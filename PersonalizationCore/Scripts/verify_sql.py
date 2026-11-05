#!/usr/bin/env python3
"""驗證個人化分類系統的 SQL（不需要 Xcode）。

做法：
1. 複製 App 內建的 PhotoAI.sqlite 到暫存檔（原檔案以唯讀方式開啟，不會被修改）。
2. 依 DatabaseManager 啟動流程建立執行期資料表（UserAlbums、UserAlbumPhotos…）。
3. 從 PersonalizationSchema.swift 擷取 Migration DDL 實際執行兩次（驗證冪等）。
4. 從 PersonalizationStore.swift / DatabaseManager.swift 擷取所有 SQL 字串，用 EXPLAIN 驗證語法與欄位名稱。
5. 依照 Swift 中的實際語句順序，模擬「移除 AI 分析資料」與「重新分析」，檢查保留 / 刪除範圍。

用法：python3 PersonalizationCore/Scripts/verify_sql.py [path/to/ios_app]
"""
from __future__ import annotations

import re
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
CORE = ROOT / "PersonalizationCore/Sources/PersonalizationCore"
BUNDLED_DB = ROOT / "MobileCLIPExplore/SQLite/PhotoAI.sqlite"
DB_MANAGER = ROOT / "MobileCLIPExplore/SQLite/DatabaseManager.swift"

failures: list[str] = []


def check(cond: bool, message: str) -> None:
    print(("  ✅ " if cond else "  ❌ ") + message)
    if not cond:
        failures.append(message)


def swift_sql_literals(source: str) -> list[str]:
    """擷取 Swift 原始碼中看起來像 SQL 的字串常值（單行與三引號）。"""
    found: list[str] = []
    for match in re.finditer(r'"""\n(.*?)\n\s*"""', source, re.S):
        found.append(match.group(1))
    for match in re.finditer(r'(?<!")"((?:[^"\\\n]|\\.)*)"(?!")', source):
        found.append(match.group(1))
    keywords = ("SELECT ", "INSERT ", "UPDATE ", "DELETE ", "CREATE ", "ALTER ")
    sqls = []
    for text in found:
        stripped = text.strip()
        if stripped.upper().startswith(keywords) and "\\(" not in stripped:
            sqls.append(stripped)
    return sqls


def runtime_tables(con: sqlite3.Connection) -> None:
    # 與 DatabaseManager.createCustomAlbumTablesIfNeeded / createSceneGraphTableIfNeeded / createNotesTableIfNeeded 相同
    con.executescript(
        """
        CREATE TABLE IF NOT EXISTS UserAlbums (album_id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS UserAlbumPhotos (album_id TEXT NOT NULL, asset_id TEXT NOT NULL, position INTEGER DEFAULT 0,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (album_id, asset_id));
        CREATE TABLE IF NOT EXISTS PinnedCategories (keyword TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS GeoRegionCache (grid_key TEXT PRIMARY KEY, region_name TEXT NOT NULL, country TEXT, country_code TEXT, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
        """
    )
    for ddl in ("ALTER TABLE UserAlbums ADD COLUMN is_pinned INTEGER DEFAULT 0",
                "ALTER TABLE AgentNotes ADD COLUMN image_assets TEXT"):
        try:
            con.execute(ddl)
        except sqlite3.OperationalError:
            pass


def apply_migrations(con: sqlite3.Connection, schema_source: str) -> None:
    con.execute(
        "CREATE TABLE IF NOT EXISTS PersonalizationMigrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT DEFAULT CURRENT_TIMESTAMP)"
    )
    # 每個 PersonalizationMigration(version: N, …) 依序套用（與 App 相同：已套用的版本略過）
    applied = {row[0] for row in con.execute("SELECT version FROM PersonalizationMigrations")}
    for block in schema_source.split("PersonalizationMigration(\n")[1:]:
        version = int(re.search(r"version:\s*(\d+)", block).group(1))
        statements_block = block.split("statements: [\n", 1)[1].split("columnAdditions:", 1)[0]
        statements = re.findall(r'"""\n(.*?)\n\s*"""', statements_block, re.S)
        if version in applied:
            continue
        with con:
            for statement in statements:
                con.execute(statement)
            con.execute("INSERT INTO PersonalizationMigrations (version, name) VALUES (?, ?)", (version, f"v{version}"))
    additions = re.findall(r'\(table: "(\w+)", column: "(\w+)", definition: "([^"]+)"\)', schema_source)
    with con:
        for table, column, definition in additions:
            exists = con.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone()[0]
            if not exists:
                continue
            columns = [row[1] for row in con.execute(f"PRAGMA table_info({table})")]
            if column not in columns:
                con.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition.replace(chr(92) + chr(39), chr(39))}")


def find_sql(sqls: list[str], marker: str) -> str:
    matches = [s for s in sqls if marker in s]
    assert len(matches) >= 1, f"SQL not found: {marker}"
    return matches[0]


def main() -> int:
    print(f"SQLite version (Python): {sqlite3.sqlite_version}")
    schema_source = (CORE / "PersonalizationSchema.swift").read_text()
    store_source = (CORE / "PersonalizationStore.swift").read_text()

    tmpdir = Path(tempfile.mkdtemp())
    db_path = tmpdir / "PhotoAI.sqlite"
    shutil.copy(BUNDLED_DB, db_path)
    original_bytes = BUNDLED_DB.read_bytes()

    con = sqlite3.connect(db_path)
    con.row_factory = None
    runtime_tables(con)

    print("1) Migration")
    before_counts = {t: con.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in ("ClusterSummary", "SemanticDictionary", "PhotoFeatures")}
    apply_migrations(con, schema_source)
    apply_migrations(con, schema_source)  # 冪等
    after_counts = {t: con.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in before_counts}
    check(before_counts == after_counts, f"既有資料筆數不變 {after_counts}")
    pf_columns = [row[1] for row in con.execute("PRAGMA table_info(PhotoFeatures)")]
    for column in ("owner_user_id", "cluster_source", "ai_removed_at"):
        check(column in pf_columns, f"PhotoFeatures 新增欄位 {column}")
    album_columns = [row[1] for row in con.execute("PRAGMA table_info(UserAlbums)")]
    check("owner_user_id" in album_columns and "description" in album_columns, "UserAlbums 新增 owner_user_id / description")

    print("2) 所有 SQL 以 EXPLAIN 驗證語法與欄位")
    sources = {"PersonalizationStore.swift": store_source}
    for extra in ("WikiStore.swift", "PhotoTextStore.swift", "WishListStore.swift", "ConversationStore.swift", "ShoppingListStore.swift"):
        if (CORE / extra).exists():
            sources[extra] = (CORE / extra).read_text()
    if DB_MANAGER.exists():
        sources["DatabaseManager.swift"] = DB_MANAGER.read_text()
    photo_text_sql = swift_sql_literals(sources.get("PhotoTextStore.swift", ""))
    all_store_sql: list[str] = []
    for name, source in sources.items():
        sqls = swift_sql_literals(source)
        if name == "PersonalizationStore.swift":
            all_store_sql = sqls
        ok = 0
        for sql in sqls:
            if sql.upper().startswith(("CREATE", "ALTER")):
                continue
            try:
                con.execute("EXPLAIN " + sql, [None] * sql.count("?"))
                ok += 1
            except sqlite3.Error as error:
                check(False, f"{name}: {error} :: {sql[:90]!r}")
        check(True, f"{name}: {ok} 條 SQL 通過 EXPLAIN")

    print("3) 模擬：移除 AI 分析資料 / 重新分析")
    vec = b"\x00\x00\x80\x3f" * 512
    with con:
        con.execute("INSERT INTO PhotoFeatures (asset_id, metadata, image_embedding, cluster_id, is_favorite, owner_user_id) VALUES ('A', '{\"date\":\"x\"}', ?, 8, 1, 'u1')", (vec,))
        con.execute("INSERT INTO PhotoFeatures (asset_id, metadata, image_embedding, cluster_id, is_favorite, owner_user_id, cluster_source) VALUES ('B', '{}', ?, 9, 0, 'u1', 'manual')", (vec,))
        con.execute("INSERT INTO PhotoFeatures (asset_id, metadata, image_embedding, cluster_id, is_favorite, owner_user_id) VALUES ('C', '{}', ?, 10, 0, 'u2')", (vec,))
        con.execute("INSERT INTO UserAlbums (album_id, title, owner_user_id) VALUES ('al1', '我的娃娃攝影', 'u1'), ('al2', '日本推活之旅', 'u1')")
        con.execute("INSERT INTO UserAlbumPhotos (album_id, asset_id, position) VALUES ('al1', 'A', 0), ('al2', 'A', 0)")
        con.execute("INSERT INTO PhotoTags (user_id, asset_id, node_id, score, source, status) VALUES ('u1','A','ramen',0.3,'auto','accepted'), ('u1','A','plush_doll',0.22,'auto','candidate'), ('u1','A','doll_outing',NULL,'manual','accepted'), ('u1','C','cat',0.3,'auto','accepted'), ('u2','C','cat',0.3,'auto','accepted')")

    if photo_text_sql:
        save_text = find_sql(photo_text_sql, "INSERT INTO PhotoText")
        with con:
            con.execute(save_text, ("A", "亞尼克 生乳捲", "亞尼克生乳捲", "vision-1", "A"))
            con.execute(save_text, ("A", "亞尼克 生乳捲 2", "亞尼克生乳捲2", "vision-1", "A"))  # upsert
            con.execute(save_text, ("C", "", "", "vision-1", "C"))
        check(con.execute("SELECT COUNT(*) FROM PhotoText").fetchone()[0] == 2, "PhotoText 寫入與更新（upsert）")
        search = find_sql(photo_text_sql, "t.normalized LIKE ?")
        found = [r[0] for r in con.execute(search, ("%生乳捲%", "生乳捲", 10))]
        check(found == ["A"], f"文字搜尋找到照片 {found}")
        pending = find_sql(photo_text_sql, "LEFT JOIN PhotoText t ON t.asset_id = f.asset_id")
        left = [r[0] for r in con.execute(pending, ("vision-1", 10))]
        check(left == ["B"], f"待辨識清單只剩沒辨識的照片 {left}")

    removal_update = find_sql(all_store_sql, "SET image_embedding = NULL")
    delete_tags = find_sql(all_store_sql, "DELETE FROM PhotoTags WHERE user_id = ? AND asset_id = ? AND source = 'auto'")
    with con:
        cur = con.execute(removal_update, ("2026-01-01T00:00:00Z", "u1", "A", "u1"))
        check(cur.rowcount == 1, "擁有者可以移除自己的向量")
        con.execute(delete_tags, ("u1", "A"))
        if photo_text_sql:
            con.execute(find_sql(all_store_sql, "DELETE FROM PhotoText WHERE asset_id = ?"), ("A",))
    row = con.execute("SELECT image_embedding, cluster_id, ai_removed_at, is_favorite, metadata FROM PhotoFeatures WHERE asset_id='A'").fetchone()
    check(row is not None, "照片識別紀錄（asset_id）保留")
    check(row[0] is None and row[1] is None and row[2] is not None, "向量與自動分類已清除並標記 ai_removed_at")
    check(row[3] == 1 and row[4] == '{"date":"x"}', "最愛與 metadata 保留")
    check(con.execute("SELECT COUNT(*) FROM UserAlbumPhotos WHERE asset_id='A'").fetchone()[0] == 2, "主題相簿成員（2 本）保留")
    check(con.execute("SELECT COUNT(*) FROM PhotoTags WHERE asset_id='A' AND source='manual'").fetchone()[0] == 1, "手動標籤保留")
    check(con.execute("SELECT COUNT(*) FROM PhotoTags WHERE asset_id='A' AND source='auto'").fetchone()[0] == 0, "自動標籤已移除")
    check(con.execute("SELECT image_embedding IS NOT NULL FROM PhotoFeatures WHERE asset_id='C'").fetchone()[0] == 1, "其他照片的向量不受影響")
    check(con.execute("SELECT COUNT(*) FROM PhotoTags WHERE asset_id='C'").fetchone()[0] == 2, "其他照片 / 其他帳號的標籤不受影響")
    if photo_text_sql:
        check(con.execute("SELECT COUNT(*) FROM PhotoText WHERE asset_id='A'").fetchone()[0] == 0, "照片文字（OCR）一併移除")
        check(con.execute("SELECT COUNT(*) FROM PhotoText WHERE asset_id='C'").fetchone()[0] == 1, "其他照片的文字不受影響")

    with con:
        cur = con.execute(removal_update, ("2026-01-01T00:00:00Z", "u1", "C", "u1"))
    check(cur.rowcount == 0, "非擁有者（u1 對 u2 的照片）無法移除向量")
    check(con.execute("SELECT image_embedding IS NOT NULL FROM PhotoFeatures WHERE asset_id='C'").fetchone()[0] == 1, "未授權操作後 u2 的向量仍在")

    with con:
        con.execute(removal_update, ("2026-01-01T00:00:00Z", "u1", "B", "u1"))
    check(con.execute("SELECT cluster_id FROM PhotoFeatures WHERE asset_id='B'").fetchone()[0] == 9, "手動移動過的分類（cluster_source=manual）保留")

    scanned_sql = find_sql(swift_sql_literals(sources.get("DatabaseManager.swift", "")), "FROM PhotoFeatures WHERE image_embedding IS NOT NULL OR ai_removed_at IS NOT NULL") if "DatabaseManager.swift" in sources else None
    if scanned_sql:
        ids = {r[0] for r in con.execute(scanned_sql)}
        check("A" in ids, "已移除 AI 的照片仍視為已處理（同步不會自動重新分析）")

    upsert_sql = find_sql(swift_sql_literals(sources.get("DatabaseManager.swift", "")), "ON CONFLICT(asset_id) DO UPDATE SET") if "DatabaseManager.swift" in sources else None
    if upsert_sql:
        with con:
            con.execute(upsert_sql, ("A", '{"date":"y"}', vec, "u1"))
        check(con.execute("SELECT image_embedding IS NULL FROM PhotoFeatures WHERE asset_id='A'").fetchone()[0] == 1,
              "同步途中的寫入不會覆蓋已移除 AI 的照片")
        reanalysis = find_sql(all_store_sql, "UPDATE PhotoFeatures SET ai_removed_at = NULL")
        with con:
            con.execute(reanalysis, ("u1", "A"))
            con.execute(upsert_sql, ("A", '{"date":"y","latitude":1}', vec, "u1"))
        row = con.execute("SELECT image_embedding IS NOT NULL, is_favorite, metadata, cluster_id FROM PhotoFeatures WHERE asset_id='A'").fetchone()
        check(row[0] == 1 and row[1] == 1, "重新分析後產生新向量，最愛保留")
        check('"latitude"' in row[2], f"重新分析合併 metadata：{row[2]}")
        with con:
            con.execute(upsert_sql, ("B", '{}', vec, "u1"))
        check(con.execute("SELECT cluster_id FROM PhotoFeatures WHERE asset_id='B'").fetchone()[0] in (None, 9), "（參考）B 已移除 AI，不會被覆寫")

    print("4) 內建資料庫檔案未被修改")
    check(BUNDLED_DB.read_bytes() == original_bytes, "PhotoAI.sqlite 內容與執行前完全相同")

    con.close()
    shutil.rmtree(tmpdir)
    print()
    if failures:
        print(f"FAILED: {len(failures)} 項")
        return 1
    print("ALL SQL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())

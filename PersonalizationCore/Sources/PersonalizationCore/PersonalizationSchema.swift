// PersonalizationSchema.swift
//
// 個人化分類系統的資料庫 Migration。
//
// 原則：
// - 只「新增」資料表、索引與欄位（CREATE TABLE IF NOT EXISTS / ALTER TABLE ADD COLUMN），
//   不重建、不刪除、不改寫任何既有資料表或資料。
// - 每個版本在一個 transaction 中執行，並記錄於 PersonalizationMigrations；失敗會整批回滾。
// - 可重複執行（idempotent）：App 每次啟動都會呼叫，已套用的版本會被略過。

import Foundation
import SQLite

struct PersonalizationMigration {
    let version: Int
    let name: String
    /// 純 DDL（只使用 IF NOT EXISTS），不含 Swift 字串插值。
    let statements: [String]
    /// 既有資料表要追加的欄位：只有在資料表存在且欄位不存在時才會 ALTER。
    let columnAdditions: [(table: String, column: String, definition: String)]
}

enum PersonalizationSchema {

    static let migrations: [PersonalizationMigration] = [
        PersonalizationMigration(
            version: 1,
            name: "personalized_taxonomy_multilabel_tags",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS PersonalizationMeta (
                    meta_key TEXT PRIMARY KEY,
                    meta_value TEXT
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS UserProfiles (
                    user_id TEXT PRIMARY KEY,
                    email TEXT,
                    display_name TEXT,
                    onboarding_status TEXT NOT NULL DEFAULT 'pending',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """,
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_userprofiles_email
                ON UserProfiles(email) WHERE email IS NOT NULL
                """,
                """
                CREATE TABLE IF NOT EXISTS TaxonomyNodes (
                    node_id TEXT PRIMARY KEY,
                    parent_id TEXT,
                    level INTEGER NOT NULL CHECK (level IN (1, 2, 3)),
                    name_zh TEXT NOT NULL,
                    name_en TEXT NOT NULL,
                    summary_zh TEXT,
                    summary_en TEXT,
                    examples_zh TEXT,
                    icon TEXT,
                    recognition TEXT NOT NULL DEFAULT 'visual',
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    is_builtin INTEGER NOT NULL DEFAULT 1,
                    is_active INTEGER NOT NULL DEFAULT 1,
                    catalog_version INTEGER NOT NULL DEFAULT 0
                )
                """,
                """
                CREATE INDEX IF NOT EXISTS idx_taxonomynodes_parent ON TaxonomyNodes(parent_id)
                """,
                """
                CREATE TABLE IF NOT EXISTS TaxonomyPrompts (
                    node_id TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    embedding BLOB,
                    PRIMARY KEY (node_id, prompt)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS UserInterests (
                    user_id TEXT NOT NULL,
                    interest_id TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, interest_id)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS UserCategoryPreferences (
                    user_id TEXT NOT NULL,
                    node_id TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    source TEXT NOT NULL DEFAULT 'manual',
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, node_id)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS PhotoTags (
                    user_id TEXT NOT NULL,
                    asset_id TEXT NOT NULL,
                    node_id TEXT NOT NULL,
                    score REAL,
                    source TEXT NOT NULL CHECK (source IN ('auto', 'manual')),
                    status TEXT NOT NULL CHECK (status IN ('accepted', 'candidate', 'rejected')),
                    tagger_version TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, asset_id, node_id)
                )
                """,
                """
                CREATE INDEX IF NOT EXISTS idx_phototags_node ON PhotoTags(user_id, node_id, status)
                """,
                """
                CREATE INDEX IF NOT EXISTS idx_phototags_asset ON PhotoTags(user_id, asset_id)
                """,
                """
                CREATE TABLE IF NOT EXISTS PhotoAnalysisState (
                    user_id TEXT NOT NULL,
                    asset_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    tagger_version TEXT,
                    last_error TEXT,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, asset_id)
                )
                """,
            ],
            columnAdditions: [
                // 照片向量的歸屬（本機帳號）。既有資料為 NULL，登入時由目前帳號認領。
                (table: "PhotoFeatures", column: "owner_user_id", definition: "TEXT"),
                // cluster_id 的來源：auto = 既有自動分類；manual = 使用者「移動到其他相簿」。
                (table: "PhotoFeatures", column: "cluster_source", definition: "TEXT NOT NULL DEFAULT 'auto'"),
                // 使用者執行「移除 AI 分析資料」的時間；非 NULL 時同步流程不會重新產生向量。
                (table: "PhotoFeatures", column: "ai_removed_at", definition: "TEXT"),
                // 主題相簿（沿用既有自訂相簿）的擁有者與說明。
                (table: "UserAlbums", column: "owner_user_id", definition: "TEXT"),
                (table: "UserAlbums", column: "description", definition: "TEXT"),
            ]
        ),
        PersonalizationMigration(
            version: 2,
            name: "user_custom_categories",
            statements: [
                // 「我的 IP」等使用者自訂分類。照片與分類的對應沿用 PhotoTags（node_id = 'ip:<category_id>'）：
                // 範例 = 手動確認、反例 = 手動拒絕、比對結果 = auto。只新增資料表，不改既有資料。
                """
                CREATE TABLE IF NOT EXISTS UserCustomCategories (
                    category_id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """,
                """
                CREATE INDEX IF NOT EXISTS idx_customcategories_user ON UserCustomCategories(user_id, kind)
                """,
            ],
            columnAdditions: []
        ),
        PersonalizationMigration(
            version: 3,
            name: "custom_category_parent_and_cover",
            statements: [
            ],
            columnAdditions: [
                // 我的 IP 的上層（例如「五條悟」屬於「咒術迴戰」），只支援兩層
                (table: "UserCustomCategories", column: "parent_category_id", definition: "TEXT"),
                // 使用者自選的相簿封面照片（只存照片識別碼）
                (table: "UserCustomCategories", column: "cover_asset_id", definition: "TEXT"),
            ]
        ),
        PersonalizationMigration(
            version: 4,
            name: "subject_suggestion_feedback",
            statements: [
                // （已停用，見 v5）主動建議專屬相簿的回饋：顯示過、採用、略過。
                // 已發布的 migration 不能刪除或改動，否則已升級過的資料庫版本會對不上。
                """
                CREATE TABLE IF NOT EXISTS SubjectSuggestionFeedback (
                    user_id TEXT NOT NULL,
                    suggestion_key TEXT NOT NULL,
                    action TEXT NOT NULL,
                    centroid BLOB,
                    photo_count INTEGER,
                    day_count INTEGER,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, suggestion_key, action)
                )
                """,
            ],
            columnAdditions: []
        ),
        PersonalizationMigration(
            version: 5,
            name: "drop_subject_suggestion_feedback",
            statements: [
                // 「主動建議專屬相簿」功能已移除：刪掉它的回饋表（只有 App 自己記錄的顯示／採用／略過，與照片無關）。
                """
                DROP TABLE IF EXISTS SubjectSuggestionFeedback
                """,
            ],
            columnAdditions: []
        ),
        PersonalizationMigration(
            version: 6,
            name: "wiki_notes",
            statements: [
                // 個人 Wiki 筆記：原本存在 Agent 後端（電腦）上，改存在手機。
                // embedding 是「主題＋摘要＋內容」的文字向量（Float32），embedding_model 記錄用哪個模型算的，
                // 換模型時只需要重算向量，筆記內容不變。只新增資料表。
                """
                CREATE TABLE IF NOT EXISTS WikiNotes (
                    user_id TEXT NOT NULL,
                    topic TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    content TEXT NOT NULL,
                    embedding BLOB,
                    embedding_model TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, topic)
                )
                """,
                // 筆記對應的照片：只存照片的識別碼（PHAsset.localIdentifier），不複製、不修改照片。
                """
                CREATE TABLE IF NOT EXISTS WikiNotePhotos (
                    user_id TEXT NOT NULL,
                    topic TEXT NOT NULL,
                    asset_id TEXT NOT NULL,
                    position INTEGER DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, topic, asset_id)
                )
                """,
                """
                CREATE INDEX IF NOT EXISTS idx_wiki_photos_asset ON WikiNotePhotos(user_id, asset_id)
                """,
            ],
            columnAdditions: []
        ),
        PersonalizationMigration(
            version: 7,
            name: "photo_text",
            statements: [
                // 照片中的文字（App 在手機上用 Apple Vision 辨識）：用於搜尋與分類線索。
                // normalized 是去空白、轉小寫後的文字；沒有文字的照片存空字串，避免重複辨識。
                // 只新增資料表，不修改照片；「移除 AI 分析資料」時一併刪除。
                """
                CREATE TABLE IF NOT EXISTS PhotoText (
                    asset_id TEXT PRIMARY KEY,
                    text TEXT NOT NULL,
                    normalized TEXT NOT NULL,
                    ocr_version TEXT,
                    recognized_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """,
            ],
            columnAdditions: []
        ),
        PersonalizationMigration(
            version: 8,
            name: "wish_places",
            statements: [
                // 想去清單：從截圖找出的店家／景點。只存名稱、地址、座標與來源截圖的識別碼；
                // 之後在附近拍的照片會標成「去過」（只記照片識別碼，不修改照片）。只新增資料表。
                """
                CREATE TABLE IF NOT EXISTS WishPlaces (
                    user_id TEXT NOT NULL,
                    place_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    name_key TEXT NOT NULL,
                    address TEXT NOT NULL DEFAULT '',
                    area TEXT NOT NULL DEFAULT '',
                    category TEXT NOT NULL DEFAULT '其他',
                    note TEXT NOT NULL DEFAULT '',
                    latitude REAL,
                    longitude REAL,
                    source_asset_id TEXT,
                    status TEXT NOT NULL DEFAULT 'want' CHECK (status IN ('want', 'visited')),
                    visited_asset_id TEXT,
                    visited_at TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, place_id)
                )
                """,
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_wish_places_name ON WishPlaces(user_id, name_key)
                """,
            ],
            columnAdditions: []
        ),
        PersonalizationMigration(
            version: 9,
            name: "agent_conversations",
            statements: [
                // 最近的對話：Agent 頁的聊天紀錄，關掉 App 後還能接著聊。
                // 照片只存識別碼（asset_ids，JSON 陣列），不複製照片。只新增資料表。
                """
                CREATE TABLE IF NOT EXISTS AgentConversations (
                    user_id TEXT NOT NULL,
                    conversation_id TEXT NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, conversation_id)
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS AgentMessages (
                    user_id TEXT NOT NULL,
                    conversation_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    is_user INTEGER NOT NULL,
                    text TEXT NOT NULL DEFAULT '',
                    bubble_text TEXT,
                    quoted_topic TEXT,
                    asset_ids TEXT NOT NULL DEFAULT '[]',
                    image_count INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, conversation_id, seq)
                )
                """,
            ],
            columnAdditions: []
        ),
        PersonalizationMigration(
            version: 10,
            name: "shopping_items",
            statements: [
                // 購物清單：從商品截圖整理出的「想買的東西」，以及要在哪個國家買。
                // 到了那個國家（或清單上寫的店附近）時提醒；只記來源截圖的識別碼，不修改照片。只新增資料表。
                """
                CREATE TABLE IF NOT EXISTS ShoppingItems (
                    user_id TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    name_key TEXT NOT NULL,
                    brand TEXT NOT NULL DEFAULT '',
                    price TEXT NOT NULL DEFAULT '',
                    store TEXT NOT NULL DEFAULT '',
                    country_code TEXT NOT NULL DEFAULT '',
                    note TEXT NOT NULL DEFAULT '',
                    source_asset_id TEXT,
                    status TEXT NOT NULL DEFAULT 'want' CHECK (status IN ('want', 'bought')),
                    bought_at TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                    PRIMARY KEY (user_id, item_id)
                )
                """,
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_shopping_items_name ON ShoppingItems(user_id, country_code, name_key)
                """,
            ],
            columnAdditions: []
        ),
        PersonalizationMigration(
            version: 11,
            name: "photo_faces",
            statements: [
                // 照片裡的臉（App 在手機上用 Apple Vision 偵測）：只存臉的數量、最大那張臉的大小、是不是前鏡頭拍的，
                // 用來判斷自拍、單人照、雙人合照、多人合照。不存臉的影像或特徵，不辨識是誰。
                // v17 起不再偵測人臉，這張表不再寫入（保留表格，不重建資料庫；舊資料啟動後清掉）。
                // 只新增資料表，不修改照片；「移除 AI 分析資料」時一併刪除。
                """
                CREATE TABLE IF NOT EXISTS PhotoFaces (
                    asset_id TEXT PRIMARY KEY,
                    main_faces INTEGER NOT NULL,
                    largest REAL NOT NULL,
                    front_camera INTEGER NOT NULL DEFAULT 0,
                    face_version TEXT,
                    analyzed_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """,
            ],
            columnAdditions: []
        ),
    ]

    static var latestVersion: Int { migrations.map(\.version).max() ?? 0 }

    /// 執行所有尚未套用的 Migration，回傳本次套用的版本。
    @discardableResult
    static func migrate(_ db: Connection) throws -> [Int] {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS PersonalizationMigrations (
            version INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
        """)

        var applied: Set<Int> = []
        for row in try db.prepare("SELECT version FROM PersonalizationMigrations").run() {
            if let version = row[0] as? Int64 { applied.insert(Int(version)) }
        }

        var newlyApplied: [Int] = []
        for migration in migrations.sorted(by: { $0.version < $1.version }) where !applied.contains(migration.version) {
            try db.transaction {
                for statement in migration.statements {
                    try db.execute(statement)
                }
                for addition in migration.columnAdditions {
                    try addColumnIfMissing(db, table: addition.table, column: addition.column, definition: addition.definition)
                }
                try db.run(
                    "INSERT INTO PersonalizationMigrations (version, name) VALUES (?, ?)",
                    Int64(migration.version), migration.name
                )
            }
            newlyApplied.append(migration.version)
        }

        // 欄位追加是冪等的：每次都檢查一次，避免「當時資料表尚未建立」造成欄位缺漏。
        try db.transaction {
            for migration in migrations {
                for addition in migration.columnAdditions {
                    try addColumnIfMissing(db, table: addition.table, column: addition.column, definition: addition.definition)
                }
            }
        }
        return newlyApplied
    }

    static func tableExists(_ db: Connection, _ table: String) throws -> Bool {
        let count = try db.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            table
        ) as? Int64 ?? 0
        return count > 0
    }

    static func columnExists(_ db: Connection, table: String, column: String) throws -> Bool {
        // PRAGMA 不能綁定參數；table 只會是本檔案內寫死的常數名稱。
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        for row in try db.prepare("PRAGMA table_info(\(table))").run() {
            if let name = row[1] as? String, name == column { return true }
        }
        return false
    }

    private static func addColumnIfMissing(_ db: Connection, table: String, column: String, definition: String) throws {
        guard try tableExists(db, table) else { return }
        guard try !columnExists(db, table: table, column: column) else { return }
        try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }
}

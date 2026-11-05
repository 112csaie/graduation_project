#!/usr/bin/env python3
"""相簿主題設定資料夾：把內建分類目錄匯出成「大分類／中分類／小分類」資料夾，逐一調整後再套用回 App。

    python3 taxonomy_folder.py export <資料夾>   建立或更新資料夾（保留已套用的調整）
    python3 taxonomy_folder.py apply  <資料夾>   檢查資料夾內容，把「改過的地方」寫進 TaxonomyTuningData.swift

內建分類定義在 TaxonomyCatalog.swift（Swift 原始碼），這裡用一個小型解析器讀出 l1()/l2()/l3() 的內容，
不需要 Xcode。App 端如何套用調整見 TaxonomyTuning.swift。

只讀寫：TaxonomyCatalog.swift（只讀）、MultiLabelTagger.swift（只讀）、TaxonomyTuningData.swift（寫入）、指定的資料夾。
不會碰照片、相簿或資料庫。
"""
import json
import os
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CORE_DIR = SCRIPT_DIR.parent / "Sources" / "PersonalizationCore"
CATALOG_SWIFT = CORE_DIR / "TaxonomyCatalog.swift"
TAGGER_SWIFT = CORE_DIR / "MultiLabelTagger.swift"
TUNING_SWIFT = CORE_DIR / "TaxonomyTuningData.swift"

RECOGNITION = ["visual", "assisted", "derived", "manualOnly"]

# 資料夾 JSON 的欄位（中文）↔ App 的欄位
NODE_FIELDS = [
    ("中文名稱", "nameZh"),
    ("英文名稱", "nameEn"),
    ("辨識方式", "recognition"),
    ("門檻", "acceptScore"),
    ("提示詞", "prompts"),
    ("容易誤認的畫面", "confusers"),
    ("被這些分類排除", "suppressedBy"),
    ("一眼看得出來", "distinct"),
    ("預設開啟", "enabledByDefault"),
]
L12_FIELDS = [("中文名稱", "nameZh"), ("英文名稱", "nameEn")]

THRESHOLD_FIELDS = [
    # (中文, App 欄位, 型別, 範圍, 說明)
    ("確認門檻", "acceptScore", float, (0.1, 0.5),
     "照片和分類描述的相似度要達到多少才自動標上（沒有自己門檻的分類都用這個）。調高＝比較嚴格、標得比較少。"),
    ("選了的大分類降低", "preferredAcceptBonus", float, (0.0, 0.1),
     "你在設定裡選了的大分類，門檻降低這麼多（比較容易標上）。"),
    ("沒選的大分類提高", "unpreferredAcceptPenalty", float, (0.0, 0.1),
     "你沒選的大分類，門檻提高這麼多（只收很有把握的）。"),
    ("與最高分最多相差", "acceptMarginFromBest", float, (0.0, 0.2),
     "一張照片可以有好幾個標籤，但分數要和這張照片最像的分類相差不超過這個值。"),
    ("每張最多幾個標籤", "maxAccepted", int, (1, 6),
     "每張照片最多自動標上幾個分類。"),
    ("排除規則容許差距", "suppressMargin", float, (0.0, 0.1),
     "「容易誤認的畫面」或「被這些分類排除」的分數只要不低於本分類減這個值，就不標。調高＝排除得更積極。"),
    ("一眼看得出來的分類與最高分最多相差", "distinctMarginFromBest", float, (0.0, 0.2),
     "貓、狗這類「一眼看得出來」的分類，可以比最高分低這麼多仍然標上。"),
]

RECOGNITION_HELP = {
    "visual": "看畫面就能判斷，分數夠就自動標上",
    "assisted": "只看得出相關畫面、無法確定情境（例如演唱會），最多成為「待確認」問你",
    "derived": "由其他標籤組合推論（例如合照＋地標＝旅行合照），不能改提示詞",
    "manualOnly": "模型分不出來，只能手動加入（改成 visual 或 assisted 時要寫提示詞）",
}


# ───────────────────────── Swift 小型解析器 ─────────────────────────

class SwiftParseError(Exception):
    pass


def tokenize(src):
    tokens = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in " \t\r\n":
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i)
            if j < 0:
                raise SwiftParseError("註解沒有結束")
            i = j + 2
        elif c == '"':
            if src.startswith('"""', i):
                raise SwiftParseError("不支援多行字串")
            j = i + 1
            out = []
            while True:
                if j >= n:
                    raise SwiftParseError("字串沒有結束")
                d = src[j]
                if d == "\\":
                    e = src[j + 1]
                    if e == "u" and src[j + 2] == "{":
                        k = src.index("}", j)
                        out.append(chr(int(src[j + 3:k], 16)))
                        j = k + 1
                        continue
                    if e == "(":
                        raise SwiftParseError("不支援字串插值")
                    out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0"}[e])
                    j += 2
                elif d == '"':
                    break
                elif d == "\n":
                    raise SwiftParseError("字串中有換行")
                else:
                    out.append(d)
                    j += 1
            tokens.append(("str", "".join(out)))
            i = j + 1
        elif c.isdigit() or (c == "-" and i + 1 < n and src[i + 1].isdigit()):
            m = re.match(r"-?\d+(\.\d+)?", src[i:])
            text = m.group(0)
            tokens.append(("num", float(text) if "." in text else int(text)))
            i += len(text)
        elif c.isalpha() or c == "_":
            m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", src[i:])
            tokens.append(("id", m.group(0)))
            i += len(m.group(0))
        elif c in "()[],:+.":
            tokens.append(("p", c))
            i += 1
        else:
            raise SwiftParseError(f"看不懂的字元：{c!r}（位置 {i}）")
    return tokens


class Parser:
    def __init__(self, tokens, constants):
        self.t = tokens
        self.i = 0
        self.constants = constants

    def peek(self, k=0):
        return self.t[self.i + k] if self.i + k < len(self.t) else (None, None)

    def take(self, kind=None, value=None):
        tok = self.peek()
        if kind and tok[0] != kind or value is not None and tok[1] != value:
            raise SwiftParseError(f"預期 {kind} {value!r}，看到 {tok}")
        self.i += 1
        return tok

    def expr(self):
        value = self.term()
        while self.peek() == ("p", "+"):
            self.take()
            right = self.term()
            if not isinstance(value, list) or not isinstance(right, list):
                raise SwiftParseError("只支援陣列相加")
            value = value + right
        return value

    def term(self):
        kind, val = self.peek()
        if kind in ("str", "num"):
            self.take()
            return val
        if (kind, val) == ("p", "["):
            self.take()
            items = []
            while self.peek() != ("p", "]"):
                items.append(self.expr())
                if self.peek() == ("p", ","):
                    self.take()
            self.take("p", "]")
            return items
        if (kind, val) == ("p", "."):
            self.take()
            return ("enum", self.take("id")[1])
        if kind == "id":
            self.take()
            if val in ("true", "false"):
                return val == "true"
            if val == "nil":
                return None
            if self.peek() == ("p", "("):
                return self.call(val)
            if val not in self.constants:
                raise SwiftParseError(f"不認得的名稱：{val}")
            return self.constants[val]
        raise SwiftParseError(f"看不懂：{(kind, val)}")

    def call(self, name):
        self.take("p", "(")
        args, kwargs = [], {}
        while self.peek() != ("p", ")"):
            if self.peek()[0] == "id" and self.peek(1) == ("p", ":"):
                label = self.take()[1]
                self.take("p", ":")
                kwargs[label] = self.expr()
            else:
                args.append(self.expr())
            if self.peek() == ("p", ","):
                self.take()
        self.take("p", ")")
        return ("call", name, args, kwargs)


def _block(src, header):
    """header 之後、對應的 ] 為止的內容（含最外層的 [ ]）"""
    start = src.index(header)
    i = src.index("[", start + len(header) - 1)
    depth, j, in_str = 0, i, False
    while j < len(src):
        c = src[j]
        if in_str:
            if c == "\\":
                j += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif src.startswith("//", j):
            j = src.index("\n", j)
            continue
        elif c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
        j += 1
    raise SwiftParseError(f"找不到 {header} 的結尾")


def parse_catalog(path=CATALOG_SWIFT):
    src = Path(path).read_text(encoding="utf-8")
    body = src[src.index("private enum BuiltInTaxonomy"):]
    # 陣列常數（posingPerson、genericMeal…）
    constants = {}
    for m in re.finditer(r"static let (\w+) = \[", body):
        name = m.group(1)
        block = _block(body, m.group(0))
        p = Parser(tokenize(block), constants)
        constants[name] = p.expr()
    version = int(re.search(r"catalogVersion:\s*(\d+)", src).group(1))

    nodes_block = _block(body, "static let nodes: [TaxonomyNode] = [")
    p = Parser(tokenize(nodes_block), constants)
    calls = p.expr()
    if p.i != len(p.t):
        raise SwiftParseError("nodes 解析後還有剩餘內容")
    nodes = []
    for c in calls:
        if not (isinstance(c, tuple) and c[0] == "call" and c[1] in ("l1", "l2", "l3")):
            raise SwiftParseError(f"nodes 裡有不是 l1/l2/l3 的項目：{c}")
        _, name, a, kw = c
        if name == "l1":
            nid, zh, en, sz, se, ex, icon, order = a
            nodes.append(dict(id=nid, parentId=None, level=1, nameZh=zh, nameEn=en, summaryZh=sz, examplesZh=ex,
                              recognition="visual", prompts=[], requiresAnyOf=[], enabledByDefault=True,
                              sortOrder=order, suppressedBy=[], confusers=[], distinct=False))
        elif name == "l2":
            nid, parent, zh, en, icon, order = a
            nodes.append(dict(id=nid, parentId=parent, level=2, nameZh=zh, nameEn=en, recognition="manualOnly",
                              prompts=[], requiresAnyOf=[], enabledByDefault=True, sortOrder=order,
                              suppressedBy=[], confusers=[], distinct=False))
        else:
            nid, parent, zh, en, mode, prompts = a
            unknown = set(kw) - {"requires", "enabled", "order", "suppressedBy", "confusers", "distinct", "requiresText"}
            if unknown:
                raise SwiftParseError(f"{nid} 有不認得的參數：{unknown}")
            nodes.append(dict(id=nid, parentId=parent, level=3, nameZh=zh, nameEn=en, recognition=mode[1],
                              prompts=prompts, requiresAnyOf=kw.get("requires", []),
                              enabledByDefault=kw.get("enabled", True), sortOrder=kw.get("order", 0),
                              suppressedBy=kw.get("suppressedBy", []), confusers=kw.get("confusers", []),
                              distinct=kw.get("distinct", False), requiresText=kw.get("requiresText", False)))
        nodes[-1]["acceptScore"] = None
    # 自我檢查：和原始碼裡 l1/l2/l3 的數量一致
    expected = len(re.findall(r"^\s*l[123]\(", nodes_block, flags=re.M))
    if expected != len(nodes):
        raise SwiftParseError(f"解析出 {len(nodes)} 個分類，原始碼有 {expected} 個")
    return version, nodes


def parse_threshold_defaults(path=TAGGER_SWIFT):
    src = Path(path).read_text(encoding="utf-8")
    block = src[src.index("struct TaggingThresholds"):]
    block = block[:block.index("static let `default`")]
    out = {}
    for _, key, typ, _, _ in THRESHOLD_FIELDS:
        m = re.search(rf"var {key}: (Float|Int) = ([\d.]+)", block)
        if not m:
            raise SwiftParseError(f"找不到門檻預設值：{key}")
        out[key] = typ(m.group(2))
    return out


def read_tuning(path=TUNING_SWIFT):
    src = Path(path).read_text(encoding="utf-8")
    m = re.search(r'##"""\n(.*?)\n"""##', src, flags=re.S)
    if not m:
        raise SwiftParseError("TaxonomyTuningData.swift 格式不對")
    text = m.group(1).strip()
    return {} if text in ("", "{}") else json.loads(text)


# ───────────────────────── 資料夾 ─────────────────────────

def safe_name(text):
    return re.sub(r'[/\\:*?"<>|]', "／", text).strip() or "未命名"


def effective_nodes(nodes, tuning):
    tuned = tuning.get("nodes", {})
    out = []
    for n in nodes:
        e = dict(n)
        for key, value in tuned.get(n["id"], {}).items():
            e[key] = value
        out.append(e)
    return out


def effective_thresholds(defaults, tuning):
    out = dict(defaults)
    out.update(tuning.get("thresholds", {}) or {})
    return out


def node_paths(nodes):
    """每個分類的相對路徑（依大分類／中分類／小分類的順序編號）"""
    by_parent = {}
    for n in nodes:
        by_parent.setdefault(n["parentId"], []).append(n)
    for children in by_parent.values():
        children.sort(key=lambda n: n["sortOrder"])
    paths = {}

    def walk(parent_id, base):
        for k, n in enumerate(by_parent.get(parent_id, []), 1):
            label = f"{k:02d} {safe_name(n['nameZh'])}"
            folder = base / label
            if n["level"] < 3:
                paths[n["id"]] = folder / ("_大分類.json" if n["level"] == 1 else "_中分類.json")
                walk(n["id"], folder)
            else:
                # 小分類也是一個資料夾：設定檔放在裡面，旁邊可以放這個分類的範例照片
                paths[n["id"]] = folder / "設定.json"

    walk(None, Path("."))
    return paths


def threshold_text(node, thresholds):
    base = node["acceptScore"] if node["acceptScore"] is not None else thresholds["acceptScore"]
    lo = base - thresholds["preferredAcceptBonus"]
    hi = base + thresholds["unpreferredAcceptPenalty"]
    own = "（這個分類自己的門檻）" if node["acceptScore"] is not None else "（全域門檻）"
    return f"{base:.3f}{own}；有選這個大分類 {lo:.3f}、沒選 {hi:.3f}"


def node_document(n, by_id, thresholds):
    trail = []
    cur = n
    while cur["parentId"]:
        cur = by_id[cur["parentId"]]
        trail.insert(0, cur["nameZh"])
    ref = {"位置": " › ".join(trail + [n["nameZh"]]) if trail else n["nameZh"]}
    if n["level"] < 3:
        doc = {"id": n["id"]}
        for zh, key in L12_FIELDS:
            doc[zh] = n[key]
        children = [c["nameZh"] for c in sorted(by_id.values(), key=lambda c: c["sortOrder"]) if c["parentId"] == n["id"]]
        ref["底下的分類"] = children
        ref["說明"] = "大分類、中分類只能改名稱；門檻和提示詞在小分類的檔案裡調整。"
        doc["參考（不用改）"] = ref
        return doc
    doc = {"id": n["id"]}
    for zh, key in NODE_FIELDS:
        doc[zh] = n[key]
    ref["辨識方式說明"] = RECOGNITION_HELP[n["recognition"]]
    if n["recognition"] in ("visual", "assisted"):
        ref["目前實際門檻"] = threshold_text(n, thresholds)
    if n.get("requiresText"):
        ref["需要照片文字"] = "畫面像只會去辨識照片文字，文字也對（例如「電子發票」「統一編號」）才標上"
    if n["requiresAnyOf"]:
        names = [[by_id[x]["nameZh"] if x in by_id else x for x in group] for group in n["requiresAnyOf"]]
        ref["組合規則"] = "每一組至少要有一個：" + " ＋ ".join("（" + "、".join(g) + "）" for g in names)
    if n["suppressedBy"]:
        ref["排除分類的名稱"] = [by_id[x]["nameZh"] if x in by_id else x for x in n["suppressedBy"]]
    doc["參考（不用改）"] = ref
    return doc


def thresholds_document(values, defaults):
    doc = {}
    for zh, key, _, (lo, hi), _ in THRESHOLD_FIELDS:
        doc[zh] = values[key]
    doc["說明（不用改）"] = {
        zh: f"{help_text}（內建 {defaults[key]}；範圍 {lo}～{hi}）"
        for zh, key, _, (lo, hi), help_text in THRESHOLD_FIELDS
    }
    return doc


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def export(folder):
    folder = Path(folder)
    version, nodes = parse_catalog()
    defaults = parse_threshold_defaults()
    tuning = read_tuning()
    eff = effective_nodes(nodes, tuning)
    by_id = {n["id"]: n for n in eff}
    thresholds = effective_thresholds(defaults, tuning)
    # 用「原始名稱」決定資料夾名稱，改名後再匯出時路徑不變
    paths = node_paths(nodes)

    if folder.exists():
        _relocate_folders(folder, nodes, paths)
    existing = _scan_ids(folder)
    # 上次匯出的內容：用來分辨「你改過還沒套用」和「App 的內建設定改了」
    snapshot_file = folder / SNAPSHOT_NAME
    try:
        snapshot = json.loads(snapshot_file.read_text(encoding="utf-8"))
    except Exception:
        snapshot = None
    readme = folder / "使用說明.md"
    exported_at = readme.stat().st_mtime if readme.exists() else None

    def edited(key, old_file, old_doc, new_doc):
        """這個檔案有沒有你還沒套用的修改"""
        if _editable(old_doc) == _editable(new_doc):
            return False
        if snapshot is not None and key in snapshot:
            return _editable(old_doc) != snapshot[key]
        # 舊版資料夾沒有快照：上次匯出之後改過的檔案才算
        return exported_at is None or old_file.stat().st_mtime > exported_at + 1

    new_snapshot = {}
    unapplied = []
    for n in eff:
        target = folder / paths[n["id"]]
        doc = node_document(n, by_id, thresholds)
        old = existing.get(n["id"])
        if old and old.exists():
            try:
                old_doc = json.loads(old.read_text(encoding="utf-8"))
            except Exception:
                old_doc = None
            if old_doc is not None and edited(n["id"], old, old_doc, doc):
                unapplied.append(n["id"])
                new_snapshot[n["id"]] = (snapshot or {}).get(n["id"], _editable(doc))
                continue   # 有還沒套用的修改：不覆蓋
            if old.resolve() != target.resolve():
                # 內建分類的順序變了：搬到新的位置（只搬這個工具產生的設定檔）
                target.parent.mkdir(parents=True, exist_ok=True)
                os.replace(old, target)
        write_json(target, doc)
        new_snapshot[n["id"]] = _editable(doc)

    tdoc = thresholds_document(thresholds, defaults)
    tfile = folder / "全域門檻.json"
    old_t = None
    if tfile.exists():
        try:
            old_t = json.loads(tfile.read_text(encoding="utf-8"))
        except Exception:
            old_t = None
    if old_t is not None and edited(THRESHOLDS_KEY, tfile, old_t, tdoc):
        unapplied.append("全域門檻")
        new_snapshot[THRESHOLDS_KEY] = (snapshot or {}).get(THRESHOLDS_KEY, _editable(tdoc))
    else:
        write_json(tfile, tdoc)
        new_snapshot[THRESHOLDS_KEY] = _editable(tdoc)
    write_json(snapshot_file, new_snapshot)
    (folder / "使用說明.md").write_text(README, encoding="utf-8")
    for name, command in (("套用到App.py", "apply"), ("重新整理資料夾.py", "export")):
        (folder / name).write_text(WRAPPER.format(command=command), encoding="utf-8")
    print(f"分類目錄 v{version}：{len(nodes)} 個分類（大分類 {sum(n['level'] == 1 for n in nodes)}、"
          f"中分類 {sum(n['level'] == 2 for n in nodes)}、小分類 {sum(n['level'] == 3 for n in nodes)}）")
    if unapplied:
        print(f"⚠️ 這些檔案有還沒套用的修改，保留沒有覆蓋：{', '.join(unapplied)}")
    print(f"已寫到：{folder}")


SNAPSHOT_NAME = ".上次匯出.json"
THRESHOLDS_KEY = "__全域門檻__"


def _scan_ids(folder):
    """資料夾裡每個分類設定檔的位置：id → 檔案"""
    existing = {}
    if not folder.exists():
        return existing
    for f in folder.rglob("*.json"):
        if f.name.startswith("."):
            continue
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        if isinstance(data, dict) and "id" in data:
            existing[data["id"]] = f
    return existing


def _relocate_folders(folder, nodes, paths):
    """分類改名或順序變了：整個資料夾搬到新的名稱（裡面你放的照片跟著走）。
    由大分類到小分類依序處理；新名稱的資料夾已經存在時不搬（之後只搬設定檔）。只改名、不刪除任何檔案。"""
    marker = {1: "_大分類.json", 2: "_中分類.json", 3: "設定.json"}
    for level in (1, 2, 3):
        existing = _scan_ids(folder)
        for n in nodes:
            if n["level"] != level or n["id"] not in existing:
                continue
            old = existing[n["id"]]
            if old.name != marker[level]:
                continue   # 舊版的檔案位置（小分類還不是資料夾）：之後只搬設定檔
            old_dir = old.parent
            new_dir = (folder / paths[n["id"]]).parent
            if old_dir.resolve() == new_dir.resolve() or new_dir.exists():
                continue
            new_dir.parent.mkdir(parents=True, exist_ok=True)
            os.rename(old_dir, new_dir)
            print(f"資料夾改名：{old_dir.relative_to(folder)} → {new_dir.relative_to(folder)}")


def _editable(doc):
    return {k: v for k, v in doc.items() if not k.startswith("參考") and not k.startswith("說明")}


def apply(folder, dry_run=False):
    folder = Path(folder)
    version, nodes = parse_catalog()
    defaults = parse_threshold_defaults()
    base = {n["id"]: n for n in nodes}
    errors, warnings = [], []
    seen = {}
    for f in sorted(folder.rglob("*.json")):
        if f.name == "全域門檻.json" or f.name.startswith("."):
            continue
        rel = f.relative_to(folder)
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            errors.append(f"{rel}：JSON 格式錯誤（第 {e.lineno} 行第 {e.colno} 個字）：{e.msg}")
            continue
        nid = data.get("id") if isinstance(data, dict) else None
        if nid not in base:
            errors.append(f"{rel}：找不到 id「{nid}」（id 不能改）")
            continue
        if nid in seen:
            errors.append(f"{rel}：和 {seen[nid]} 是同一個分類（id 重複）")
            continue
        seen[nid] = rel
        data["_file"] = str(rel)
    for nid in base:
        if nid not in seen:
            warnings.append(f"找不到「{base[nid]['nameZh']}」（{nid}）的檔案，沿用內建設定")

    # 讀出每個分類的設定
    proposed = {}
    for f in sorted(folder.rglob("*.json")):
        if f.name == "全域門檻.json" or f.name.startswith("."):
            continue
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        nid = data.get("id") if isinstance(data, dict) else None
        if nid not in base or seen.get(nid) != f.relative_to(folder):
            continue
        n = base[nid]
        rel = f.relative_to(folder)
        fields = NODE_FIELDS if n["level"] == 3 else L12_FIELDS
        values = {}
        for zh, key in fields:
            if zh not in data:
                errors.append(f"{rel}：少了「{zh}」")
                continue
            values[key] = data[zh]
        proposed[nid] = (rel, values)

    for nid, (rel, v) in proposed.items():
        n = base[nid]
        for key in ("nameZh", "nameEn"):
            if key in v and (not isinstance(v[key], str) or not v[key].strip()):
                errors.append(f"{rel}：名稱不能是空的")
        if n["level"] < 3:
            continue
        mode = v.get("recognition", n["recognition"])
        if mode not in RECOGNITION:
            errors.append(f"{rel}：辨識方式要是 {'、'.join(RECOGNITION)} 其中之一")
            continue
        if mode == "derived" and n["recognition"] != "derived":
            errors.append(f"{rel}：不能改成 derived（組合推論要寫在程式裡）")
        if n["recognition"] == "derived" and mode != "derived":
            errors.append(f"{rel}：組合推論的分類不能改辨識方式")
        for key, zh in (("prompts", "提示詞"), ("confusers", "容易誤認的畫面"), ("suppressedBy", "被這些分類排除")):
            items = v.get(key, [])
            if not isinstance(items, list) or not all(isinstance(x, str) and x.strip() for x in items):
                errors.append(f"{rel}：「{zh}」要是一串文字，例如 [\"a cat\", \"a kitten\"]，不能有空白的項目")
        if mode in ("visual", "assisted") and not v.get("prompts"):
            errors.append(f"{rel}：{mode} 至少要有一個提示詞")
        if v.get("confusers") and mode not in ("visual", "assisted"):
            errors.append(f"{rel}：只有 visual、assisted 的分類能設定「容易誤認的畫面」")
        for ref in v.get("suppressedBy", []) if isinstance(v.get("suppressedBy"), list) else []:
            if ref not in base:
                errors.append(f"{rel}：「被這些分類排除」裡的 {ref} 不存在（要填分類的 id）")
        score = v.get("acceptScore")
        if score is not None and (not isinstance(score, (int, float)) or isinstance(score, bool) or not 0.1 <= score <= 0.5):
            errors.append(f"{rel}：門檻要是 0.1～0.5 的數字，或 null（用全域門檻）")
        for key, zh in (("distinct", "一眼看得出來"), ("enabledByDefault", "預設開啟")):
            if key in v and not isinstance(v[key], bool):
                errors.append(f"{rel}：「{zh}」要填 true 或 false")
        for p in v.get("prompts", []) if isinstance(v.get("prompts"), list) else []:
            if re.search(r"[一-鿿]", p):
                warnings.append(f"{rel}：提示詞「{p}」有中文；照片比對的模型（MobileCLIP）只懂英文，建議寫英文")

    # 全域門檻
    thresholds_tuning = {}
    tf = folder / "全域門檻.json"
    if tf.exists():
        try:
            tdata = json.loads(tf.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            errors.append(f"全域門檻.json：JSON 格式錯誤（第 {e.lineno} 行）：{e.msg}")
            tdata = {}
        for zh, key, typ, (lo, hi), _ in THRESHOLD_FIELDS:
            if zh not in tdata:
                continue
            value = tdata[zh]
            ok = isinstance(value, (int, float)) and not isinstance(value, bool) and lo <= value <= hi
            if typ is int and ok and value != int(value):
                ok = False
            if not ok:
                errors.append(f"全域門檻.json：「{zh}」要是 {lo}～{hi} 的{'整數' if typ is int else '數字'}")
                continue
            value = typ(value)
            if abs(value - defaults[key]) > 1e-9:
                thresholds_tuning[key] = value

    if errors:
        print("❌ 有錯誤，沒有套用（App 維持原本的設定）：")
        for e in errors:
            print("  ・" + e)
        return False

    # 和內建設定比較，只留下改過的地方
    tuned_nodes = {}
    changes = []
    for nid, (rel, v) in proposed.items():
        n = base[nid]
        diff = {}
        for key, value in v.items():
            if key == "acceptScore":
                if value is not None:
                    diff[key] = float(value)
            elif value != n[key]:
                diff[key] = value
        if diff:
            tuned_nodes[nid] = diff
            changes.append(f"{n['nameZh']}（{nid}）：" + "、".join(_field_zh(k) for k in diff))
    tuning = {}
    if tuned_nodes:
        tuning["nodes"] = tuned_nodes
    if thresholds_tuning:
        tuning["thresholds"] = thresholds_tuning

    # 套用後的目錄要能通過 App 的檢查（suppressedBy 指到的分類存在、可辨識的分類有提示詞…）
    text = json.dumps(tuning, ensure_ascii=False, indent=2, sort_keys=True) if tuning else "{}"
    if '"""##' in text:
        print("❌ 內容裡有 \"\"\"## 這串字，無法寫入")
        return False

    for w in warnings:
        print("⚠️ " + w)
    if not tuning:
        print("沒有任何和內建設定不同的地方。")
    else:
        print(f"和內建設定不同的地方（{len(tuned_nodes)} 個分類" + ("、全域門檻" if thresholds_tuning else "") + "）：")
        for c in changes:
            print("  ・" + c)
        for key, value in thresholds_tuning.items():
            zh = next(z for z, k, *_ in THRESHOLD_FIELDS if k == key)
            print(f"  ・全域門檻「{zh}」：{defaults[key]} → {value}")
    old = read_tuning()
    if old == tuning:
        print("App 裡已經是這個設定，不用更新。")
        return True
    if dry_run:
        print("（只檢查，沒有寫入）")
        return True
    TUNING_SWIFT.write_text(TUNING_TEMPLATE.format(json=text), encoding="utf-8")
    print(f"\n✅ 已寫入 {TUNING_SWIFT}")
    print("在 Xcode 重新建置、安裝到手機後生效：App 會更新分類名稱與提示詞，並用既有照片向量重新比對自動標籤（手動標籤不受影響）。")
    return True


def _field_zh(key):
    for zh, k in NODE_FIELDS:
        if k == key:
            return zh
    return key


TUNING_TEMPLATE = '''// TaxonomyTuningData.swift
//
// ⚠️ 這個檔案由桌面「相簿主題設定」資料夾裡的「套用到App.py」自動產生，請不要手動修改。
// 內容是你在資料夾裡改過的地方（和內建設定不同的欄位）；{{}} 代表沒有任何調整。
// 說明見 TaxonomyTuning.swift。

enum TaxonomyTuningData {{
    static let json = ##"""
{json}
"""##
}}
'''

WRAPPER = '''#!/usr/bin/env python3
# 在「終端機」執行：python3 "{{這個檔案的路徑}}"（也可以把檔案拖進終端機視窗）
# 預設 App 專案在桌面的 ml-mobileclip/ios_app；不在那裡時，執行時把 ios_app 的路徑加在最後面。
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
ios_app = Path(sys.argv[1]) if len(sys.argv) > 1 else here.parent / "ml-mobileclip" / "ios_app"
script_dir = ios_app / "PersonalizationCore" / "Scripts"
if not (script_dir / "taxonomy_folder.py").exists():
    sys.exit(f"找不到 App 專案：{{ios_app}}\\n請在指令最後加上 ios_app 資料夾的路徑。")
sys.dont_write_bytecode = True   # 不在 App 專案裡留下 __pycache__
sys.path.insert(0, str(script_dir))
import taxonomy_folder

ok = taxonomy_folder.{command}(here)
sys.exit(0 if ok in (None, True) else 1)
'''

README = """# 相簿主題設定

這個資料夾是 App「主題分類」的設定，依 **大分類 › 中分類 › 小分類** 排列，每個小分類一個資料夾。
改完之後執行 `套用到App.py`，再用 Xcode 重新建置、安裝到手機就會生效。

## 資料夾裡有什麼

- 大分類資料夾裡的 `_大分類.json`、中分類資料夾裡的 `_中分類.json`：只能改名稱。
- 小分類資料夾裡的 `設定.json`：門檻、提示詞等設定（見下表）。
- 小分類資料夾裡可以放這個分類的**範例照片**（應該被分進來的、或被分錯進來的），方便你對照著調整。
  套用腳本只讀 `.json` 檔，照片不會被修改，也不會被放進 App。

## 怎麼改

用「文字編輯」或 VS Code 打開小分類資料夾裡的 `設定.json`，可以改這些欄位：

| 欄位 | 說明 |
|---|---|
| 中文名稱、英文名稱 | App 裡顯示的名稱 |
| 辨識方式 | `visual` 看畫面就判斷、自動標上；`assisted` 只會成為「待確認」問你；`manualOnly` 只能手動加入；`derived` 組合推論（不能改） |
| 門檻 | 這個分類自己的門檻，`null` 代表用 `全域門檻.json` 的「確認門檻」（0.25）。調高＝比較嚴格、標得比較少；通常在 0.20～0.32 之間調 |
| 提示詞 | 給照片比對模型（MobileCLIP）的**英文**描述，例如 `"a cat sleeping on a sofa"`。照片像其中任何一句就算分數。描述「畫面上看得到什麼」最有效 |
| 容易誤認的畫面 | 常被誤認成這個分類的畫面（英文）。照片比較像這些時，這個分類不會標上 |
| 被這些分類排除 | 填其他分類的 **id**。那些分類一樣像或更像時，這個分類不標 |
| 一眼看得出來 | `true`：就算你沒選這個大分類、或照片裡還有別的東西，也照樣標上（貓、狗用這個） |
| 預設開啟 | 選大分類時，這個小分類要不要預設打開 |

「參考（不用改）」裡是位置、目前實際門檻等資訊，改了也不會有作用。

`id` 不能改；JSON 的格式要正確（字串用雙引號、項目之間用逗號、最後一項後面不要有逗號）。

## 套用

打開「終端機」，輸入 `python3 ` （後面有一個空白），把 `套用到App.py` 拖進視窗，按 Enter。

- 有錯誤時會列出哪個檔案、哪裡錯，**不會**寫入任何東西。
- 沒問題時會列出你改了哪些分類，並更新 App 專案裡的 `TaxonomyTuningData.swift`（只記錄和內建設定不同的地方）。
- 想全部還原：用 `重新整理資料夾.py` 之前，先把 App 專案的 `TaxonomyTuningData.swift` 內容改回 `{}`，或把資料夾刪掉重新產生。

## 生效之後

- 手機上的 App 會更新分類名稱與提示詞（新的提示詞會在手機上算文字向量），並用既有的照片向量重新比對**自動**標籤。
- 不會重新分析照片、不會改到手動加的標籤、不會動到任何照片。
- 你在 App 裡回答「是／不是」的學習結果照常有效。

## 重新整理資料夾

App 的內建分類有新增或改版時，執行 `重新整理資料夾.py`：會加入新的分類、更新「參考」資訊，
已套用的調整會保留；還沒套用的修改也不會被覆蓋（會列出來提醒你）。
分類改名時，資料夾會跟著改名，你放在裡面的照片會一起搬過去，不會刪除任何檔案。
（資料夾裡隱藏的 `.上次匯出.json` 是用來分辨「你改過的地方」，請不要刪除。）
"""


def main(argv):
    if len(argv) < 3 or argv[1] not in ("export", "apply", "check"):
        print(__doc__)
        return 2
    if argv[1] == "export":
        export(argv[2])
        return 0
    ok = apply(argv[2], dry_run=argv[1] == "check")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

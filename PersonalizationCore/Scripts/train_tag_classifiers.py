#!/usr/bin/env python3
"""selfIE 分類判斷器訓練（在 Mac 上執行）

把組員從 App「設定 › 協助訓練分類」匯出的標記檔（selfIE標記_*.json）合併，
替每個分類訓練一個小型判斷器（邏輯斯迴歸），寫進 App 的 TagClassifierData.swift。

- 標記檔只有照片向量（512 個數字）和「是／不是」，不含照片。
- 只需要 numpy（評估腳本的 .venv312 裡已經有），不用裝其他套件。
- 每個分類「是」至少 15 張、「不是」至少 15 張才訓練；不夠的分類 App 照舊用文字描述比對。
- 用 5 折交叉驗證選門檻：在準確率（Precision）≥ 目標（預設 90%）的門檻中，選召回率最高的。
  驗證後達不到目標的分類不放進 App。
- 結果另外寫成報告（classifier_report.md），列出每個分類的準確率、召回率與張數。
- 公開資料集（tag_threshold_eval.py labels 輸出的「公開資料集_OpenImages.json」）也放在同一個資料夾就會一起用：
  · 公開資料的權重比你的標記低（網路照片和手機隨手拍的照片風格不同），預設 0.5
  · 你標的照片夠多的分類：門檻只用「你的照片」驗證；加了公開資料、召回率沒有比較高就不用
  · 你標的照片不夠、只靠公開資料的分類：準確率要 95% 以上；你有標過幾張的話，在你的照片上也要達到目標；
    不設「一定不是」的門檻（網路照片驗證出來的門檻不一定適合你的照片，避免把你的照片誤擋掉）；
    召回率低於 30% 的不放；要照片文字佐證的分類（收據、票根…）不會只靠公開資料（一定要用你標的照片訓練）

用法：
  python3 train_tag_classifiers.py                         # 讀 ~/Desktop/selfIE標記資料 裡的所有 .json
  python3 train_tag_classifiers.py 資料夾或檔案 ...
  python3 train_tag_classifiers.py --dry-run               # 只看結果，不寫入 App
  python3 train_tag_classifiers.py --precision 0.85        # 改準確率目標
  python3 train_tag_classifiers.py --no-public             # 不用公開資料集
"""

import argparse
import base64
import datetime
import hashlib
import json
import sys
from pathlib import Path

try:
    import numpy as np
except ImportError:
    sys.exit("需要 numpy。請用評估腳本的環境執行：PersonalizationCore/Scripts/.venv312/bin/python3 train_tag_classifiers.py")

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_SWIFT = SCRIPT_DIR.parent / "Sources" / "PersonalizationCore" / "TagClassifierData.swift"
REPORT = SCRIPT_DIR / "classifier_report.md"
DEFAULT_INPUT = Path.home() / "Desktop" / "selfIE標記資料"
FORMAT = "selfie-labels-1"
# 組員共用網頁「下載全部標記檔」合併成的一個檔案：{"format": BUNDLE_FORMAT, "files": [標記檔, ...]}
BUNDLE_FORMAT = "selfie-labels-bundle-1"

MIN_POSITIVE = 15
MIN_NEGATIVE = 15
FOLDS = 5
# 其他分類的「是」當作這個分類的「不是」時的權重（不一定真的不是，所以權重低）
OTHER_POSITIVE_WEIGHT = 0.3
# 公開資料集：明確的是／不是的權重；其他分類的「是」當作不是時的權重；每個分類最多用幾張
PUBLIC_WEIGHT = 0.5
PUBLIC_OTHER_WEIGHT = 0.1
MAX_PUBLIC_OTHERS = 3000
# 只靠公開資料的分類：準確率目標至少這麼高
PUBLIC_ONLY_PRECISION = 0.95
# 你標過的照片至少幾張，才拿來檢查只靠公開資料訓練的判斷器
MIN_USER_CHECK = 6
# 只靠公開資料的分類：召回率太低的不放（幾乎不會標上任何照片，放了只是多一個可能誤判的地方）
MIN_PUBLIC_ONLY_RECALL = 0.3


def is_public_doc(doc, who):
    return doc.get("source") == "public-dataset" or str(who).startswith("公開資料集")


# ───────────── 讀檔 ─────────────

def read_label_files(paths, use_public=True):
    """回傳 ({(照片, 分類): 是否}, 向量 {照片: np.array}, 每個人的張數, 向量長度, 公開資料集的照片)"""
    files = []
    for p in paths:
        p = Path(p).expanduser()
        if p.is_dir():
            files += sorted(p.glob("*.json"))
        elif p.suffix == ".json":
            files.append(p)
    if not files:
        sys.exit(f"找不到標記檔。請把組員匯出的 selfIE標記_*.json 放進：{DEFAULT_INPUT}")

    labels, vectors, contributors = {}, {}, {}
    public = set()
    dim = None
    # 每個標記檔（合併檔裡的每一份也算一個）
    docs = []
    for f in files:
        try:
            doc = json.loads(f.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"⚠️ 略過 {f.name}：不是正確的 JSON（{e}）")
            continue
        if doc.get("format") == BUNDLE_FORMAT:
            for i, sub in enumerate(doc.get("files", [])):
                docs.append((f"{f.name}#{i + 1}", sub))
        else:
            docs.append((f.name, doc))
    # 舊的匯出先讀、新的後讀：同一張照片同一個分類以新的答案為準
    docs.sort(key=lambda item: str(item[1].get("exportedAt", "")))
    for name, doc in docs:
        if doc.get("format") != FORMAT:
            print(f"⚠️ 略過 {name}：不是 selfIE 的標記檔")
            continue
        if dim is None:
            dim = doc.get("dimension")
        elif doc.get("dimension") != dim:
            print(f"⚠️ 略過 {name}：向量長度 {doc.get('dimension')} 和其他檔案（{dim}）不同，可能是不同版本的 App")
            continue
        who = doc.get("contributor") or name
        from_public = is_public_doc(doc, who)
        if from_public and not use_public:
            print(f"・ 略過 {name}：公開資料集（--no-public）")
            continue
        count = 0
        for item in doc.get("items", []):
            try:
                vec = np.frombuffer(base64.b64decode(item["e"]), dtype="<f4").astype(np.float64)
            except Exception:
                continue
            if vec.size != dim:
                continue
            norm = np.linalg.norm(vec)
            if norm == 0:
                continue
            # 照片 ID 已經雜湊過；加上是誰的照片，不同人的照片不會撞在一起
            key = f"{who}:{item['id']}"
            vectors[key] = vec / norm
            labels[(key, item["node"])] = bool(item["label"])
            if from_public:
                public.add(key)
            count += 1
        contributors[who] = contributors.get(who, 0) + count
        print(f"讀取 {name}：{who}，{count} 筆")
    return labels, vectors, contributors, dim, public


# ───────────── 訓練 ─────────────

def train_logistic(X, y, w_sample, l2=1e-3, iters=600, lr=0.1):
    """加權、L2 正則化的邏輯斯迴歸（Adam），回傳 (w, b)"""
    n, d = X.shape
    w = np.zeros(d)
    b = 0.0
    m_w = np.zeros(d); v_w = np.zeros(d); m_b = 0.0; v_b = 0.0
    beta1, beta2, eps = 0.9, 0.999, 1e-8
    total = w_sample.sum()
    for t in range(1, iters + 1):
        z = X @ w + b
        p = 1 / (1 + np.exp(-np.clip(z, -30, 30)))
        g = (p - y) * w_sample
        grad_w = X.T @ g / total + l2 * w
        grad_b = g.sum() / total
        m_w = beta1 * m_w + (1 - beta1) * grad_w
        v_w = beta2 * v_w + (1 - beta2) * grad_w ** 2
        m_b = beta1 * m_b + (1 - beta1) * grad_b
        v_b = beta2 * v_b + (1 - beta2) * grad_b ** 2
        w -= lr * (m_w / (1 - beta1 ** t)) / (np.sqrt(v_w / (1 - beta2 ** t)) + eps)
        b -= lr * (m_b / (1 - beta1 ** t)) / (np.sqrt(v_b / (1 - beta2 ** t)) + eps)
    return w, b


def sigmoid(z):
    return 1 / (1 + np.exp(-np.clip(z, -30, 30)))


def fold_of(key, folds):
    return int(hashlib.md5(key.encode()).hexdigest(), 16) % folds


def choose_threshold(prob, y, target_precision):
    """準確率 ≥ 目標的門檻中選召回率最高的（y 是 0/1）"""
    best = None
    for t in np.unique(np.round(prob, 3)):
        pred = prob >= t
        tp = int((pred & (y == 1)).sum())
        fp = int((pred & (y == 0)).sum())
        fn = int((~pred & (y == 1)).sum())
        if tp == 0:
            continue
        precision = tp / (tp + fp)
        recall = tp / (tp + fn)
        # 召回率最高；一樣高時選準確率較高的（門檻比較嚴）
        if precision >= target_precision and (best is None or (recall, precision) > (best[2], best[1])):
            best = (float(t), precision, recall)
    return best


def reject_threshold(prob, y, keep_recall=0.95):
    """「一定不是」的門檻：機率低於它的照片拿掉，同時保留至少 keep_recall 的「是」"""
    pos = np.sort(prob[y == 1])
    if pos.size == 0:
        return 0.0
    index = int(np.floor((1 - keep_recall) * pos.size))
    return float(max(0.0, pos[min(index, pos.size - 1)] - 1e-4))


def build_dataset(node, labels, vectors, public):
    """這個分類的訓練資料：
    - 明確的是／不是：你的標記權重 1、公開資料集 PUBLIC_WEIGHT
    - 其他分類的「是」當作不是：你的照片 OTHER_POSITIVE_WEIGHT、公開資料集 PUBLIC_OTHER_WEIGHT（最多 MAX_PUBLIC_OTHERS 張）"""
    explicit = {k: v for (k, n), v in labels.items() if n == node}
    keys, ys, ws, explicit_flags = [], [], [], []
    for k, v in explicit.items():
        keys.append(k); ys.append(1.0 if v else 0.0); ws.append(PUBLIC_WEIGHT if k in public else 1.0)
        explicit_flags.append(True)
    others = {k for (k, n), v in labels.items() if v and n != node and k not in explicit}
    public_others = sorted((k for k in others if k in public),
                           key=lambda k: hashlib.md5(f"{node}|{k}".encode()).hexdigest())[:MAX_PUBLIC_OTHERS]
    for k in sorted(k for k in others if k not in public):
        keys.append(k); ys.append(0.0); ws.append(OTHER_POSITIVE_WEIGHT); explicit_flags.append(False)
    for k in sorted(public_others):
        keys.append(k); ys.append(0.0); ws.append(PUBLIC_OTHER_WEIGHT); explicit_flags.append(False)
    if not keys:
        return None
    X = np.stack([vectors[k] for k in keys])
    return keys, X, np.array(ys), np.array(ws), np.array(explicit_flags), np.array([k in public for k in keys])


def balance(y, w):
    """「是」和「不是」的總權重一樣，少的那邊不會被忽略"""
    pos = w[y == 1].sum(); neg = w[y == 0].sum()
    if pos == 0 or neg == 0:
        return w
    out = w.copy()
    out[y == 1] *= (pos + neg) / (2 * pos)
    out[y == 0] *= (pos + neg) / (2 * neg)
    return out


def cross_val(keys, X, y, w, evaluate):
    """5 折交叉驗證：evaluate 為 True 的照片分成 5 份，每份的機率都來自「沒看過它」的模型；
    其他照片（例如驗證只看你的照片時的公開資料）每一折都拿來訓練。回傳每張照片的機率（沒算到的是 nan）"""
    folds = np.array([fold_of(k, FOLDS) if e else -1 for k, e in zip(keys, evaluate)])
    oof = np.full(len(keys), np.nan)
    for f in range(FOLDS):
        test = folds == f
        train = ~test
        if test.sum() == 0 or (y[train] == 1).sum() == 0 or (y[train] == 0).sum() == 0:
            continue
        wf, bf = train_logistic(X[train], y[train], balance(y[train], w[train]))
        oof[test] = sigmoid(X[test] @ wf + bf)
    return oof


def precision_at(prob, y, threshold):
    pred = prob >= threshold
    tp = int((pred & (y == 1)).sum()); fp = int((pred & (y == 0)).sum())
    return (tp / (tp + fp)) if tp + fp else None


def pack(w_final, b_final, threshold, reject, precision, recall, counts, source, user_only_recall=None):
    out = {
        "w": base64.b64encode(w_final.astype("<f4").tobytes()).decode(),
        "b": round(float(b_final), 6),
        "t": round(threshold, 4),
        "r": round(reject, 4),
        "precision": round(precision, 4),
        "recall": round(recall, 4),
        "source": source,
    }
    out.update(counts)
    if user_only_recall is not None:
        out["user_only_recall"] = round(user_only_recall, 4)
    return out


def train_node(node, labels, vectors, target_precision, public=frozenset(), text_only=frozenset()):
    data = build_dataset(node, labels, vectors, public)
    if data is None:
        return None, "沒有資料"
    keys, X, y, w, explicit, pub = data
    mine = ~pub
    u_pos = int((explicit & mine & (y == 1)).sum()); u_neg = int((explicit & mine & (y == 0)).sum())
    p_pos = int((explicit & pub & (y == 1)).sum()); p_neg = int((explicit & pub & (y == 0)).sum())
    counts = {"positive": u_pos, "negative": u_neg, "public_positive": p_pos, "public_negative": p_neg}
    u_neg_total = int((mine & (y == 0)).sum())
    user_enough = u_pos >= MIN_POSITIVE and (u_neg >= MIN_NEGATIVE or u_neg_total >= MIN_NEGATIVE * 2)

    if user_enough:
        # 只用你的照片驗證（評估用：明確標記的照片＋其他分類的「是」當作不是）。
        # a. 只用你的標記訓練；b. 加上公開資料訓練。b 的召回率不比 a 低才用 b
        mk = [k for k, m in zip(keys, mine) if m]
        oof_a = cross_val(mk, X[mine], y[mine], w[mine], [True] * len(mk))
        a = choose_threshold(np.nan_to_num(oof_a), y[mine], target_precision)
        b, oof_b = None, None
        if p_pos > 0:
            oof_b = cross_val(keys, X, y, w, mine)
            b = choose_threshold(np.nan_to_num(oof_b[mine]), y[mine], target_precision)
        if b is not None and (a is None or b[2] >= a[2]):
            threshold, precision, recall = b
            ue = explicit[mine]
            reject = min(reject_threshold(np.nan_to_num(oof_b[mine])[ue], y[mine][ue]), threshold)
            w_final, b_final = train_logistic(X, y, balance(y, w))
            return pack(w_final, b_final, threshold, reject, precision, recall, counts, "你的標記＋公開資料",
                        user_only_recall=a[2] if a else 0.0), None
        if a is None:
            return None, f"驗證後準確率達不到 {target_precision:.0%}（是 {u_pos}、不是 {u_neg}）"
        threshold, precision, recall = a
        ue = explicit[mine]
        reject = min(reject_threshold(np.nan_to_num(oof_a)[ue], y[mine][ue]), threshold)
        w_final, b_final = train_logistic(X[mine], y[mine], balance(y[mine], w[mine]))
        return pack(w_final, b_final, threshold, reject, precision, recall, counts, "你的標記"), None

    if node in text_only and p_pos:
        return None, (f"要照片文字佐證的分類不會只靠公開資料（你的 是 {u_pos}、不是 {u_neg}；"
                      f"需要各 {MIN_POSITIVE} 張以上）")
    if p_pos >= MIN_POSITIVE and (y == 0).sum() >= MIN_NEGATIVE * 2:
        # 只靠公開資料：用全部照片驗證，準確率目標提高；你標過的照片也要過
        target = max(target_precision, PUBLIC_ONLY_PRECISION)
        oof = np.nan_to_num(cross_val(keys, X, y, w, [True] * len(keys)))
        chosen = choose_threshold(oof, y, target)
        if chosen is None:
            return None, f"只有公開資料（是 {p_pos}、不是 {p_neg}），驗證後準確率達不到 {target:.0%}"
        threshold, precision, recall = chosen
        if recall < MIN_PUBLIC_ONLY_RECALL:
            return None, (f"只有公開資料：準確率 {target:.0%} 時召回率只有 {recall:.0%}（網路照片太雜），不放進 App")
        ue = explicit & mine
        if u_pos + u_neg >= MIN_USER_CHECK:
            mine_precision = precision_at(oof[ue], y[ue], threshold)
            if mine_precision is not None and mine_precision < target_precision:
                return None, (f"只有公開資料：在你標的 {u_pos + u_neg} 張照片上準確率只有 {mine_precision:.0%}"
                              f"（網路照片和你的照片差太多），不放進 App")
        w_final, b_final = train_logistic(X, y, balance(y, w))
        result = pack(w_final, b_final, threshold, 0.0, precision, recall, counts, "只有公開資料")
        # 在你標過的照片上（訓練有用到，所以只是參考）：「是」標到幾張、「不是」誤標幾張
        if ue.any():
            prob = sigmoid(X[ue] @ w_final + b_final)
            result["mine_hit"] = f"{int(((prob >= threshold) & (y[ue] == 1)).sum())}/{u_pos}"
            result["mine_false"] = f"{int(((prob >= threshold) & (y[ue] == 0)).sum())}/{u_neg}"
        # 不設「一定不是」的門檻（reject = 0）：網路照片驗證出來的不一定適合你的照片
        return result, None

    reason = f"資料不夠（是 {u_pos}、不是 {u_neg}；需要各 {MIN_POSITIVE} 張以上）"
    if p_pos:
        reason += f"；公開資料 是 {p_pos}"
    return None, reason


# ───────────── 輸出 ─────────────

def node_info():
    """從 TaxonomyCatalog（＋TaxonomyTuningData）讀：中文名稱（報告用；讀不到就用 id）、要照片文字佐證的分類、
    可以訓練的分類（看畫面判斷的小分類；None＝讀不到目錄，全部都訓練）"""
    names, text_only, trainable = {}, set(), None
    try:
        sys.path.insert(0, str(SCRIPT_DIR))
        import taxonomy_folder  # 同一個資料夾的工具
        _, nodes = taxonomy_folder.parse_catalog()
        trainable = set()
        for n in nodes:
            names[n["id"]] = n["nameZh"]
            if n.get("requiresText"):
                text_only.add(n["id"])
            if n["level"] == 3 and n["recognition"] in ("visual", "assisted"):
                trainable.add(n["id"])
        try:
            for n in taxonomy_folder.effective_nodes(nodes, taxonomy_folder.read_tuning()):
                names[n["id"]] = n["nameZh"]
        except Exception:
            pass
    except Exception:
        # 讀不到分類目錄時，至少保護這幾個
        text_only = {"receipt", "boarding_pass"}
    return names, text_only, trainable


def node_redirects():
    """TaxonomyCatalog.swift 的 nodeRedirects：已移除或合併的分類 → 取代它的分類"""
    import re
    try:
        src = (SCRIPT_DIR.parent / "Sources" / "PersonalizationCore" / "TaxonomyCatalog.swift").read_text(encoding="utf-8")
        body = src.split("static let nodeRedirects", 1)[1].split("\n    ]", 1)[0]
        return dict(re.findall(r'^\s*"(\w+)":\s*"(\w+)",', body, re.M))
    except Exception:
        return {}


# 合併前的「不是」也搬過去的舊分類：標「不是票根」的照片幾乎都是收據、卡片、文件這類紙張，
# 也不是電影；這些正是判斷器最需要的「容易搞混的例子」，不搬的話電影會把各種紙張都當成票根
KEEP_NEGATIVES_FROM = {"ticket_stub"}
# 個別分類的準確率目標（比 --precision 嚴格）：電影誤標很明顯（文件、卡片被當成票根），寧可少標一點
NODE_PRECISION = {"movie": 0.95}


def apply_redirects(labels, redirects, trainable):
    """舊的分類 ID 換成取代它的分類（例如 v21 小卡、徽章 → 周邊小物）：
    - 「是」搬過去（是小卡 → 是周邊小物）
    - 「不是」不搬（不是小卡的照片可能是徽章，不代表不是周邊小物）；KEEP_NEGATIVES_FROM 例外
    - 換完不是可以訓練的分類（已移除、或併到中分類）就不用"""
    out, moved, dropped = {}, 0, 0
    for (key, node), value in labels.items():
        target, seen = node, set()
        while target in redirects and target not in seen:
            seen.add(target)
            target = redirects[target]
        if target != node:
            if not value and node not in KEEP_NEGATIVES_FROM:
                dropped += 1
                continue
            moved += 1
        if trainable is not None and target not in trainable:
            dropped += 1
            continue
        # 同一張照片在合併後的分類同時有是／不是時，以「是」為準
        out[(key, target)] = out.get((key, target), False) or value
    if moved or dropped:
        print(f"舊分類 ID：{moved} 筆搬到合併後的分類；{dropped} 筆不用（合併前的「不是」、已移除的分類）")
    return out


def write_swift(classifiers, version):
    payload = json.dumps({"classifiers": {k: {"w": v["w"], "b": v["b"], "t": v["t"], "r": v["r"]} for k, v in sorted(classifiers.items())}},
                         ensure_ascii=False, separators=(",", ":"))
    OUTPUT_SWIFT.write_text(f'''// TagClassifierData.swift
//
// ⚠️ 這個檔案由 Scripts/train_tag_classifiers.py 自動產生，請不要手動修改。
// 內容是用組員標記的照片（是／不是）訓練出來的分類判斷器（每個分類一組權重）；{{}} 代表還沒有訓練。
// 說明見 MultiLabelTagger.swift 的 LearnedTagClassifier。
// 產生時間：{datetime.datetime.now().strftime("%Y-%m-%d %H:%M")}，{len(classifiers)} 個分類。

enum TagClassifierData {{
    static let version = "{version}"
    static let json = ##"""
{payload}
"""##
}}
''', encoding="utf-8")


def write_report(results, skipped, contributors, target_precision, names):
    lines = ["# 分類判斷器訓練結果", "",
             f"- 時間：{datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}",
             f"- 準確率目標：{target_precision:.0%}（用 5 折交叉驗證選門檻）",
             "- 標記資料：" + "、".join(f"{k} {v} 筆" for k, v in contributors.items()), "",
             "## 放進 App 的分類", "",
             "- 準確率、召回率：判斷器單獨判斷時的表現。App 裡判斷器只負責「很確定是」和「一定不是」，中間的照片照舊用文字描述比對。",
             "- 來源是「你的標記」或「你的標記＋公開資料」的分類，數字是在你的照片上驗證的；「只有公開資料」的分類是在網路照片上驗證的，"
             "放到你的照片上通常會差一些。",
             "- 只用你的標記：同一個分類只用你的標記訓練時的召回率（加了公開資料才比較得出來）。",
             "- 你的照片：只靠公開資料的分類，在你標過的照片上「是」標到幾張、「不是」誤標幾張（只是參考，張數很少）。", "",
             "| 分類 | 來源 | 你的 是／不是 | 公開 是／不是 | 準確率 | 召回率 | 只用你的標記 | 你的照片 | 標上門檻 | 拿掉門檻 |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for node, r in sorted(results.items(), key=lambda kv: (kv[1].get("source") == "只有公開資料", -kv[1]["recall"])):
        only = f"{r['user_only_recall']:.0%}" if "user_only_recall" in r else "—"
        mine = f"是 {r['mine_hit']}、誤標 {r['mine_false']}" if "mine_hit" in r else "—"
        lines.append(f"| {names.get(node, node)}（{node}） | {r.get('source', '你的標記')} | {r['positive']}／{r['negative']} | "
                     f"{r.get('public_positive', 0)}／{r.get('public_negative', 0)} | {r['precision']:.0%} | {r['recall']:.0%} | "
                     f"{only} | {mine} | {r['t']:.3f} | {r['r']:.3f} |")
    if not results:
        lines.append("| （沒有） | | | | | | | | | |")
    lines += ["", "## 沒有放進 App 的分類（照舊用文字描述比對）", ""]
    for node, reason in sorted(skipped.items()):
        lines.append(f"- {names.get(node, node)}（{node}）：{reason}")
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv):
    parser = argparse.ArgumentParser(description="合併組員的標記檔，訓練每個分類的判斷器")
    parser.add_argument("inputs", nargs="*", default=[str(DEFAULT_INPUT)], help="標記檔或資料夾")
    parser.add_argument("--precision", type=float, default=0.9, help="準確率目標（預設 0.9）")
    parser.add_argument("--dry-run", action="store_true", help="只顯示結果，不寫入 App")
    parser.add_argument("--no-public", action="store_true", help="不用公開資料集（公開資料集_*.json）")
    args = parser.parse_args(argv)

    labels, vectors, contributors, dim, public = read_label_files(args.inputs, use_public=not args.no_public)
    names, text_only, trainable = node_info()
    labels = apply_redirects(labels, node_redirects(), trainable)
    nodes = sorted({n for (_, n) in labels})
    print(f"\n共 {len(vectors)} 張照片、{len(labels)} 筆回答、{len(nodes)} 個分類、向量長度 {dim}\n")

    results, skipped = {}, {}
    for node in nodes:
        result, reason = train_node(node, labels, vectors, max(args.precision, NODE_PRECISION.get(node, 0)), public, text_only)
        label = f"{names.get(node, node)}（{node}）"
        if result:
            results[node] = result
            print(f"✅ {label}：{result['source']}，準確率 {result['precision']:.0%}、召回率 {result['recall']:.0%}"
                  f"（你的 是 {result['positive']}、不是 {result['negative']}；公開 是 {result['public_positive']}）")
        else:
            skipped[node] = reason
            print(f"・ {label}：{reason}")

    write_report(results, skipped, contributors, args.precision, names)
    print(f"\n報告：{REPORT}")
    if args.dry_run:
        print("（--dry-run：沒有寫入 App）")
        return
    digest = hashlib.md5(json.dumps({k: v["w"] for k, v in results.items()}, sort_keys=True).encode()).hexdigest()[:8]
    version = f"{datetime.date.today():%Y%m%d}-{digest}" if results else ""
    write_swift(results, version)
    print(f"✅ 已寫入 {OUTPUT_SWIFT}（{len(results)} 個分類）")
    print("在 Xcode 重新建置、安裝到手機後生效：App 會用既有照片向量重新分類（手動標籤不受影響）。")


if __name__ == "__main__":
    main(sys.argv[1:])

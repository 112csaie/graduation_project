#!/usr/bin/env python3
"""selfIE 提示詞評估（在 Mac 上執行）：替還沒有判斷器的分類挑出最好的提示詞、容易誤認的畫面與門檻

App 判斷一張照片是不是某個分類：照片向量和這個分類每條提示詞（"a photo of …"）的相似度取最高分，
分數夠高、而且不比「容易誤認的畫面」低，就標上。沒有判斷器的分類（或判斷器沒把握的照片）完全靠這些提示詞。

這支程式：
  1. 用 App 內附的文字模型（Core ML，需要 macOS）把候選提示詞轉成向量（算過的存快取）
  2. 拿已經有答案的照片測：你標過的照片（桌面 selfIE標記資料）；你標得太少的分類，加上公開資料集
  3. 每個分類用「逐條加入」的方式挑提示詞（最多 4 條）和容易誤認的畫面（最多 5 條）：
     在準確率 ≥ 目標（預設 90%）的門檻中，召回率最高的組合
  4. 寫成報告（prompt_tuning_report.md）；加上 --write-folder 才把「有變好」的分類寫進「相簿主題設定」資料夾
     （之後照平常執行 套用到App.py 套用；不想要的分類，把那個資料夾的 設定.json 改回來就好）

用法（在 PersonalizationCore/Scripts 資料夾）：
  .venv312/bin/python3 prompt_tuning.py                         # 只看報告
  .venv312/bin/python3 prompt_tuning.py --only cycling coffee   # 只評估這些分類
  .venv312/bin/python3 prompt_tuning.py --write-folder ~/Desktop/相簿主題設定

候選提示詞寫在 prompt_candidates.json（目前在用的提示詞會自動一起比較）。
只讀取標記檔、App 的分類目錄與模型；只寫入報告、文字向量快取，以及（--write-folder 時）設定.json。不碰手機、相簿或 App 的資料庫。
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
sys.dont_write_bytecode = True
import tag_threshold_eval as te  # noqa: E402  文字模型、分類目錄
import taxonomy_folder as tf  # noqa: E402
import train_tag_classifiers as tr  # noqa: E402  讀標記檔

CANDIDATES = SCRIPT_DIR / "prompt_candidates.json"
REPORT = SCRIPT_DIR / "prompt_tuning_report.md"
TEXT_CACHE = Path.home() / "selfIE_tag_eval" / "cache" / "prompt_text_vectors.npz"

MAX_PROMPTS = 4
MAX_CONFUSERS = 5
MIN_GAIN = 0.01          # 加一條至少要多抓到 1% 才加
MIN_EVAL_POSITIVES = 8   # 「是」少於這個數就不評估（量不準）
USER_FIRST = 10          # 你標的「是」至少這麼多，就只用你的照片評估
MAX_NEGATIVES = 4000     # 其他分類的「是」當「不是」時最多用幾張（算得快）
THRESHOLD_RANGE = (0.18, 0.40)


# ───────────── 文字向量 ─────────────

class TextEncoder:
    def __init__(self):
        self.cache = {}
        if TEXT_CACHE.exists():
            with np.load(TEXT_CACHE) as z:
                self.cache = {k: z[k] for k in z.files}
        self.model = None
        self.tokenizer = None
        self.dirty = False

    def __call__(self, prompt):
        prompt = prompt.strip()
        if prompt in self.cache:
            return self.cache[prompt]
        if self.model is None:
            if sys.platform != "darwin":
                sys.exit("文字向量要用 App 內附的 Core ML 模型計算，只能在 Mac 上執行。")
            try:
                import coremltools as ct
            except ImportError:
                sys.exit("需要 coremltools：請用 .venv312/bin/python3 執行")
            self.model = te.load_mlmodel(ct, te.TEXT_MODEL)
            self.tokenizer = te.Tokenizer()
        tokens = np.array(self.tokenizer.encode_full(te.PROMPT_TEMPLATE + prompt), dtype=np.int32).reshape(1, 77)
        vec = te.normalize(self.model.predict({"text": tokens})["final_emb_1"]).astype(np.float32)
        self.cache[prompt] = vec
        self.dirty = True
        return vec

    def save(self):
        if self.dirty:
            TEXT_CACHE.parent.mkdir(parents=True, exist_ok=True)
            tmp = TEXT_CACHE.with_suffix(".tmp.npz")
            np.savez(tmp, **self.cache)
            tmp.replace(TEXT_CACHE)


# ───────────── 評估資料 ─────────────

def eval_set(node, labels, vectors, public, rng):
    """這個分類的評估照片：你明確標的是／不是＋其他分類的「是」（當「不是」）。
    你標的「是」太少時，加上公開資料集。回傳 (X, y, 說明)"""
    def collect(use_public):
        keys, ys = [], []
        explicit = {k: v for (k, n), v in labels.items() if n == node and (use_public or k not in public)}
        for k, v in explicit.items():
            keys.append(k); ys.append(1 if v else 0)
        others = sorted({k for (k, n), v in labels.items()
                         if v and n != node and k not in explicit and (use_public or k not in public)})
        if len(others) > MAX_NEGATIVES:
            others = sorted(rng.choice(others, MAX_NEGATIVES, replace=False).tolist())
        keys += others; ys += [0] * len(others)
        return keys, np.array(ys)

    keys, y = collect(False)
    mine = int(y.sum())
    source = f"你的照片（是 {mine}）"
    if mine < USER_FIRST:
        keys, y = collect(True)
        source = f"你的照片＋公開資料（是 {int(y.sum())}，你的 {mine}）"
    if not keys:
        return None, None, "沒有照片"
    X = np.stack([vectors[k] for k in keys]).astype(np.float32)
    return X, y, source


def node_scores(X, prompt_vecs, confuser_vecs, margin):
    """和 App 相同：提示詞取最高分；容易誤認的畫面一樣像（差不到 margin）時不算"""
    s = (X @ np.stack(prompt_vecs).T).max(axis=1)
    if confuser_vecs:
        c = (X @ np.stack(confuser_vecs).T).max(axis=1)
        s = np.where(c >= s - margin, -1.0, s)
    return s


def best_threshold(s, y, target):
    """門檻範圍內，準確率 ≥ 目標時召回率最高的門檻：(門檻, 準確率, 召回率)；達不到時 None"""
    lo, hi = THRESHOLD_RANGE
    pos = int(y.sum())
    if pos == 0:
        return None
    order = np.argsort(-s)
    s_sorted, y_sorted = s[order], y[order]
    tp = np.cumsum(y_sorted)
    fp = np.cumsum(1 - y_sorted)
    best = None
    for i in range(len(s_sorted)):
        t = float(s_sorted[i])
        if t < lo:
            break
        if t > hi or (i + 1 < len(s_sorted) and s_sorted[i + 1] == t):
            continue
        precision = tp[i] / (tp[i] + fp[i])
        recall = tp[i] / pos
        if precision >= target and (best is None or recall > best[2]):
            best = (t, float(precision), float(recall))
    return best


def at_threshold(s, y, t):
    pred = s >= t
    tp = int((pred & (y == 1)).sum()); fp = int((pred & (y == 0)).sum())
    pos = int(y.sum())
    return (tp / (tp + fp) if tp + fp else 0.0, tp / pos if pos else 0.0)


def recall_of(result):
    return result[2] if result else 0.0


# ───────────── 挑選 ─────────────

def tune(X, y, current_prompts, current_confusers, cand_prompts, cand_confusers, encode, target, margin):
    pool = list(dict.fromkeys([p.strip() for p in current_prompts + cand_prompts if p.strip()]))
    cpool = list(dict.fromkeys([c.strip() for c in current_confusers + cand_confusers if c.strip()]))
    pv = {p: encode(p) for p in pool}
    cv = {c: encode(c) for c in cpool}

    def evaluate(prompts, confusers):
        return best_threshold(node_scores(X, [pv[p] for p in prompts], [cv[c] for c in confusers], margin), y, target)

    # 1. 提示詞：逐條加入（先不用容易誤認的畫面）
    chosen, best = [], None
    while len(chosen) < MAX_PROMPTS:
        trials = [(evaluate(chosen + [p], []), p) for p in pool if p not in chosen]
        trials = [t for t in trials if t[0]]
        if not trials:
            break
        res, p = max(trials, key=lambda t: (t[0][2], t[0][1]))
        if chosen and recall_of(res) < recall_of(best) + MIN_GAIN:
            break
        chosen.append(p); best = res
    if not chosen:
        return None
    # 2. 容易誤認的畫面：逐條加入，召回率變高（同樣的準確率下）才留
    confusers = []
    while len(confusers) < MAX_CONFUSERS:
        trials = [(evaluate(chosen, confusers + [c]), c) for c in cpool if c not in confusers]
        trials = [t for t in trials if t[0]]
        if not trials:
            break
        res, c = max(trials, key=lambda t: (t[0][2], t[0][1]))
        if recall_of(res) < recall_of(best) + MIN_GAIN:
            break
        confusers.append(c); best = res
    return chosen, confusers, best


# ───────────── 主程式 ─────────────

def main(argv=None):
    p = argparse.ArgumentParser(description="替分類挑出最好的提示詞、容易誤認的畫面與門檻")
    p.add_argument("inputs", nargs="*", default=[str(tr.DEFAULT_INPUT)], help="標記檔或資料夾")
    p.add_argument("--only", nargs="+", help="只評估這些分類（tag id）")
    p.add_argument("--precision", type=float, default=0.9, help="準確率目標（預設 0.9）")
    p.add_argument("--write-folder", help="把有變好的分類寫進這個「相簿主題設定」資料夾")
    p.add_argument("--seed", type=int, default=7)
    args = p.parse_args(argv)
    rng = np.random.default_rng(args.seed)

    candidates = {k: v for k, v in json.loads(CANDIDATES.read_text(encoding="utf-8")).items() if not k.startswith("_")}
    nodes, by_id, defaults = te.load_nodes()
    labels, vectors, _, _, public = tr.read_label_files(args.inputs)
    _, _, trainable = tr.node_info()
    labels = tr.apply_redirects(labels, tr.node_redirects(), trainable)
    margin = defaults.get("suppressMargin", 0.01)
    encode = TextEncoder()

    tags = [t for t in candidates if t in by_id]
    for t in candidates:
        if t not in by_id:
            print(f"⚠️ 候選裡的「{t}」不在分類目錄裡，略過")
    if args.only:
        tags = [t for t in tags if t in set(args.only)]

    rows, changes = [], {}
    for tag in tags:
        node = by_id[tag]
        name = f"{node['nameZh']}（{tag}）"
        X, y, source = eval_set(tag, labels, vectors, public, rng)
        if X is None or int(y.sum()) < MIN_EVAL_POSITIVES:
            rows.append((name, source if X is not None else "沒有照片", None, None, None))
            print(f"・ {name}：照片太少，沒辦法評估（{source}）")
            continue
        current_prompts = list(node["prompts"])
        current_confusers = list(node.get("confusers") or [])
        current_t = node["acceptScore"] if node.get("acceptScore") is not None else defaults["acceptScore"]
        # 目前：現在的提示詞、容易誤認的畫面、門檻
        s_now = node_scores(X, [encode(p) for p in current_prompts], [encode(c) for c in current_confusers], margin)
        now = at_threshold(s_now, y, current_t)
        # 只調門檻
        best_t_only = best_threshold(s_now, y, args.precision)
        cand = candidates[tag]
        tuned = tune(X, y, current_prompts, current_confusers, cand.get("prompts", []), cand.get("confusers", []),
                     encode, args.precision, margin)
        rows.append((name, source, (current_t, now), best_t_only, tuned))
        if tuned:
            prompts, confusers, (t, prec, rec) = tuned
            improved = rec >= max(now[1] if now[0] >= args.precision else 0.0, recall_of(best_t_only)) + MIN_GAIN
            if improved:
                changes[tag] = {"prompts": prompts, "confusers": confusers, "threshold": round(t, 3),
                                "precision": prec, "recall": rec}
            print(f"{'✅' if improved else '・'} {name}：目前 準確率 {now[0]:.0%}／召回率 {now[1]:.0%} → "
                  f"調整後 {prec:.0%}／{rec:.0%}（門檻 {t:.3f}）")
        else:
            print(f"・ {name}：達不到準確率 {args.precision:.0%}（目前 {now[0]:.0%}／{now[1]:.0%}）")
    encode.save()

    write_report(rows, changes, args.precision)
    print(f"\n報告：{REPORT}")
    if args.write_folder and changes:
        write_folder(changes, Path(args.write_folder).expanduser())
    elif changes:
        print(f"有 {len(changes)} 個分類變好。要套用：加上 --write-folder ~/Desktop/相簿主題設定 再執行一次，然後執行 套用到App.py")
    return 0


def write_report(rows, changes, target):
    lines = ["# 提示詞評估", "",
             f"- 準確率目標：{target:.0%}；「目前」是現在的提示詞和門檻，「只調門檻」是提示詞不變、換最好的門檻。",
             "- 只算這個分類自己的分數；App 還會和其他分類比（差太多不標），實際結果可能略有不同。",
             "- ✅ 是有變好、建議套用的分類。", "",
             "| 分類 | 評估照片 | 目前（準確率／召回率） | 只調門檻 | 調整後 | 門檻 |", "|---|---|---|---|---|---|"]
    for name, source, now, t_only, tuned in rows:
        if now is None:
            lines.append(f"| {name} | {source} | 照片太少，沒評估 | | | |")
            continue
        t_now, (p_now, r_now) = now
        t_only_text = f"{t_only[1]:.0%}／{t_only[2]:.0%}（{t_only[0]:.3f}）" if t_only else "達不到"
        if tuned:
            _, _, (t, prec, rec) = tuned
            mark = "✅ " if any(name.endswith(f"（{k}）") for k in changes) else ""
            tuned_text, t_text = f"{mark}{prec:.0%}／{rec:.0%}", f"{t_now:.3f} → {t:.3f}"
        else:
            tuned_text, t_text = "達不到", f"{t_now:.3f}"
        lines.append(f"| {name} | {source} | {p_now:.0%}／{r_now:.0%} | {t_only_text} | {tuned_text} | {t_text} |")
    if changes:
        lines += ["", "## 建議的提示詞", ""]
        for tag, c in changes.items():
            lines.append(f"### {tag}")
            lines += [f"- 提示詞：{p}" for p in c["prompts"]]
            lines += [f"- 容易誤認的畫面：{x}" for x in c["confusers"]]
            lines.append(f"- 門檻：{c['threshold']}")
            lines.append("")
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_folder(changes, folder):
    written = 0
    for nid, settings in tf._scan_ids(folder).items():
        if nid not in changes or settings.name != "設定.json":
            continue
        doc = json.loads(settings.read_text(encoding="utf-8"))
        c = changes[nid]
        doc["提示詞"] = c["prompts"]
        doc["容易誤認的畫面"] = c["confusers"]
        doc["門檻"] = c["threshold"]
        settings.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        written += 1
    print(f"✅ 已寫進 {written} 個分類的 設定.json（{folder}）。接著執行 python3 套用到App.py 套用到 App。")


if __name__ == "__main__":
    sys.exit(main())

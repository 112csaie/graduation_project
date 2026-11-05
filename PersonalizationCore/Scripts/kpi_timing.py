#!/usr/bin/env python3
"""整理 App 主控台的「[計時]」紀錄，算出平均、p95（系統測試報告第 3.4 節的績效 KPI）。

用法：
  1. 用 Xcode 以 Debug 版安裝 App，照測試步驟操作。
  2. 把 Xcode 主控台（或 Mac「主機」App，搜尋「[計時]」）的內容整段複製，存成文字檔，例如 紀錄.txt。
  3. python3 kpi_timing.py 紀錄.txt
     python3 kpi_timing.py 紀錄.txt --columns   # 另外印出每個項目的秒數，一行一個，可直接貼進 KPI 紀錄表
     python3 kpi_timing.py                      # 不給檔名：直接讀剪貼簿（在主控台全選、複製後執行）

每一行紀錄的格式：[計時] 名稱 | 1.234s | 120 張 | 97.3 張/秒 | 備註
"""
import math
import os
import re
import subprocess
import sys
from collections import OrderedDict

LINE = re.compile(r"\[計時\]\s*(?P<name>[^|]+?)\s*\|\s*(?P<sec>[0-9.]+)s"
                  r"(?:\s*\|\s*(?P<count>\d+)\s*張\s*\|\s*[0-9.\-]+\s*張/秒)?"
                  r"(?:\s*\|\s*(?P<note>.*))?$")

# 名稱 → (KPI 編號, 說明, 判定方式)
TARGETS = {
    "搜尋": ("PF-01", "p95 < 2 秒且平均 < 1 秒", lambda s: s["p95"] < 2 and s["mean"] < 1),
    "篩選": ("PF-02", "p95 < 0.5 秒", lambda s: s["p95"] < 0.5),
    "掃描": ("PF-03", "≥ 10 張／秒（總張數 ÷ 總秒數）", lambda s: s["rate"] is not None and s["rate"] >= 10),
    "分類": ("PF-04", "重新分類 10,000 張 ≤ 60 秒（看最長的一次）", lambda s: s["max"] <= 60),
    "文字辨識": ("PF-05", "≥ 5 張／秒（總張數 ÷ 總秒數）", lambda s: s["rate"] is not None and s["rate"] >= 5),
    "啟動到首頁": ("PF-06", "平均 < 3 秒", lambda s: s["mean"] < 3),
    "過熱暫停": ("PF-10", "≤ 10 秒（看最長的一次）", lambda s: s["max"] <= 10),
    "搜尋（含智慧搜尋）": ("PF-11", "p95 < 3 秒（組員負責）", lambda s: s["p95"] < 3),
}


def p95(values):
    """由小到大排序後取第 ⌈0.95 × 次數⌉ 個（和 KPI 紀錄表的算法相同）。"""
    ordered = sorted(values)
    return ordered[max(1, math.ceil(0.95 * len(ordered))) - 1]


def parse(text):
    groups = OrderedDict()
    for raw in text.splitlines():
        if "[計時]" not in raw:
            continue
        line = raw[raw.index("[計時]"):].strip()
        m = LINE.match(line)
        if not m:
            continue  # 「熱狀態」這類沒有秒數的紀錄
        name = m.group("name").strip()
        count = int(m.group("count")) if m.group("count") else None
        groups.setdefault(name, []).append((float(m.group("sec")), count, (m.group("note") or "").strip()))
    return groups


def summarize(rows):
    secs = [r[0] for r in rows]
    counts = [r[1] for r in rows if r[1] is not None]
    total_sec = sum(r[0] for r in rows if r[1] is not None)
    return {
        "n": len(secs),
        "mean": sum(secs) / len(secs),
        "p95": p95(secs),
        "max": max(secs),
        "total_count": sum(counts) if counts else None,
        "rate": (sum(counts) / total_sec) if counts and total_sec > 0 else None,
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show_columns = "--columns" in sys.argv
    if args:
        path = os.path.expanduser(args[0])
        if not os.path.exists(path):
            print(f"找不到檔案：{path}")
            print("請先把主控台的內容存成文字檔（例如用「文字編輯」貼上後存成純文字），再把檔案路徑放在指令後面；")
            print("也可以不給檔名，直接在主控台全選、複製後執行：python3 kpi_timing.py")
            sys.exit(1)
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    else:
        try:
            text = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
        except FileNotFoundError:
            print(__doc__)
            sys.exit(1)
        print("（讀取剪貼簿的內容）")
    groups = parse(text)
    if not groups:
        print("找不到「[計時]」紀錄。請確認是 Debug 版 App，並且複製了主控台的內容。")
        sys.exit(1)

    for name, rows in groups.items():
        s = summarize(rows)
        code, rule, check = TARGETS.get(name, ("", "", None))
        print(f"\n■ {name}" + (f"（{code}）" if code else ""))
        print(f"  次數 {s['n']}　平均 {s['mean']:.3f} 秒　p95 {s['p95']:.3f} 秒　最長 {s['max']:.3f} 秒")
        if s["total_count"] is not None:
            rate = f"{s['rate']:.1f}" if s["rate"] is not None else "-"
            print(f"  總張數 {s['total_count']}　每秒 {rate} 張")
        if check:
            print(f"  標準：{rule} → {'Pass' if check(s) else 'Fail'}")
        if name in ("搜尋", "篩選") and s["n"] < 20:
            print("  提醒：報告要求同一項目至少量測 20 次（PF-01 是 20 組查詢 × 5 次 = 100 次）")
        if show_columns:
            print("  秒數（貼到 KPI 紀錄表）：")
            for sec, _, _ in rows:
                print(f"{sec:.3f}")


if __name__ == "__main__":
    main()

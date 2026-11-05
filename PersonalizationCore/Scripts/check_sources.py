#!/usr/bin/env python3
"""不需要 Xcode 的原始碼檢查（無法取代編譯，只能抓明顯錯誤）。

1. Swift 結構檢查：去除字串與註解後，檢查 () [] {} 是否成對、三引號字串是否關閉。
2. 照片安全掃描：整個 App 不得出現刪除 / 修改系統相簿照片的 API；
   個人化相關程式碼不得出現任何寫入照片或刪除檔案的 API。
3. 專案檔檢查：新增的 Swift 檔案都已加入 MobileCLIPExplore target 的 Sources。

用法：python3 PersonalizationCore/Scripts/check_sources.py [path/to/ios_app]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
problems: list[str] = []


def strip_swift(code: str) -> str:
    """移除註解與字串內容（支援三引號、字串插值中的括號會被忽略）。"""
    out = []
    i, n = 0, len(code)
    while i < n:
        if code.startswith("//", i):
            j = code.find("\n", i)
            i = n if j == -1 else j
            continue
        if code.startswith("/*", i):
            j = code.find("*/", i + 2)
            if j == -1:
                problems.append("未關閉的區塊註解")
                return "".join(out)
            i = j + 2
            continue
        if code.startswith('"""', i):
            j = code.find('"""', i + 3)
            if j == -1:
                problems.append("未關閉的三引號字串")
                return "".join(out)
            out.append('""')
            i = j + 3
            continue
        if code[i] == '"':
            j = i + 1
            depth = 0
            while j < n:
                if code[j] == "\\" and j + 1 < n and code[j + 1] == "(":
                    depth += 1
                    j += 2
                    continue
                if depth and code[j] == ")":
                    depth -= 1
                elif code[j] == "\\":
                    j += 2
                    continue
                elif code[j] == '"' and depth == 0:
                    break
                elif code[j] == "\n" and depth == 0:
                    problems.append(f"疑似未關閉的字串：{code[i:i+40]!r}")
                    break
                j += 1
            out.append('""')
            i = j + 1
            continue
        out.append(code[i])
        i += 1
    return "".join(out)


def check_balance(path: Path) -> None:
    code = strip_swift(path.read_text(encoding="utf-8"))
    pairs = {")": "(", "]": "[", "}": "{"}
    stack: list[tuple[str, int]] = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack or stack[-1][0] != pairs[ch]:
                problems.append(f"{path.name}:{line} 括號不成對：{ch}")
                return
            stack.pop()
    if stack:
        problems.append(f"{path.name}:{stack[-1][1]} 有未關閉的 {stack[-1][0]}")


def code_lines(path: Path) -> str:
    return "\n".join(l for l in path.read_text(encoding="utf-8").splitlines() if not l.strip().startswith("//"))


def main() -> int:
    personal_dirs = [ROOT / "PersonalizationCore/Sources", ROOT / "MobileCLIPExplore/Personalization"]
    app_dir = ROOT / "MobileCLIPExplore"

    swift_files = sorted(set(app_dir.rglob("*.swift")) | set((ROOT / "PersonalizationCore").rglob("*.swift")))
    for path in swift_files:
        check_balance(path)
    print(f"Swift 結構檢查：{len(swift_files)} 個檔案")

    for path in app_dir.rglob("*.swift"):
        code = code_lines(path)
        for token in ("deleteAssets", "PHAssetChangeRequest"):
            if token in code:
                problems.append(f"{path.name} 仍包含 {token}（會刪除 / 修改系統相簿照片）")
    forbidden = ("PHAssetChangeRequest", "PHAssetCollectionChangeRequest", "PHAssetCreationRequest",
                 "deleteAssets", "performChanges", "removeItem(", "PHContentEditingOutput")
    personal_files = [p for d in personal_dirs for p in d.rglob("*.swift")]
    for path in personal_files:
        code = code_lines(path)
        for token in forbidden:
            if token in code:
                problems.append(f"{path.name} 使用了 {token}")
    print(f"照片安全掃描：App {len(list(app_dir.rglob('*.swift')))} 個檔案、個人化程式碼 {len(personal_files)} 個檔案")

    pbxproj = (ROOT / "MobileCLIPExplore.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    in_sources = set(re.findall(r"/\* (\S+\.swift) in Sources \*/", pbxproj))
    for path in personal_files:
        if path.name not in in_sources:
            problems.append(f"{path.name} 尚未加入 Xcode target 的 Sources")
    print(f"專案檔檢查：{len(personal_files)} 個新檔案")

    if problems:
        print("\nFAILED:")
        for p in problems:
            print("  ❌", p)
        return 1
    print("\nALL SOURCE CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# 自適應個人視覺記憶系統：語意檢索與自動化歸納架構
## Adaptive Personal Visual Memory System

[![Platform](https://img.shields.io/badge/Platform-iOS%2017.0%2B-black.svg)](https://developer.apple.com/ios/)
[![Language](https://img.shields.io/badge/Language-Swift%205.10%20%7C%20Python%203.10%2B-blue.svg)](https://developer.apple.com/)
[![Framework](https://img.shields.io/badge/Framework-SwiftUI%20%7C%20CoreML%20%7C%20FastAPI-green.svg)](https://developer.apple.com/documentation/coreml)

## 📌 專案簡介 (Introduction)
現代人生活離不開 3C 產品（尤其是手機），常利用手機紀錄日常生活。然而，日積月累的相片常導致需要時找不到照片，且手動整理相簿耗費大量時間。

本專案開發出一款**本地端智慧相簿管理應用程式**，旨在讓每個人不再為自己凌亂的相簿所困。使用者將相簿照片上傳後，系統即可自動化分類出如旅遊、美食、寵物等相簿，並能依據時間、地點自動建立群組（例如：`2025日本`、`2026春季`）。此外，本系統具備「以字搜圖」功能，只需輸入自然語言關鍵字，即可精準檢索出對應的照片，享受如私人助理般的相簿管理服務。

---

## 🚀 核心功能 (Features)
- **影像自動標記**：系統自動偵測上傳相片的物件、場景、地點等 Metadata 並進行基礎分類。
- **動態分類邏輯**：支援「自適應」功能，系統能根據使用者行為或特定場景自動調整分類權重。
- **使用者自定義**：提供介面供使用者自行建立標籤或相簿，交由模型自動分類；亦支援手動將相片移動至指定相簿中。
- **多維度搜尋**：支援透過時間、地點等詮釋資料（Metadata）進行複合式篩選與搜尋。
- **語義特徵搜尋**：利用 Embedding 技術，支援描述性長句特徵檢索（例如：*"A dog is playing a ball at the beach"*），精準找出符合情境的照片。
- **AI Agent 相簿小幫手**：提供自然語言對話介面，使用者可輸入抽象、複雜的指令（例如：*"幫我找2019年的日本旅遊"*），並可利用 AI Agent 搜尋該圖片的相關網路資訊。

---

## 🛠️ 實作方法與架構 (Method & Architecture)
本系統採用**四層式模組化架構**設計，將前端用戶介面與底層 AI 推論及資料庫解耦：

1. **訪問層 (Presentation Layer)**：利用 iOS 的 `SwiftUI` 建立高互動性介面，接收使用者指令（如上傳、搜尋）並視覺化呈現結果。
2. **控制層 (Control Layer)**：透過 `Swift ViewModel` 處理表現邏輯，作為 UI 與底層服務之間的溝通橋樑。
3. **服務層 (Service Layer)**：核心 AI 運算區。
   - **邊緣端推論**：整合 Apple `Vision Framework` 與 `CoreML`，載入 `MobileCLIP-S2` 模型進行本地端影像與文字的 512 維嵌入向量（Embedding）運算。
   - **AI Agent 後端**：透過輕量化網路接口（FastAPI/Flask）連接 Python 後端，由 `agent_service.py` 處理複雜自然語言語意分析並進行智慧工具調用（Tool-use）。
4. **資源層 (Resource Layer)**：利用 `Local File System` 安全儲存實體相片；並透過 `SQLite` 資料庫（`PhotoAI.sqlite`）儲存相片詮釋資料與 512 維特徵向量，實現高效的本地端向量檢索。

---

## 📊 測試資料 (Data)
- **資料集來源**：目前系統主要使用**其中兩名專題組員的手機相簿實體相片**進行內部沙盒環境測試。
- **資料集狀態**：現階段暫未引入外部公開標準資料集（如 ImageNet 或 COCO），全數以真實生活場景相片進行自適應分類與語意檢索之演算法驗證。

---

## 💻 開發與執行環境 (Environment)
### 開發環境
- **iOS 前端**：Swift 5.10+、SwiftUI (iOS 17 API)、Xcode 15+、Swift Package Manager (SPM)。
- **Python 後端**：Python 3.10+、PyTorch、Transformers、FastAPI / Flask。

### 執行需求
- **iOS 裝置**：iOS 17.0 以上，具 Neural Engine 之 A12 Bionic 晶片以上之 iPhone（以支援本地端硬體加速推論）。
- **儲存空間**：裝置本地端需預留至少 500MB 空間（用於 CoreML 模型與 SQLite 資料庫基礎配置）。
- **網絡限制**：基礎核心功能（如特徵提取、本地檢索）完全支援離線運作；iCloud 相簿原圖下載與 AI Agent 連網知識搜索則需維持網路連線。

---

## ⚠️ 系統限制 (Limitations)
1. **語言限制**：受限於目前採用的 `MobileCLIP-S2` 預訓練模型與標準 BPE 詞彙表，系統現階段之語意檢索功能**僅支援英文自然語言**。
2. **硬體負載控制**：為避免使用者輸入文字時連續觸發推論導致裝置發燙，系統限制必須按下鍵盤確認鍵（Return）後才正式啟動檢索流程。
3. **運算時效**：首次全庫掃描與特徵提取耗時較長，建議於裝置充電時執行。
4. **格式限制**：目前主要針對靜態影像進行特徵處理，暫未將動態影像（如 Live Photo、影片）納入特徵向量運算範圍。

---

## 📚 參考文獻 (References)
* [1] A. Mulligan, "sqlite-vec: A SQLite extension for efficient vector search," GitHub repository. [Online]. Available: https://github.com/asg017/sqlite-vec. Accessed: Feb. 17, 2026.
* [2] GeeksforGeeks, "Machine Learning Tutorial," [Online]. Available: https://www.geeksforgeeks.org/machine-learning/
* [3] P. K. A. Vasu, H. Pouransari, F. Faghri, O. Tuzel, and R. Vemulapalli, "MobileCLIP: Fast image-text models through multi-modal reinforced training," in *Proc. IEEE/CVF Conf. Comput. Vis. Pattern Recognit. (CVPR)*, 2024, pp. 10423–10433.
* [4] Apple Inc., "MobileCLIP GitHub Repository," [Online]. Available: https://github.com/apple/ml-mobileclip
* [5] Apple Developer Documentation, [Online]. Available: https://developer.apple.com/

---

## 👥 專題團隊資訊 (Project Team)
* **執行期間**：114 年 9 月 至 116 年 1 月
* **指導教授**：吳世琳 教授、陳嶽鵬 教授
* **專題組員**：
  - **資訊工程學系**：湯依儒 (B1228015)、蔡佩妤 (B1228018)
  - **人工智慧學系**：鄭暐薰 (B1228006)、邱庭俞 (B1228021)
* **所屬單位**：長庚大學資訊工程學系

---

## 📄 授權條款 (License)
本專案採用 **MIT 授權條款 (MIT License)**。

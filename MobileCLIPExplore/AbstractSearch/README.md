# 抽象語意搜尋模組（v10）iOS 版：整合說明

PC 版 `pipeline_v10.py` 的 Swift 移植。建圖與搜尋都在手機上離線完成：

- 建圖：Foundation Models（iOS 27）直接看照片，輸出場景圖
- 文字型照片（截圖、文件、收據、菜單…）**不建圖**：直接用 App 已經有的 OCR 與 MobileCLIP 標籤產生紀錄
- 文字向量：NLContextualEmbedding
- 儲存：SQLite，表格結構與 PC 版相同

## 檔案

| 檔案 | 內容 |
| --- | --- |
| `ASAbstractSearchService.swift` | **整合入口**，只需要呼叫這個類別 |
| `ASFoundationModel.swift` | 建圖、查詢解析（Foundation Models）與提示詞 |
| `ASTextPhotoFilter.swift` | 文字型照片的判斷與簡化紀錄（OCR＋CLIP 標籤） |
| `ASHybridSearch.swift` | 混合式搜尋演算法（對照 `hybrid_search_v10.py` 移植） |
| `ASTextEmbedder.swift` | 文字向量 |
| `ASStore.swift` | SQLite 儲存 |
| `ASSceneGraph.swift` | 資料格式 |
| `ASParityCheck.swift` | 與 PC 版的一致性檢查（開發用） |

所有型別都以 `AS` 開頭，避免和專案中既有的 v9 版本撞名。全部拖進 App target 即可，不需要安裝其他套件。

## 需求與專案設定

- iOS 27、支援 Apple Intelligence 的裝置，且使用者已開啟 Apple Intelligence
- Info.plist：`NSPhotoLibraryUsageDescription`（讀取相簿）
- 背景建圖的設定見下方「建圖排程」

## 使用方式

```swift
// App 啟動時建立一次，整個 App 共用
let service = try ASAbstractSearchService(databaseURL: ASAbstractSearchService.defaultDatabaseURL())
try await service.prepare()   // 載入文字向量模型（第一次可能需要下載）

// 是否可用（不支援 Apple Intelligence 的裝置要隱藏或改用一般搜尋）
if !ASAbstractSearchService.isAvailable { ... }

// 建圖：傳入要處理的照片。已建好、沒修改過的會自動跳過；失敗的下次會重試
let summary = await service.buildIndex(for: assets, hint: { id in
    // 回傳這張照片的 OCR 與 CLIP 結果（見下方「文字型照片不建圖」）；還沒有結果就回傳 nil
    lookupHint(id)
}, progress: { p in
    print("\(p.done)/\(p.total)")
})
// summary.built：用模型建圖的張數；summary.textOnly：文字型照片、沒有呼叫模型的張數

// 搜尋
let results = try await service.search("一隻在海邊散步的狗", topK: 20)
for r in results {
    r.localIdentifier   // 用 PHAsset.fetchAssets(withLocalIdentifiers:) 取回照片
    r.score             // 總分
    r.channelScores     // 各比對面向的分數，例如 ["semantic": 0.52, "entity": 0.48, "count": 1.0]
    r.description       // 模型對這張照片的描述，除錯用
}

// 照片被刪除後，傳入目前相簿所有照片的 ID，清掉資料庫裡的舊資料
try service.removeDeletedAssets(keeping: currentIDs)
```

取得照片（建議新照片優先建圖）：

```swift
let options = PHFetchOptions()
options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
let fetch = PHAsset.fetchAssets(with: .image, options: options)
var assets: [PHAsset] = []
fetch.enumerateObjects { a, _, _ in assets.append(a) }
```

## 文字型照片不建圖（hint）

截圖、文件、收據、菜單這類照片，只要有一個類型標籤就搜得到，不需要完整建圖。
`buildIndex` 的 `hint` 閉包傳入照片的 `localIdentifier`，回傳 App 已經算好的結果：

```swift
func lookupHint(_ id: String) -> ASPhotoHint? {
    guard let ocr = myOCRResult(id), let clip = myCLIPResult(id) else { return nil }  // 還沒算好就回傳 nil
    return ASPhotoHint(
        ocrText: ocr.text,                         // OCR 全部文字
        textAreaRatio: ocr.textAreaRatio,          // 文字框面積總和 ÷ 照片面積；沒有就傳 nil
        clipTags: clip.top3.map { ASClipTag(tag: $0.label, score: $0.probability) }  // 只有標籤就不傳 score
    )
}
```

- **判斷規則**（`ASTextPhotoFilter`）：文字面積 ≥ 10% 且字數 ≥ 20 就是文字型照片。
  沒有文字面積時改用字數 ≥ 200 判斷。
- **類型標籤**：CLIP 分數 ≥ 0.10 的前 3 名。OCR 關鍵字補標籤（`useKeywordTags`）預設關閉，PC 實驗沒有提升。
- **CLIP 標籤要是中文**，而且清單裡要有文字類的標籤（文件、講義課本、考卷、收據發票、菜單、聊天截圖、
  社群貼文截圖、新聞截圖、App 截圖、簡報、海報、票券等），這些照片才搜得到。
- 文字型照片不需要 Apple Intelligence，所以**模型被限流或在背景時也照常處理**。
- 判斷規則或標籤清單改了，把 `ASTextPhotoFilter.recordModelName` 改成新值，文字型照片會重算（很快）。
- PC 驗證（124 張、30 條查詢）：16 張文字照片完全不建圖，整體 MRR 0.812 → 0.804。

## 建圖排程（重要：裝置端模型在背景會被限流）

Foundation Models 在 App 不在前景時**可以執行，但系統忙碌時會限流**（`LanguageModelError.rateLimited`），
Apple 建議的處理方式是等一段時間再試，沒有公布背景配額。所以不要只靠背景建圖，建議三層搭配：

| 時機 | 做法 | 可靠度 |
| --- | --- | --- |
| App 在前景 | 開啟 App 時就開始建圖，進背景時取消 | 最穩定，主力 |
| 使用者主動按「分析相簿」 | `BGContinuedProcessingTask`：離開 App 後繼續，鎖定畫面的 Live Activity 顯示進度 | 背景中仍可能被限流 |
| 充電、閒置時 | `BGProcessingTask` 補做剩下的照片 | 最容易被限流 |

`buildIndex` 會依錯誤類型處理，不需要呼叫端判斷：

- **被限流或逾時**：先等 5 秒、15 秒各重試一次；仍被限流，之後的一般照片就先跳過（`summary.pending`），
  但**文字型照片照常處理**，最後 `stopReason == .rateLimited`。跳過的照片**不會**被記成失敗，下次呼叫會接續。
- **觸發安全機制、內容太長等重試也沒用的錯誤**：記為永久失敗，之後跳過，避免每次都卡在同一張。
- **Task 被取消**：在目前這張完成後停下，`stopReason == .cancelled`。

### 1. 前景建圖

```swift
@Environment(\.scenePhase) private var scenePhase
@State private var buildTask: Task<Void, Never>?

.onChange(of: scenePhase) { _, phase in
    if phase == .active {
        buildTask = Task { await service.buildIndex(for: fetchAssets(), hint: lookupHint) }
    } else {
        buildTask?.cancel()   // 進背景就停，交給下面兩種背景任務
    }
}
```

### 2. 使用者按下「分析相簿」（BGContinuedProcessingTask，iOS 26+）

必須由使用者的動作觸發。任務 ID 要以 bundle ID 開頭，並加入 Info.plist 的 `BGTaskSchedulerPermittedIdentifiers`。

```swift
import BackgroundTasks

let continuedID = Bundle.main.bundleIdentifier! + ".abstractsearch.analyze"

// App 啟動時註冊一次
BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedID, using: nil) { task in
    guard let task = task as? BGContinuedProcessingTask else { return }
    let work = Task {
        let assets = fetchAssets()
        task.progress.totalUnitCount = Int64(assets.count)
        let summary = await service.buildIndex(for: assets, hint: lookupHint, progress: { p in
            task.progress.completedUnitCount = Int64(p.done)
            task.updateTitle("分析相簿", subtitle: "已完成 \(p.done)/\(p.total) 張")
        })
        if summary.stopReason == .rateLimited { scheduleNightlyBuild() }  // 被限流就交給充電時補做
        task.setTaskCompleted(success: summary.stopReason == .completed)
    }
    task.expirationHandler = { work.cancel() }
}

// 按鈕的動作
func startAnalyze() {
    let request = BGContinuedProcessingTaskRequest(identifier: continuedID,
                                                   title: "分析相簿", subtitle: "準備中")
    try? BGTaskScheduler.shared.submit(request)
}
```

### 3. 充電、閒置時補做（BGProcessingTask）

Signing & Capabilities 加入 **Background Modes → Background processing**，任務 ID 同樣要加入 Info.plist。

```swift
let nightlyID = Bundle.main.bundleIdentifier! + ".abstractsearch.build"

BGTaskScheduler.shared.register(forTaskWithIdentifier: nightlyID, using: nil) { task in
    let task = task as! BGProcessingTask
    let work = Task {
        let summary = await service.buildIndex(for: fetchAssets(), hint: lookupHint)
        if summary.stopReason != .completed { scheduleNightlyBuild() }   // 沒做完就再排一次
        task.setTaskCompleted(success: summary.stopReason == .completed)
    }
    task.expirationHandler = { work.cancel() }
}

func scheduleNightlyBuild() {
    let request = BGProcessingTaskRequest(identifier: nightlyID)
    request.requiresExternalPower = true
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)   // 被限流後至少隔一段時間
    try? BGTaskScheduler.shared.submit(request)
}
```

### 還沒建好圖的照片

建圖需要時間，搜尋時可以在畫面上顯示「已分析 X / Y 張」，
並讓還沒分析的照片先用功能 2（MobileCLIP 關鍵字搜尋）的結果補上。

## 確認移植正確（建議第一次整合時做）

`ASParityCheck` 用 PC 版算好的分數，檢查 Swift 版的搜尋演算法是否算出完全相同的結果。
不需要 Apple Intelligence 和相簿權限，模擬器也能跑。

1. 把 `parity_fixture.json` 加進 App target（PC 上用 `export_parity_fixture.py` 產生）
2. 呼叫一次：

```swift
let url = Bundle.main.url(forResource: "parity_fixture", withExtension: "json")!
print(try ASParityCheck.run(fixtureURL: url))
```

第一行顯示「通過」即可，確認後可以把 json 從 target 移除。

## 注意事項

- **相似度校正**：不同文字向量模型的相似度分布不同（對應 PC 版的 `sim_floor`）。
  照片累積到 50 張以上、第一次算完向量時會自動校正一次；照片大量增加後可以手動呼叫 `calibrateSimFloor()`。
- **換文字向量模型**：實作 `ASTextEmbedding` 協定後傳入 `ASAbstractSearchService(databaseURL:embedder:)`，
  再呼叫 `embedPending()`，只會重算向量，不會重新建圖。
- **改提示詞或輸出格式**：把 `ASAbstractSearchService.schemaVersion` 改成新值，所有照片會在下次建圖時重建。
- **資料庫可以拿回 PC 分析**：`graph_json` 格式與 PC 版相同，
  把手機上的 `AbstractSearch.sqlite` 複製出來，就能用 PC 的工具（例如 `draw_graph.py --all`）檢查模型建出來的場景圖。
- **執行緒**：所有方法都可以從任何 Task 呼叫；搜尋與建圖可以同時進行。

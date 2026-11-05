# 個人化分類系統（PersonalizationCore）

這個資料夾是個人化分類系統中與平台無關的核心程式碼。App target 直接編譯
`Sources/PersonalizationCore/*.swift`（Xcode 專案中的 `PersonalizationCore` 群組），
`Package.swift` 只用於在 Mac 上執行單元測試。

| 檔案 | 用途 |
|---|---|
| `TaxonomyCatalog.swift` | **唯一**的分類定義（v3，取代舊的 45 類 Classification）：14 個興趣定位、17 個大分類 → 50 個中分類 → 156 個小分類，涵蓋追星、動漫、跑咖、娃娃與娃活、音樂展演、運動戶外、穿搭美妝等族群 |
| `InterestRecommender.swift` | 興趣 → 大分類的推薦與排序（只影響排序／預設，不影響辨識） |
| `MultiLabelTagger.swift` | 用**既有照片向量**做多標籤比對（已確認 / 待確認），門檻集中在 `TaggingThresholds` |
| `PersonalizationSchema.swift` | 非破壞性 Migration（只新增資料表、索引與欄位） |
| `PersonalizationStore.swift` | 偏好、標籤、跨分類查詢、移除 AI 分析資料、重新分析準備 |
| `ReferenceMatcher.swift` | 「我的 IP」：用使用者挑的範例照片（照片 × 照片向量）找出同一作品／角色／團體的照片；回答「是／不是」會成為新的範例／反例 |
| `TripDetector.swift` | Time & Place 旅遊相簿：自動學習住家／學校／公司等常去地點並排除，地區只到第一級行政區 |

App 端的檔案位於 `MobileCLIPExplore/Personalization/`。

## 執行測試（需要 Xcode）

```bash
cd PersonalizationCore
swift test                                   # XCTest：偏好、推薦、多標籤、移除 AI 資料、權限、Migration、照片安全靜態檢查
python3 Scripts/verify_sql.py ..             # 不需 Xcode：用 PhotoAI.sqlite 的副本驗證所有 SQL 與移除流程
python3 Scripts/check_sources.py ..          # 不需 Xcode：Swift 結構、照片安全 API 掃描、專案檔註冊
```

App 編譯：

```bash
xcodebuild -project MobileCLIPExplore.xcodeproj -scheme MobileCLIPExplore \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Migration

App 啟動時 `DatabaseManager.init` → `setUpPersonalizationStore()` 自動執行，不需手動操作：

- 新增資料表：`PersonalizationMigrations`、`PersonalizationMeta`、`UserProfiles`、`TaxonomyNodes`、
  `TaxonomyPrompts`、`UserInterests`、`UserCategoryPreferences`、`PhotoTags`、`PhotoAnalysisState`
- 既有資料表只追加欄位：`PhotoFeatures.owner_user_id / cluster_source / ai_removed_at`、
  `UserAlbums.owner_user_id / description`
- 每個版本在 transaction 中執行並記錄版本；可重複執行；失敗時新功能停用、既有功能不受影響。
- 不重建資料表、不刪除資料、不重新產生照片向量。

## 手動驗證原始照片不會被刪除或修改

1. 在「照片」App 中記下一張照片（例如截圖它的「資訊」面板：檔名、大小、日期）。
2. 在本 App 開啟該照片 → 「移除 AI 分析資料」→ 確認。
3. 回到「照片」App：照片仍在、仍在原本的相簿、「最近刪除」裡沒有它、資訊與內容不變。
4. 本 App 中：照片仍顯示在「All Photos」與主題相簿，手動標籤仍在，AI 標籤消失。
5. 再按「重新分析」：AI 標籤重新出現，「照片」App 中的照片仍未改變（修改日期不變）。
6. 若系統跳出「允許刪除照片？」的對話框，代表有錯誤——本 App 已不再呼叫任何刪除照片的 API。

## 舊分類（45 類 Classification）

`DatabaseManager.legacyClassificationEnabled = false`：不再執行舊分類、不在啟動時載入舊分類向量，
UI 也不再顯示。`ClusterSummary`／`SemanticDictionary`／`PhotoFeatures.cluster_id` 的既有資料**保留不刪**，
需要時把旗標改回 `true` 即可恢復。照片向量完全沿用，不需要重新掃描。

## Time & Place 旅遊相簿規則（`TripDetectionConfig`）

| 規則 | 預設值 |
|---|---|
| 常去地點：約 1 km 格子出現在 ≥ 6 個不同週，且 ≥ 4 次分開造訪或跨度 > 35 天 | 住家、學校、公司自動排除 |
| 在外地：距離所有常去地點 ≥ 40 km（在常住的行政區內需 ≥ 100 km） | |
| 切分旅程：回到常去地點，或相隔 > 48 小時 | |
| 有效旅程：≥ 2 天且 ≥ 6 張，或單日 ≥ 15 張且距離 ≥ 80 km；> 30 天視為長住 | |
| 無定位照片只在旅程期間內加入；螢幕截圖排除 | |
| 地區：反向地理編碼的第一級行政區（繁體中文），約 2 km 網格快取 | 東京、首爾、高雄 |

## 我的 IP（使用者自訂分類）

- 資料表：`UserCustomCategories`（Migration v2，只新增資料表）。照片對應沿用 `PhotoTags`，`node_id = 'ip:<id>'`。
- 範例 = 手動確認（建立時挑的照片、按「是」、手動加入）；反例 = 手動拒絕（按「不是」、從此分類移除）。
- 比對（`ReferenceMatchThresholds`）：與某張範例相似度 ≥ 0.86，或與最像的兩張平均 ≥ 0.80 → 自動加入；≥ 0.72 → 待確認（每個 IP 最多 60 張）；
  比反例更像反例 → 不算。門檻為保守初始值（沒有標註資料），請依實際使用調整。
- 分類目錄重新標記不會清掉 IP 結果；「移除 AI 分析資料」會清掉該照片的 IP 自動結果，保留手動回答。
- 刪除 IP 只刪除 App 的分類與對應標籤，不影響照片、系統相簿與主題相簿。

## 預先計算的分類文字向量（PhotoAI.sqlite → PrecomputedPromptEmbeddings）

- App 內附的 `PhotoAI.sqlite` 多了一張表 `PrecomputedPromptEmbeddings`（prompt、512 維向量、模板「a photo of」）。
  其他資料表（SemanticDictionary、ClusterSummary、PhotoFeatures、AgentNotes）完全沒有變動。
- App 準備分類時會以「唯讀」開啟 App 內附的這個檔案匯入向量，手機上不需要再跑文字模型；
  已安裝的使用者也適用（不需要重新安裝或重建資料庫）。只有目錄中新增、還沒預算的描述才在手機上現算。
- 產生方式：`Scripts/precompute_prompt_embeddings.py` 直接讀 `mobileclip_s2_text.mlpackage` 的運算圖與權重，用 numpy 計算；
  寫入前會與 SemanticDictionary 的既有向量（App 以 CoreML 算出）比對，目前最低餘弦相似度 0.9999994。
  修改 TaxonomyCatalog 的描述後重新執行即可（用法見腳本開頭說明）。

## 內建 PhotoAI.sqlite 的內容（2026-10 精簡）

依目前程式碼實際用到的內容整理，6.7 MB → 0.9 MB：

| 資料表 | 內容 | 原因 |
|---|---|---|
| `PrecomputedPromptEmbeddings` | 210 筆（目前分類目錄的全部描述） | 分類用的文字向量 |
| `SemanticDictionary` | 空（保留結構） | 舊 45 類分類的 1,405 筆向量，已停用 |
| `ClusterSummary` | 空（保留結構） | 舊 45 類分類表（1,399 筆），已停用；搜尋等查詢仍以 LEFT JOIN 參照，所以保留資料表 |
| `PhotoFeatures`、`AgentNotes` | 空（保留結構） | 使用者資料由 App 執行時寫入 |

- 只影響「新安裝」：已安裝的手機使用的是 Documents 裡自己的資料庫，不會被改動或刪除。
- 原始檔備份於 `_backup_before_personalization_20261011/MobileCLIPExplore/SQLite/PhotoAI.sqlite`。
  若要重新啟用舊分類（`legacyClassificationEnabled = true`），請先換回備份檔。
- 頁面大小維持 4 KB：改成 1 KB 檔案可再縮到約 0.5 MB，但新安裝會沿用這個檔案當作工作資料庫，
  照片向量（每筆 2 KB）讀寫會變慢，因此不採用。

## 演唱會場次（LiveEventDetector）

「主題 › 演唱會」（以及「音樂祭」「Live House」「舞台劇」和上層「音樂與表演」）最上方會顯示「場次」：同一個晚上、同一個場館的照片是一場，點進去是那一場的所有照片。

- 起點：照片與演唱會類描述最像（≥ 0.22，且不輸給這張照片最像的分類超過 0.02），或已被標成演唱會類（含待確認）。使用者按過「不是」的不算。
- 起點間隔 ≤ 3 小時、距離 ≤ 1.5 公里串成一場；至少 3 張起點且其中 2 張是舞台類（手燈不能單獨成立）。
- 擴大：前後 2 小時、場館 1.5 公里內的照片一起收（排隊、周邊、場外）；沒有定位的只收演出期間；一般截圖不收。
- 名稱：場館名稱（反向地理編碼的 areasOfInterest，例如「臺北小巨蛋」），查不到時用行政區，再不行用分類名稱。
- 場次只存在記憶體中並合併進演唱會相簿，不寫入 PhotoTags；「不屬於這場」會記為使用者拒絕該分類。
- 只處理已掃描（有向量）的照片，目前不含影片。

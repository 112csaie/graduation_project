import Foundation
import CoreML
import SQLite
import UIKit
import Accelerate
import CoreLocation
import Photos

// 🌟 用於記憶體的資料結構
struct CachedCategory {
    let clusterId: Int
    let keyword: String
    let parentCategory: String
    let embedding: [Float]
}

struct CachedParentCategory {
    let name: String
    let embedding: [Float]
    let children: [CachedCategory]
}

struct CustomAlbumSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let coverAssetId: String?
    let photoCount: Int
}

struct PhotoListItem: Identifiable, Hashable {
    let id: String
    let isFavorite: Bool
    let tag: String
    let date: String
}

struct MetadataAlbumSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let coverAssetId: String?
    let photoCount: Int
    let primaryAssetIds: [String]
    let otherAssetIds: [String]
    /// 旅程還沒有地名時，需要優先查詢第一級行政區的照片。
    var regionPendingAssetIds: [String] = []

    var assetIds: [String] {
        primaryAssetIds + otherAssetIds
    }

    var otherPhotoCount: Int {
        otherAssetIds.count
    }
}

struct MetadataAlbumSection: Identifiable, Hashable {
    let id: String
    let title: String
    let albums: [MetadataAlbumSummary]
}

class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: Connection?
    
    // 🌟 全域快取陣列 (存放 1400 筆語意字典)
    private var categoryCache: [CachedCategory] = []
    private var parentCategoryCache: [CachedParentCategory] = []
    
    // 🌟 資料庫寫入序列化佇列 (防止多執行緒併發寫入時引發 Database Locked)
    // internal：PersonalizationStore 共用同一個寫入佇列，確保所有寫入序列化。
    let writeQueue = DispatchQueue(label: "com.photoai.db.writeQueue")
    /// 個人化分類（多標籤、偏好、移除 AI 分析資料）的資料存取層，共用同一個 SQLite 連線。
    private(set) var personalization: PersonalizationStore?

    /// 照片向量與 metadata 的記憶體快取（見下方「照片特徵快取」）。以前每次搜尋都要把整個
    /// PhotoFeatures 表讀出來、逐張解碼向量和 JSON；專屬相簿、主動建議、演唱會場次也各自重讀一次。
    fileprivate var featureCache: [String: CachedPhotoFeature] = [:]
    fileprivate var featureCacheLoaded = false
    fileprivate let featureCacheLock = NSLock()
    private let classificationPreparationQueue = DispatchQueue(label: "com.photoai.db.classificationPreparation")
    private let classificationThreshold: Float = 0.21
    /// 舊的 45 類 Classification（ClusterSummary）已由個人化分類（PersonalizationCore）取代。
    /// 關閉後不再執行舊分類、也不在啟動時載入 1,399 筆舊分類向量；既有資料保留在資料庫中，不會被刪除。
    static let legacyClassificationEnabled = false
    private var hasPreparedClassification = false
    private lazy var textModel: mobileclip_s2_text? = {
        try? mobileclip_s2_text(configuration: MLModelConfiguration())
    }()
    /// 只建立一次：CLIPTokenizer 初始化會讀取約 4.9 萬條 BPE 規則與詞彙表，每次重建要花不少時間。
    /// 只在 classificationPreparationQueue（序列佇列）上使用。
    private lazy var sharedTokenizer = CLIPTokenizer()
    private lazy var queryDateFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd", "yyyy/M/d", "yyyy/M/dd", "yyyy/MM/d", "yyyy/MM/dd",
            "M/d/yyyy", "MM/dd/yyyy", "d/M/yyyy", "dd/MM/yyyy",
            "yyyy年M月d日", "M月d日yyyy年", "MMM d, yyyy", "MMMM d, yyyy"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter
        }
    }()
    private let metadataDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {
        copyDatabaseIfNeeded()
        connectDatabase()
        createNotesTableIfNeeded()
        createCustomAlbumTablesIfNeeded()
        dropLegacySceneGraphTable()
        createGeoRegionCacheTableIfNeeded()
        setUpPersonalizationStore()   // 非破壞性 Migration：只新增資料表與欄位
        warmUpFeatureCache()          // 背景載入照片向量快取，第一次搜尋不必等
        syncBundledTaxonomyIfNeeded()
        if Self.legacyClassificationEnabled {
            loadDictionaryIntoMemory() // 啟動時一次性將字典讀入 RAM
        }
    }
    
    // MARK: - 基礎連線設定
    private func copyDatabaseIfNeeded() {
        let fileManager = FileManager.default
        guard let documentsUrl = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let finalDatabaseURL = documentsUrl.appendingPathComponent("PhotoAI.sqlite")
        
        if !fileManager.fileExists(atPath: finalDatabaseURL.path) {
            if let bundleURL = Bundle.main.url(forResource: "PhotoAI", withExtension: "sqlite") {
                do {
                    try fileManager.copyItem(at: bundleURL, to: finalDatabaseURL)
                    print("資料庫複製成功")
                } catch { print("複製資料庫失敗: \(error)") }
            }
        }
    }
    
    private func connectDatabase() {
        guard let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let finalDatabaseURL = documentsUrl.appendingPathComponent("PhotoAI.sqlite")
        do {
            db = try Connection(finalDatabaseURL.path)
            print("成功連接 SQLite 資料庫")
            // WAL：寫入時不必每筆都等硬碟同步完成，大量寫入（標籤、地區）快很多；讀取也不會被寫入擋住。
            // 只改這個 App 自己的資料庫檔，不影響照片。失敗時維持原本模式。
            do {
                _ = try db?.scalar("PRAGMA journal_mode=WAL")
                try db?.execute("PRAGMA synchronous=NORMAL")
            } catch {
                print("資料庫 WAL 模式設定失敗（維持原本模式）: \(error)")
            }
        } catch { print("連接資料庫失敗: \(error)") }
    }

    /// 舊 45 類分類表的同步。舊分類停用後內建資料庫已不再附分類資料（見 PersonalizationCore/README），不需同步。
    private func syncBundledTaxonomyIfNeeded() {
        guard Self.legacyClassificationEnabled else { return }
        guard let db,
              let bundleURL = Bundle.main.url(forResource: "PhotoAI", withExtension: "sqlite")
        else { return }

        do {
            let bundledDB = try Connection(bundleURL.path)
            let bundledCount = (try bundledDB.scalar("SELECT COUNT(*) FROM ClusterSummary") as? Int64) ?? 0
            let currentCount = (try db.scalar("SELECT COUNT(*) FROM ClusterSummary") as? Int64) ?? 0

            guard bundledCount > currentCount else { return }

            var bundledCategories: [(keyword: String, parentCategory: String)] = []
            for row in try bundledDB.prepare("SELECT keyword, parent_category FROM ClusterSummary ORDER BY cluster_id ASC").run() {
                let keyword = row[0] as? String ?? ""
                let parentCategory = row[1] as? String ?? "Uncategorized"
                guard !keyword.isEmpty else { continue }
                bundledCategories.append((keyword: keyword, parentCategory: parentCategory))
            }

            try syncClusterSummary(with: bundledCategories)
            print("📦 已從 app 內建資料庫同步最新分類表：\(bundledCount) 筆小分類。")
        } catch {
            print("同步內建分類表失敗: \(error)")
        }
    }

    private func syncClusterSummary(with categories: [(keyword: String, parentCategory: String)]) throws {
        guard let db else { return }

        var existingKeywordMap: [String: Int64] = [:]
        for row in try db.prepare("SELECT cluster_id, keyword FROM ClusterSummary").run() {
            let clusterId = row[0] as? Int64 ?? 0
            let keyword = row[1] as? String ?? ""
            if !keyword.isEmpty {
                existingKeywordMap[keyword] = clusterId
            }
        }

        let importedKeywords = Set(categories.map(\.keyword))
        let removedKeywords = existingKeywordMap.keys.filter { !importedKeywords.contains($0) }

        try db.transaction {
            for category in categories {
                try db.prepare("""
                INSERT OR IGNORE INTO SemanticDictionary (keyword, word_embedding)
                VALUES (?, NULL)
                """).run(category.keyword)

                if existingKeywordMap[category.keyword] != nil {
                    try db.prepare("""
                    UPDATE ClusterSummary
                    SET parent_category = ?
                    WHERE keyword = ?
                    """).run(category.parentCategory, category.keyword)
                } else {
                    try db.prepare("""
                    INSERT INTO ClusterSummary (keyword, parent_category, random_vector)
                    VALUES (?, ?, NULL)
                    """).run(category.keyword, category.parentCategory)
                }
            }

            for keyword in removedKeywords {
                if let clusterId = existingKeywordMap[keyword] {
                    try? db.prepare("UPDATE PhotoFeatures SET cluster_id = -1 WHERE cluster_id = ?").run(clusterId)
                }
                try db.prepare("DELETE FROM ClusterSummary WHERE keyword = ?").run(keyword)
            }
        }
    }

    private func loadDictionaryIntoMemory() {
        guard let db = db else { return }
        categoryCache.removeAll()
        parentCategoryCache.removeAll()

        do {
            var groupedCategories: [String: [CachedCategory]] = [:]
            let query = """
            SELECT c.cluster_id, c.keyword, c.parent_category, s.word_embedding
            FROM ClusterSummary c
            JOIN SemanticDictionary s ON c.keyword = s.keyword
            """
            for row in try db.prepare(query).run() {
                let id = Int(row[0] as? Int64 ?? 1)
                let keyword = row[1] as? String ?? ""
                let parentCategory = row[2] as? String ?? "Uncategorized"
                if let blob = row[3] as? Blob {
                    let wordEmbedding = Data(blob.bytes).toArray(type: Float.self)
                    let cachedCategory = CachedCategory(
                        clusterId: id,
                        keyword: keyword,
                        parentCategory: parentCategory,
                        embedding: wordEmbedding
                    )
                    categoryCache.append(cachedCategory)
                    groupedCategories[parentCategory, default: []].append(cachedCategory)
                }
            }

            parentCategoryCache = groupedCategories.compactMap { parentCategory, children in
                guard let parentEmbedding = averageEmbedding(for: children.map(\.embedding)) else { return nil }
                return CachedParentCategory(
                    name: parentCategory,
                    embedding: parentEmbedding,
                    children: children
                )
            }
            .sorted { $0.name < $1.name }

            print("✅ 成功將 \(categoryCache.count) 筆分類向量載入快取，建立 \(parentCategoryCache.count) 個大分類快取！")
        } catch { print("載入快取失敗: \(error)") }
    }

    func prepareClassificationIfNeeded() {
        guard Self.legacyClassificationEnabled else { return }
        classificationPreparationQueue.sync {
            guard !hasPreparedClassification else { return }
            generateMissingSemanticEmbeddingsIfNeeded()
            loadDictionaryIntoMemory()
            hasPreparedClassification = true
        }
    }

    private func generateMissingSemanticEmbeddingsIfNeeded() {
        guard let db = db else { return }

        var missingKeywords: [String] = []
        do {
            let query = """
            SELECT c.keyword
            FROM ClusterSummary c
            LEFT JOIN SemanticDictionary s ON c.keyword = s.keyword
            WHERE s.keyword IS NULL OR s.word_embedding IS NULL
            ORDER BY c.cluster_id ASC
            """
            for row in try db.prepare(query).run() {
                if let keyword = row[0] as? String, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    missingKeywords.append(keyword)
                }
            }
        } catch {
            print("讀取缺失分類向量失敗: \(error)")
            return
        }

        guard !missingKeywords.isEmpty else { return }
        guard let textModel else {
            print("Text model unavailable, skipping semantic dictionary generation.")
            return
        }

        let tokenizer = CLIPTokenizer()
        var generatedCount = 0

        writeQueue.sync {
            do {
                for keyword in missingKeywords {
                    guard let embedding = self.textEmbedding(for: keyword, tokenizer: tokenizer, model: textModel) else {
                        continue
                    }

                    let embeddingData = Data(buffer: UnsafeBufferPointer(start: embedding, count: embedding.count))
                    try db.prepare("""
                    INSERT OR REPLACE INTO SemanticDictionary (keyword, word_embedding)
                    VALUES (?, ?)
                    """).run(keyword, Blob(bytes: [UInt8](embeddingData)))
                    generatedCount += 1
                }
            } catch {
                print("寫入分類向量失敗: \(error)")
            }
        }

        print("🧠 補齊 \(generatedCount) 筆缺失的分類文字向量。")
    }

    private func textEmbedding(
        for keyword: String,
        tokenizer: CLIPTokenizer,
        model: mobileclip_s2_text
    ) -> [Float]? {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return nil }

        do {
            let prompt = "a photo of \(trimmedKeyword)"
            let tokenArray = tokenizer.encode_full(text: prompt)
            let tokenMultiArray = try MLMultiArray(shape: [1, 77], dataType: .int32)

            for (index, tokenID) in tokenArray.enumerated() {
                tokenMultiArray[index] = NSNumber(value: tokenID)
            }

            let input = mobileclip_s2_textInput(text: tokenMultiArray)
            let prediction = try model.prediction(input: input)
            return prediction.final_emb_1.toFloatArray().normalized()
        } catch {
            print("文字模型推論失敗 (\(keyword)): \(error)")
            return nil
        }
    }

    private func averageEmbedding(for embeddings: [[Float]]) -> [Float]? {
        guard let firstEmbedding = embeddings.first else { return nil }

        var sum = [Float](repeating: 0, count: firstEmbedding.count)
        for embedding in embeddings where embedding.count == firstEmbedding.count {
            for index in embedding.indices {
                sum[index] += embedding[index]
            }
        }

        var divisor = Float(embeddings.count)
        var averaged = [Float](repeating: 0, count: firstEmbedding.count)
        vDSP_vsdiv(sum, 1, &divisor, &averaged, 1, vDSP_Length(sum.count))
        return averaged.normalized()
    }

    // MARK: - 個人化分類（PersonalizationStore）
    private func setUpPersonalizationStore() {
        guard let db = db else { return }
        let store = PersonalizationStore(db: db, writeQueue: writeQueue)
        do {
            try store.migrate()
            try store.seedCatalogIfNeeded()
            personalization = store
        } catch {
            // Migration 失敗時不啟用新功能，既有功能維持原狀。
            print("個人化分類 Migration 失敗（新功能停用，既有功能不受影響）: \(error)")
        }
    }

    /// 以既有 MobileCLIP 文字模型計算 "a photo of <keyword>" 的正規化向量（與分類字典相同的流程）。
    func computeTextEmbedding(for keyword: String) -> [Float]? {
        classificationPreparationQueue.sync {
            guard let textModel else { return nil }
            return textEmbedding(for: keyword, tokenizer: sharedTokenizer, model: textModel)
        }
    }

    /// 使用者是否已移除這張照片的 AI 分析（場景圖建立等背景工作會略過）。
    func isAIAnalysisRemoved(assetId: String) -> Bool {
        (try? personalization?.isAIAnalysisRemoved(assetId: assetId)) ?? false
    }

    /// 所有「移除 AI 分析資料」的照片（一次查詢；大量照片時不用每張各查一次）
    func aiRemovedAssetIds() -> Set<String> {
        (try? personalization?.aiRemovedAssetIds()) ?? []
    }

    // MARK: - 照片分類查詢
    func fetchGroupedCategories() -> [(main: String, subs: [String])] {
        guard let db = db else { return [] }
        var groupedDict: [String: [String]] = [:]
        var pinnedSet: Set<String> = []
        
        do {
            // 先讀取已釘選的分類
            for row in try db.prepare("SELECT keyword FROM PinnedCategories").run() {
                if let k = row[0] as? String { pinnedSet.insert(k) }
            }
            
            let query = "SELECT parent_category, keyword FROM ClusterSummary"
            let statement = try db.prepare(query)
            for row in try statement.run() {
                if let parent = row[0] as? String, let keyword = row[1] as? String {
                    groupedDict[parent, default: []].append(keyword)
                }
            }
        } catch { print("讀取階層分類失敗: \(error)") }
        
        // 排序邏輯：釘選的子相簿優先，再依字母排序
        return groupedDict.map { (main: $0.key, subs: $0.value) }
            .sorted { $0.main < $1.main }
            .map { group in
                let sortedSubs = group.subs.sorted { a, b in
                    let pA = pinnedSet.contains(a) ? 0 : 1
                    let pB = pinnedSet.contains(b) ? 0 : 1
                    if pA != pB { return pA < pB }
                    return a < b
                }
                return (main: group.main, subs: sortedSubs)
            }
    }

    func fetchPhotos(for keyword: String) -> [String] {
        guard let db = db else { return [] }
        var assetIds: [String] = []
        do {
            let query = """
            SELECT p.asset_id 
            FROM PhotoFeatures p
            JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE c.keyword = ?
            ORDER BY p.rowid ASC
            """
            for row in try db.prepare(query).run(keyword) {
                if let assetId = row[0] as? String { assetIds.append(assetId) }
            }
        } catch { print("查詢照片失敗: \(error)") }
        return sanitizeAssetIds(assetIds)
    }

    func fetchPhotosWithFavorite(for keyword: String) -> [(id: String, isFavorite: Bool)] {
        guard let db = db else { return [] }
        var results: [(String, Bool)] = []
        do {
            let query = """
            SELECT p.asset_id, p.is_favorite 
            FROM PhotoFeatures p
            JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE c.keyword = ?
            ORDER BY p.rowid ASC
            """
            for row in try db.prepare(query).run(keyword) {
                if let assetId = row[0] as? String {
                    let isFavInt = row[1] as? Int64 ?? 0
                    results.append((id: assetId, isFavorite: isFavInt == 1))
                }
            }
        } catch { print("讀取最愛狀態失敗: \(error)") }
        let validIds = Set(sanitizeAssetIds(results.map(\.0)))
        return results.filter { validIds.contains($0.0) }
    }

    // MARK: - 照片同步與 AI 自動分類邏輯
    /// 寫入（或重新分析時更新）照片向量的 SQL。insertPhotoEmbedding 與 insertPhotoEmbeddings 共用。
    static let insertEmbeddingSQL = """
    INSERT INTO PhotoFeatures (asset_id, metadata, image_embedding, cluster_id, is_favorite, owner_user_id)
    VALUES (?, ?, ?, NULL, 0, ?)
    ON CONFLICT(asset_id) DO UPDATE SET
        metadata = CASE
            WHEN json_valid(PhotoFeatures.metadata) AND json_valid(excluded.metadata)
            THEN json_patch(PhotoFeatures.metadata, excluded.metadata)
            ELSE excluded.metadata
        END,
        image_embedding = excluded.image_embedding,
        cluster_id = CASE WHEN PhotoFeatures.cluster_source = 'manual' THEN PhotoFeatures.cluster_id ELSE NULL END,
        owner_user_id = COALESCE(PhotoFeatures.owner_user_id, excluded.owner_user_id)
    WHERE PhotoFeatures.ai_removed_at IS NULL
    """

    /// 寫入（或重新分析時更新）照片向量。
    /// - 使用者「移除 AI 分析資料」後（ai_removed_at 非 NULL），同步途中的寫入不會把向量加回來。
    /// - 重新分析時：合併 metadata（保留已反向地理編碼的地點）、保留最愛與手動移動過的分類。
    @discardableResult
    func insertPhotoEmbedding(assetId: String, metadata: String, embeddingData: Data) -> Bool {
        let ownerUserId = LocalUserSession.currentUserId
        var didWrite = false
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let insertQuery = Self.insertEmbeddingSQL
                try db.run(insertQuery, assetId, metadata, Blob(bytes: [UInt8](embeddingData)), ownerUserId)
                didWrite = db.changes > 0
            } catch { print("寫入照片失敗: \(error)") }
        }
        if didWrite { refreshFeatureCache(assetIds: [assetId]) }
        return didWrite
    }

    /// 一次寫入多張照片的向量（同一個 transaction）。回傳實際寫入的照片 ID。
    /// 規則與 insertPhotoEmbedding 相同：使用者移除 AI 分析的照片不會被寫回。
    func insertPhotoEmbeddings(_ rows: [(assetId: String, metadata: String, embeddingData: Data)]) -> Set<String> {
        guard !rows.isEmpty else { return [] }
        let ownerUserId = LocalUserSession.currentUserId
        var written = Set<String>()
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.transaction {
                    let statement = try db.prepare(Self.insertEmbeddingSQL)
                    for row in rows {
                        try statement.run(row.assetId, row.metadata, Blob(bytes: [UInt8](row.embeddingData)), ownerUserId)
                        if db.changes > 0 { written.insert(row.assetId) }
                    }
                }
            } catch {
                print("批次寫入照片失敗: \(error)")
                written = []
            }
        }
        refreshFeatureCache(assetIds: Array(written))
        return written
    }

    func classifyPendingPhotos(limit: Int? = nil) -> Int {
        // 舊分類已停用：照片改由 PersonalizationService 以多標籤方式分類（沿用同一份照片向量）。
        guard Self.legacyClassificationEnabled else { return 0 }
        prepareClassificationIfNeeded()

        let pendingPhotos = fetchPendingClassificationEmbeddings(limit: limit)
        guard !pendingPhotos.isEmpty else { return 0 }

        var classifiedCount = 0
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let updateStatement = try db.prepare("""
                UPDATE PhotoFeatures
                SET cluster_id = ?
                WHERE asset_id = ?
                """)

                for photo in pendingPhotos {
                    let photoEmbedding = photo.embeddingData.toArray(type: Float.self)
                    let targetClusterId = findBestMatchClusterId(for: photoEmbedding, threshold: classificationThreshold) ?? -1
                    try updateStatement.run(targetClusterId, photo.assetId)
                    classifiedCount += 1
                }
            } catch {
                print("批次分類照片失敗: \(error)")
            }
        }

        if classifiedCount > 0 {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
            }
        }
        return classifiedCount
    }

    private func fetchPendingClassificationEmbeddings(limit: Int?) -> [(assetId: String, embeddingData: Data)] {
        guard let db = db else { return [] }

        var results: [(assetId: String, embeddingData: Data)] = []
        do {
            var query = """
            SELECT asset_id, image_embedding
            FROM PhotoFeatures
            WHERE cluster_id IS NULL AND image_embedding IS NOT NULL
            ORDER BY rowid ASC
            """

            if let limit, limit > 0 {
                query += "\nLIMIT \(limit)"
            }

            for row in try db.prepare(query).run() {
                guard let assetId = row[0] as? String, let blob = row[1] as? Blob else { continue }
                results.append((assetId: assetId, embeddingData: Data(blob.bytes)))
            }
        } catch {
            print("讀取待分類照片失敗: \(error)")
        }
        return results
    }

    private func findBestMatchClusterId(for photoEmbedding: [Float], threshold: Float) -> Int? {
        if categoryCache.isEmpty {
            return nil
        }

        let candidateParents = bestParentCategories(for: photoEmbedding, limit: 1)
        let candidateCategories = candidateParents.isEmpty
            ? categoryCache
            : candidateParents.flatMap(\.children)

        var bestId: Int? = nil
        var maxSim: Float = -1.0
        
        for category in candidateCategories {
            let dotProduct = cosineSimilarity(photoEmbedding, category.embedding)
            if dotProduct > maxSim {
                maxSim = dotProduct
                bestId = category.clusterId
            }
        }
        return maxSim >= threshold ? bestId : nil
    }

    private func bestParentCategories(for photoEmbedding: [Float], limit: Int) -> [CachedParentCategory] {
        guard !parentCategoryCache.isEmpty else { return [] }

        return parentCategoryCache
            .map { parentCategory in
                (parentCategory: parentCategory, score: cosineSimilarity(photoEmbedding, parentCategory.embedding))
            }
            .sorted { $0.score > $1.score }
            .prefix(max(1, limit))
            .map(\.parentCategory)
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dotProduct: Float = 0.0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        return dotProduct
    }

    func fetchAllScannedAssetIds() -> Set<String> {
        guard let db = db else { return [] }
        var ids = Set<String>()
        do {
            // 「已處理」= 有向量，或使用者已移除 AI 分析（不再自動分析）。
            // 沒有向量且未被排除的照片（例如重新分析失敗）會在下次同步自動重試。
            for row in try db.prepare("SELECT asset_id FROM PhotoFeatures WHERE image_embedding IS NOT NULL OR ai_removed_at IS NOT NULL").run() {
                if let id = row[0] as? String { ids.insert(id) }
            }
        } catch {}
        return ids
    }

    func fetchAllCategories() -> [String] {
        guard let db = db else { return [] }
        var list: [String] = []
        do {
            for row in try db.prepare("SELECT keyword FROM ClusterSummary").run() {
                if let k = row[0] as? String { list.append(k) }
            }
        } catch {}
        return list
    }

    func fetchPhotosWithDetails(for keyword: String) -> [PhotoListItem] {
        guard let db = db else { return [] }
        var results: [PhotoListItem] = []
        do {
            let query = """
            SELECT p.asset_id, p.is_favorite, c.keyword, p.metadata
            FROM PhotoFeatures p
            JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE c.keyword = ?
            ORDER BY p.rowid ASC
            """
            for row in try db.prepare(query).run(keyword) {
                guard let assetId = row[0] as? String else { continue }
                let isFav = (row[1] as? Int64 ?? 0) == 1
                let tag   = (row[2] as? String) ?? ""
                var date  = ""
                if let meta = row[3] as? String,
                   let data = meta.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = dict["date"] as? String {
                    date = d
                }
                results.append(PhotoListItem(id: assetId, isFavorite: isFav, tag: tag, date: date))
            }
        } catch { print("fetchPhotosWithDetails failed: \(error)") }
        return sanitizePhotoListItems(results)
    }

    func countAllPhotos() -> Int {
        guard let db = db else { return 0 }
        if let row = try? db.prepare("SELECT COUNT(*) FROM PhotoFeatures").run().first(where: { _ in true }),
           let n = row[0] as? Int64 { return Int(n) }
        return 0
    }

    // MARK: - 自定義相簿建立與讀取
    private func createCustomAlbumTablesIfNeeded() {
        guard let db = db else { return }
        do {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS UserAlbums (
                album_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """)

            try db.execute("""
            CREATE TABLE IF NOT EXISTS UserAlbumPhotos (
                album_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                position INTEGER DEFAULT 0,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (album_id, asset_id)
            )
            """)
            
            try db.execute("CREATE TABLE IF NOT EXISTS PinnedCategories (keyword TEXT PRIMARY KEY)")
            try? db.execute("ALTER TABLE UserAlbums ADD COLUMN is_pinned INTEGER DEFAULT 0")
        } catch {
            print("建立自定義相簿資料表失敗: \(error)")
        }
    }

    func fetchCustomAlbums() -> [CustomAlbumSummary] {
        guard let db = db else { return [] }
        var albums: [CustomAlbumSummary] = []

        do {
            let query = """
            SELECT
                a.album_id,
                a.title,
                a.is_pinned
            FROM UserAlbums a
            WHERE ? IS NULL OR a.owner_user_id IS NULL OR a.owner_user_id = ?
            GROUP BY a.album_id, a.title, a.created_at, a.is_pinned
            ORDER BY a.is_pinned DESC, a.created_at ASC
            """

            let userId = LocalUserSession.currentUserId
            for row in try db.prepare(query).run(userId, userId) {
                let albumId = row[0] as? String ?? ""
                let title = row[1] as? String ?? ""
                let assetIds = fetchCustomAlbumPhotoAssetIds(albumId: albumId)
                let photoCount = assetIds.count
                let coverAssetId = assetIds.first

                albums.append(CustomAlbumSummary(
                    id: albumId,
                    title: title,
                    coverAssetId: coverAssetId,
                    photoCount: photoCount
                ))
            }
        } catch {
            print("讀取自定義相簿失敗: \(error)")
        }

        return albums
    }

    private func fetchCustomAlbumCoverAssetId(albumId: String, position: Int) -> String? {
        guard let db = db else { return nil }
        do {
            let query = """
            SELECT asset_id
            FROM UserAlbumPhotos
            WHERE album_id = ? AND position = ?
            LIMIT 1
            """
            if let row = try db.prepare(query).run(albumId, position).first(where: { _ in true }) {
                return row[0] as? String
            }
        } catch {
            print("讀取自定義相簿封面失敗: \(error)")
        }
        return nil
    }

    func customAlbumExists(named title: String) -> Bool {
        guard let db = db else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        do {
            let query = """
            SELECT 1
            FROM UserAlbums
            WHERE lower(title) = lower(?)
            LIMIT 1
            """
            return try db.prepare(query).run(trimmed).first(where: { _ in true }) != nil
        } catch {
            print("檢查自定義相簿名稱失敗: \(error)")
            return false
        }
    }

    @discardableResult
    func createCustomAlbum(title: String, assetIds: [String]) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var createdAlbumId: String?
        writeQueue.sync {
            guard let db = self.db else { return }
            let albumId = UUID().uuidString

            do {
                try db.prepare("INSERT INTO UserAlbums (album_id, title, owner_user_id) VALUES (?, ?, ?)").run(albumId, trimmed, LocalUserSession.currentUserId)
                for (index, assetId) in assetIds.enumerated() {
                    try db.prepare("""
                    INSERT OR IGNORE INTO UserAlbumPhotos (album_id, asset_id, position)
                    VALUES (?, ?, ?)
                    """).run(albumId, assetId, index)
                }
                createdAlbumId = albumId
            } catch {
                print("建立自定義相簿失敗: \(error)")
            }
        }

        if createdAlbumId != nil {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
            }
        }
        return createdAlbumId
    }

    func fetchCustomAlbumPhotoAssetIds(albumId: String) -> [String] {
        guard let db = db else { return [] }
        var assetIds: [String] = []
        do {
            let query = """
            SELECT asset_id
            FROM UserAlbumPhotos
            WHERE album_id = ?
            ORDER BY position ASC, created_at ASC
            """
            for row in try db.prepare(query).run(albumId) {
                if let assetId = row[0] as? String {
                    assetIds.append(assetId)
                }
            }
        } catch {
            print("讀取自定義相簿照片失敗: \(error)")
        }
        return sanitizeAssetIds(assetIds)
    }

    func fetchCustomAlbumPhotosWithDetails(albumId: String) -> [PhotoListItem] {
        guard let db = db else { return [] }
        var results: [PhotoListItem] = []

        do {
            let query = """
            SELECT ap.asset_id, COALESCE(p.is_favorite, 0), COALESCE(c.keyword, ''), p.metadata
            FROM UserAlbumPhotos ap
            LEFT JOIN PhotoFeatures p ON ap.asset_id = p.asset_id
            LEFT JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE ap.album_id = ?
            ORDER BY ap.position ASC, ap.created_at ASC
            """
            for row in try db.prepare(query).run(albumId) {
                guard let assetId = row[0] as? String else { continue }
                let isFav = (row[1] as? Int64 ?? 0) == 1
                let tag = row[2] as? String ?? ""
                var date = ""

                if let meta = row[3] as? String,
                   let data = meta.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = dict["date"] as? String {
                    date = d
                }

                results.append(PhotoListItem(id: assetId, isFavorite: isFav, tag: tag, date: date))
            }
        } catch {
            print("讀取自定義相簿詳情失敗: \(error)")
        }

        return sanitizePhotoListItems(results)
    }

    func fetchPhotosWithDetails(forAssetIds assetIds: [String]) -> [PhotoListItem] {
        let validAssetIds = sanitizeAssetIds(assetIds)
        guard !validAssetIds.isEmpty, let db = db else { return [] }

        let validIdSet = Set(validAssetIds)
        var itemsById: [String: PhotoListItem] = [:]
        do {
            let query = """
            SELECT p.asset_id, p.is_favorite, COALESCE(c.keyword, ''), p.metadata
            FROM PhotoFeatures p
            LEFT JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            """
            for row in try db.prepare(query).run() {
                guard let assetId = row[0] as? String else { continue }
                guard validIdSet.contains(assetId) else { continue }
                let isFav = (row[1] as? Int64 ?? 0) == 1
                let tag = row[2] as? String ?? ""
                var date = ""

                if let meta = row[3] as? String,
                   let data = meta.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = dict["date"] as? String {
                    date = d
                }

                itemsById[assetId] = PhotoListItem(id: assetId, isFavorite: isFav, tag: tag, date: date)
            }
        } catch {
            print("依 asset ids 讀取照片詳情失敗: \(error)")
        }

        let orderedItems = validAssetIds.compactMap { itemsById[$0] }
        return sanitizePhotoListItems(orderedItems)
    }

    func addPhotos(_ assetIds: [String], toCustomAlbum albumId: String) {
        let dedupedAssetIds = assetIds.reduce(into: [String]()) { partialResult, assetId in
            if !partialResult.contains(assetId) {
                partialResult.append(assetId)
            }
        }

        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let maxPositionQuery = "SELECT COALESCE(MAX(position), -1) FROM UserAlbumPhotos WHERE album_id = ?"
                let currentMaxPosition = Int((try db.prepare(maxPositionQuery).run(albumId).first(where: { _ in true })?[0] as? Int64) ?? -1)

                for (offset, assetId) in dedupedAssetIds.enumerated() {
                    try db.prepare("""
                    INSERT OR IGNORE INTO UserAlbumPhotos (album_id, asset_id, position)
                    VALUES (?, ?, ?)
                    """).run(albumId, assetId, currentMaxPosition + offset + 1)
                }
            } catch {
                print("新增自定義相簿照片失敗: \(error)")
            }
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
        }
    }

    func removePhotoFromCustomAlbum(assetId: String, albumId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.prepare("""
                DELETE FROM UserAlbumPhotos
                WHERE album_id = ? AND asset_id = ?
                """).run(albumId, assetId)
            } catch {
                print("移除自定義相簿照片失敗: \(error)")
            }
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
        }
    }

    // MARK: - 相簿管理 (刪除與釘選)
    func deleteCustomAlbum(albumId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.prepare("DELETE FROM UserAlbumPhotos WHERE album_id = ?").run(albumId)
                try db.prepare("DELETE FROM UserAlbums WHERE album_id = ?").run(albumId)
                DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
            } catch { print("刪除相簿失敗: \(error)") }
        }
    }

    func togglePinCustomAlbum(albumId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.prepare("UPDATE UserAlbums SET is_pinned = CASE WHEN is_pinned = 1 THEN 0 ELSE 1 END WHERE album_id = ?").run(albumId)
                DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
            } catch { print("釘選自定義相簿失敗: \(error)") }
        }
    }

    func togglePinCategory(keyword: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let count = try db.scalar("SELECT COUNT(*) FROM PinnedCategories WHERE keyword = ?", keyword) as? Int64 ?? 0
                if count > 0 {
                    try db.prepare("DELETE FROM PinnedCategories WHERE keyword = ?").run(keyword)
                } else {
                    try db.prepare("INSERT INTO PinnedCategories (keyword) VALUES (?)").run(keyword)
                }
                DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
            } catch { print("釘選分類相簿失敗: \(error)") }
        }
    }

    // MARK: - 照片操作
    /// 這張照片是否加入最愛（App 自己的標記，不影響系統相簿）
    func isFavorite(assetId: String) -> Bool {
        guard let db = db else { return false }
        let value = try? db.scalar("SELECT is_favorite FROM PhotoFeatures WHERE asset_id = ?", assetId)
        return (value as? Int64 ?? 0) == 1
    }

    /// 最愛的照片（較新加入 App 的在前），只回傳仍在相簿中的照片
    func favoriteAssetIds(limit: Int = 200) -> [String] {
        guard let db = db else { return [] }
        var ids: [String] = []
        if let rows = try? db.prepare("SELECT asset_id FROM PhotoFeatures WHERE is_favorite = 1 ORDER BY rowid DESC LIMIT ?").run(Int64(limit)) {
            for row in rows { if let id = row[0] as? String { ids.append(id) } }
        }
        let existing = existingAssetIds(ids)
        return ids.filter { existing.contains($0) }
    }

    /// 「照片」App 的「喜好項目」同步到 App 的最愛（只讀取系統相簿，不會改系統的喜好項目）。
    /// - 系統新加的喜好項目 → App 也加入最愛
    /// - 之前從系統帶進來、後來在「照片」App 取消的 → App 也取消
    /// - 你只在 App 裡按的最愛不受影響
    static let syncSystemFavoritesKey = "syncSystemFavorites"
    private static let importedFavoritesKey = "importedSystemFavoriteIds"

    func syncSystemFavorites() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.syncSystemFavoritesKey) as? Bool ?? true else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "favorite == YES")
        var system = Set<String>()
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in system.insert(asset.localIdentifier) }

        let previous = Set(defaults.stringArray(forKey: Self.importedFavoritesKey) ?? [])
        let toAdd = system.subtracting(previous)
        // 部分存取（.limited）時看不到的照片不代表取消了喜好，只在完整存取時才取消
        let toRemove = status == .authorized ? previous.subtracting(system) : []
        guard !toAdd.isEmpty || !toRemove.isEmpty else { return }

        var imported = previous.subtracting(toRemove)
        var changed = false
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.transaction {
                    for id in toAdd {
                        try db.prepare("UPDATE PhotoFeatures SET is_favorite = 1 WHERE asset_id = ?").run(id)
                        if db.changes > 0 { imported.insert(id); changed = true }
                    }
                    for id in toRemove {
                        try db.prepare("UPDATE PhotoFeatures SET is_favorite = 0 WHERE asset_id = ?").run(id)
                        if db.changes > 0 { changed = true }
                    }
                }
            } catch {
                print("同步系統喜好項目失敗: \(error)")
            }
        }
        // 還沒掃描進 App 的照片不記錄，掃描之後下次同步會再加入
        defaults.set(Array(imported), forKey: Self.importedFavoritesKey)
        if changed {
            DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
        }
    }

    func toggleFavorite(assetId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.prepare("UPDATE PhotoFeatures SET is_favorite = CASE WHEN is_favorite = 1 THEN 0 ELSE 1 END WHERE asset_id = ?").run(assetId)
                DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
            } catch {}
        }
    }

    // 註：原本的 deletePhoto(assetId:) 已移除。它只被「從系統相簿刪除原始照片」的流程使用，
    // 而且會連同主題相簿成員一起刪除。現在 App 不再刪除原始照片，請改用
    // PersonalizationService.removeAIAnalysis(assetId:)，它只移除 AI 分析資料。

    func movePhoto(assetId: String, to targetKeyword: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let getID = "SELECT cluster_id FROM ClusterSummary WHERE keyword = ?"
                if let row = try db.prepare(getID).run(targetKeyword).first(where: { _ in true }) {
                    let tid = row[0] as? Int64 ?? 1
                    // 標記為手動分類：重新分析或移除 AI 分析資料時都會保留使用者的選擇。
                    try db.prepare("UPDATE PhotoFeatures SET cluster_id = ?, cluster_source = 'manual' WHERE asset_id = ?").run(tid, assetId)
                    DispatchQueue.main.async { NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil) }
                }
            } catch {}
        }
    }

    /// Time & Place：自動偵測旅行並產生旅遊相簿（例如「東京 8/22–8/25」）。
    /// 住家、學校、公司等常去地點由 TripDetector 依照片的時間與 GPS 自動學習並排除。
    func fetchMetadataAlbumSections() -> [MetadataAlbumSection] {
        guard let db = db else { return [] }

        var rows: [(assetId: String, metadata: String)] = []
        do {
            for row in try db.prepare("SELECT asset_id, metadata FROM PhotoFeatures").run() {
                if let assetId = row[0] as? String {
                    rows.append((assetId: assetId, metadata: row[1] as? String ?? "{}"))
                }
            }
        } catch {
            print("讀取 metadata 相簿失敗: \(error)")
            return []
        }

        let orderedAssetIds = sanitizeAssetIds(rows.map(\.assetId))
        guard !orderedAssetIds.isEmpty else { return [] }
        let metadataById = Dictionary(rows.map { ($0.assetId, $0.metadata) }, uniquingKeysWith: { first, _ in first })
        let assetsById = fetchAssetsMap(for: orderedAssetIds)

        // metadata 還沒有地區的照片：先查同一網格（約 2 km）的快取，不需要網路
        var regionByGrid: [String: GeoRegion?] = [:]
        func cachedRegionNear(_ lat: Double, _ lon: Double) -> GeoRegion? {
            let key = RegionNaming.gridKey(latitude: lat, longitude: lon)
            if let hit = regionByGrid[key] { return hit }
            let region = cachedRegion(gridKey: key)
            regionByGrid[key] = region
            return region
        }

        let photos: [GeoPhoto] = orderedAssetIds.compactMap { id in
            guard let asset = assetsById[id], let date = asset.creationDate else { return nil }
            let dict = (try? metadataDictionary(from: metadataById[id] ?? "{}")) ?? [:]
            let latitude = asset.location?.coordinate.latitude ?? (dict["latitude"] as? Double)
            let longitude = asset.location?.coordinate.longitude ?? (dict["longitude"] as? Double)
            var region: GeoRegion?
            if let name = dict["regionName"] as? String, !name.isEmpty {
                region = GeoRegion(name: name,
                                   country: dict["regionCountry"] as? String ?? "",
                                   countryCode: dict["regionCountryCode"] as? String ?? "")
            } else if let latitude, let longitude {
                region = cachedRegionNear(latitude, longitude)
            }
            return GeoPhoto(id: id, date: date, latitude: latitude, longitude: longitude, region: region,
                            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot))
        }

        let result = TripDetector.detect(photos: photos)
        lastTripDetectionInsufficientHistory = result.insufficientHistory
        tripCacheLock.lock()
        tripCache = (Date(), result)
        tripCacheLock.unlock()
        guard !result.trips.isEmpty else { return [] }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "zh_Hant_TW")
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "M/d"
        let calendar = Calendar.current

        var sectionsByYear: [(year: Int, albums: [MetadataAlbumSummary])] = []
        for trip in result.trips {   // 已依開始時間新到舊排序
            let start = dayFormatter.string(from: trip.startDate)
            let end = dayFormatter.string(from: trip.endDate)
            let dateText = start == end ? start : "\(start)–\(end)"
            var subtitleParts: [String] = []
            if let country = trip.country, !country.isEmpty { subtitleParts.append(country) }
            subtitleParts.append(dateText)
            subtitleParts.append("\(trip.dayCount) 天")
            subtitleParts.append("\(trip.allAssetIds.count) 張")

            // 還沒有地名：挑旅程中幾張照片（頭、中、尾，略過確定查不到的）優先查詢第一級行政區，查到後自動更新標題。
            // 查不到（沒有網路、多次被限流、海上等）時不再一直顯示「地點讀取中」，改用舊版地點資料或「地點未知」。
            var title = trip.title
            var pending: [String] = []
            if title == nil {
                let resolver = RegionResolver.shared
                let candidates = trip.primaryAssetIds.filter { !resolver.isExhausted($0) }
                if !candidates.isEmpty {
                    pending = Array(Set([candidates.first, candidates[candidates.count / 2], candidates.last].compactMap { $0 }))
                    resolver.enqueue(pending, priority: true)
                }
                if pending.contains(where: { resolver.isPending($0) }) {
                    title = "地點讀取中"
                } else {
                    pending = []
                    title = legacyTripPlaceName(assetIds: trip.primaryAssetIds, metadataById: metadataById) ?? "地點未知"
                }
            }

            let album = MetadataAlbumSummary(
                id: trip.id,
                title: title ?? "地點未知",
                subtitle: subtitleParts.joined(separator: " · "),
                coverAssetId: trip.primaryAssetIds[trip.primaryAssetIds.count / 2],
                photoCount: trip.allAssetIds.count,
                primaryAssetIds: trip.primaryAssetIds,
                otherAssetIds: trip.otherAssetIds,
                regionPendingAssetIds: pending
            )
            let year = calendar.component(.year, from: trip.startDate)
            if let index = sectionsByYear.firstIndex(where: { $0.year == year }) {
                sectionsByYear[index].albums.append(album)
            } else {
                sectionsByYear.append((year: year, albums: [album]))
            }
        }

        return sectionsByYear.map { section in
            MetadataAlbumSection(id: "trips-\(section.year)", title: "\(section.year) 旅行", albums: section.albums)
        }
    }

    /// 舊版掃描留下的地點欄位（tripLocality：台灣為縣市、其他國家為城市）中最常見的名稱，作為離線備援標題。
    private func legacyTripPlaceName(assetIds: [String], metadataById: [String: String]) -> String? {
        var counts: [String: Int] = [:]
        for id in assetIds {
            guard let dict = try? metadataDictionary(from: metadataById[id] ?? "{}") else { continue }
            let name = ((dict["tripLocality"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { counts[RegionNaming.shortName(name), default: 0] += 1 }
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// 最近一次偵測是否因為定位照片太少而無法判斷常去地點（UI 顯示說明用）。
    private(set) var lastTripDetectionInsufficientHistory = false

    /// 最近一次的旅程偵測結果（旅程、常去地點）。興趣紀錄用來判斷「旅行的日子」與「住家、學校附近」。
    private var tripCache: (date: Date, result: TripDetectionResult)?
    private let tripCacheLock = NSLock()

    /// 旅程與常去地點：10 分鐘內重用；沒有時重新偵測一次（只讀取照片時間與定位）。不可在主執行緒呼叫。
    func recentTripDetection(maxAge: TimeInterval = 600) -> TripDetectionResult? {
        tripCacheLock.lock()
        let cached = tripCache
        tripCacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.date) < maxAge { return cached.result }
        _ = fetchMetadataAlbumSections()
        tripCacheLock.lock()
        defer { tripCacheLock.unlock() }
        return tripCache?.result
    }

    // MARK: - 第一級行政區快取（減少反向地理編碼次數）
    private func createGeoRegionCacheTableIfNeeded() {
        guard let db = db else { return }
        do {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS GeoRegionCache (
                grid_key TEXT PRIMARY KEY,
                region_name TEXT NOT NULL,
                country TEXT,
                country_code TEXT,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """)
        } catch {
            print("建立 GeoRegionCache 失敗: \(error)")
        }
    }

    func cachedRegion(gridKey: String) -> GeoRegion? {
        guard let db = db else { return nil }
        guard let row = try? db.prepare(
            "SELECT region_name, country, country_code FROM GeoRegionCache WHERE grid_key = ?"
        ).run(gridKey).first(where: { _ in true }),
              let name = row[0] as? String else { return nil }
        return GeoRegion(name: name, country: row[1] as? String ?? "", countryCode: row[2] as? String ?? "")
    }

    func cacheRegion(_ region: GeoRegion, gridKey: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                try db.run("""
                INSERT OR REPLACE INTO GeoRegionCache (grid_key, region_name, country, country_code)
                VALUES (?, ?, ?, ?)
                """, gridKey, region.name, region.country, region.countryCode)
            } catch {
                print("寫入地區快取失敗: \(error)")
            }
        }
    }

    // MARK: - AI Agent 筆記功能
    private func createNotesTableIfNeeded() {
        guard let db = db else { return }
        do {
            let query = """
            CREATE TABLE IF NOT EXISTS AgentNotes (
                note_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                content TEXT,
                image_assets TEXT, 
                is_favorite INTEGER DEFAULT 0,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """
            try db.execute(query)
            try? db.execute("ALTER TABLE AgentNotes ADD COLUMN image_assets TEXT")
        } catch { print("建立筆記表失敗") }
    }

    func fetchNotes(onlyFavorite: Bool = false) -> [(id: String, title: String, isFavorite: Bool)] {
        guard let db = db else { return [] }
        var results: [(String, String, Bool)] = []
        do {
            var q = "SELECT note_id, title, is_favorite FROM AgentNotes"
            if onlyFavorite { q += " WHERE is_favorite = 1" }
            q += " ORDER BY created_at DESC"
            for row in try db.prepare(q).run() {
                results.append((
                    id: row[0] as? String ?? "",
                    title: row[1] as? String ?? "",
                    isFavorite: (row[2] as? Int64 ?? 0) == 1
                ))
            }
        } catch {}
        return results
    }

    func fetchNoteDetail(noteId: String) -> (content: String, images: [UIImage]) {
        guard let db = db else { return ("", []) }
        do {
            let q = "SELECT content, image_assets FROM AgentNotes WHERE note_id = ?"
            if let row = try db.prepare(q).run(noteId).first(where: { _ in true }) {
                let content = row[0] as? String ?? ""
                let imageAssetsString = row[1] as? String ?? ""
                
                var loadedImages: [UIImage] = []
                if !imageAssetsString.isEmpty {
                    let filenames = imageAssetsString.split(separator: ",").map(String.init)
                    loadedImages = filenames.compactMap { loadImageFromDisk(filename: $0) }
                }
                return (content, loadedImages)
            }
        } catch { print("讀取筆記詳情失敗") }
        return ("", [])
    }

    func insertNote(title: String, content: String, images: [UIImage] = []) {
        let filenames = images.compactMap { saveImageToDisk(image: $0) }
        let assetsString = filenames.joined(separator: ",")
        
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let q = "INSERT INTO AgentNotes (note_id, title, content, image_assets) VALUES (?, ?, ?, ?)"
                try db.prepare(q).run(UUID().uuidString, title, content, assetsString)
            } catch { print("新增筆記失敗") }
        }
    }

    func toggleNoteFavorite(noteId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do { try db.prepare("UPDATE AgentNotes SET is_favorite = CASE WHEN is_favorite = 1 THEN 0 ELSE 1 END WHERE note_id = ?").run(noteId) } catch {}
        }
    }

    func deleteNote(noteId: String) {
        writeQueue.sync {
            guard let db = self.db else { return }
            do { try db.prepare("DELETE FROM AgentNotes WHERE note_id = ?").run(noteId) } catch {}
        }
    }
    
    // MARK: - 本機圖片存取輔助
    private func saveImageToDisk(image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let filename = UUID().uuidString + ".jpg"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        do {
            try data.write(to: url)
            return filename
        } catch { return nil }
    }

    private func loadImageFromDisk(filename: String) -> UIImage? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        }
        return nil
    }

    // MARK: - 搜尋與 Metadata 讀取
    /// 首頁搜尋：日期／地點文字比對 + MobileCLIP 向量相似度。
    /// 改用記憶體快取：不再每次搜尋都讀整個資料表、解碼向量與 JSON。計分規則與門檻和以前相同。
    func searchPhotos(text: String, textEmbedding: [Float]? = nil) -> [String] {
        let rows = featureCacheSnapshot()
        let lowerText = text.lowercased()
        let normalizedDateQuery = normalizedDayKey(from: text)
        // 日期、地點文字符合的照片一定列出；照片向量的分數另外判斷（見 VectorSearchCutoff）
        var metadataScores: [String: Float] = [:]
        var similarities: [(id: String, score: Float)] = []
        similarities.reserveCapacity(rows.count)

        for (assetId, feature) in rows {
            if !lowerText.isEmpty, let metadataInfo = feature.metadata {
                let score = metadataSearchScore(query: lowerText, normalizedDateQuery: normalizedDateQuery, metadata: metadataInfo)
                if score > 0 { metadataScores[assetId] = score }
            }
            if let queryVector = textEmbedding, let imageVector = feature.embedding {
                similarities.append((id: assetId, score: cosineSimilarity(queryVector, imageVector)))
            }
        }

        // 相簿裡沒有的東西不會再列出一堆不相關的照片：只留下明顯比其他照片更像的
        var totals = metadataScores
        let similarityById = Dictionary(similarities.map { ($0.id, $0.score) }, uniquingKeysWith: max)
        for (id, score) in metadataScores { totals[id] = score + (similarityById[id] ?? 0) }
        for item in VectorSearchCutoff.filter(similarities) {
            totals[item.id] = (metadataScores[item.id] ?? 0) + item.score
        }
        return totals.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// 智慧搜尋找到的照片裡，哪些和查詢「至少有點像」（照片向量的分數明顯高於相簿平均，見 VectorSearchCutoff.plausible）
    func plausibleMatches(_ assetIds: Set<String>, textEmbedding: [Float]) -> Set<String> {
        let rows = featureCacheSnapshot()
        var scores: [(id: String, score: Float)] = []
        scores.reserveCapacity(rows.count)
        for (assetId, feature) in rows {
            if let imageVector = feature.embedding {
                scores.append((id: assetId, score: cosineSimilarity(textEmbedding, imageVector)))
            }
        }
        return VectorSearchCutoff.plausible(assetIds, among: scores)
    }

    /// - Parameter notify: 是否廣播 DatabaseUpdated。大量背景寫入（例如地區查詢）應傳 false 並自行批次通知，
    ///   避免每寫一張就讓畫面整頁重新載入。
    func updatePhotoMetadata(assetId: String, merge updates: [String: Any], notify: Bool = true) {
        guard !updates.isEmpty else { return }

        var didUpdate = false
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                let selectQuery = "SELECT metadata FROM PhotoFeatures WHERE asset_id = ?"
                let existingMetadata = try db.prepare(selectQuery).run(assetId).first(where: { _ in true })?[0] as? String ?? "{}"
                var metadataDict = (try? metadataDictionary(from: existingMetadata)) ?? [:]

                for (key, value) in updates {
                    metadataDict[key] = value
                }

                let data = try JSONSerialization.data(withJSONObject: metadataDict, options: [])
                let metadataString = String(data: data, encoding: .utf8) ?? "{}"
                try db.prepare("UPDATE PhotoFeatures SET metadata = ? WHERE asset_id = ?").run(metadataString, assetId)
                didUpdate = true
                self.updateCachedMetadata(assetId: assetId, json: metadataString)
            } catch {
                print("更新照片 metadata 失敗: \(error)")
            }
        }

        if didUpdate && notify {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
            }
        }
    }

    func fetchAssetIdsNeedingLocationMetadata(limit: Int = 50) -> [String] {
        guard let db = db else { return [] }

        var assetIds: [String] = []
        do {
            // 需要（重新）取得第一級行政區的照片：有座標，但還沒有 v2 地區資料（regionVersion = 2）。
            let query = """
            SELECT asset_id
            FROM PhotoFeatures
            WHERE metadata LIKE '%"latitude"%'
              AND metadata NOT LIKE '%"regionVersion":2%'
            ORDER BY rowid DESC
            LIMIT ?
            """
            for row in try db.prepare(query).run(limit) {
                if let assetId = row[0] as? String {
                    assetIds.append(assetId)
                }
            }
        } catch {
            print("讀取待補地點 metadata 照片失敗: \(error)")
        }
        return assetIds
    }

    private func metadataDictionary(from metadata: String) throws -> [String: Any] {
        guard let data = metadata.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return dict
    }

    private func sanitizePhotoListItems(_ items: [PhotoListItem]) -> [PhotoListItem] {
        let validIds = Set(sanitizeAssetIds(items.map(\.id)))
        return items.filter { validIds.contains($0.id) }
    }

    private func sanitizeAssetIds(_ assetIds: [String]) -> [String] {
        guard !assetIds.isEmpty else { return [] }
        let (validIds, missingIds) = splitExistingAssetIds(assetIds)
        // 只有在「完整相簿存取權」時，查不到的照片才代表真的已被刪除。
        // 部分存取（.limited）時，未被選取的照片同樣查不到；這時刪除資料會讓主題相簿與手動標籤遺失，因此只過濾不清理。
        if !missingIds.isEmpty && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
            removeMissingAssetsFromDatabase(assetIds: missingIds)
        }
        return validIds
    }

    /// 使用者在「照片」App 刪了照片後：找出 App 資料裡已經不存在的照片，只清理 App 自己的資料（分析結果、相簿連結），
    /// 並廣播 DatabaseUpdated 讓畫面重新讀取。不會修改或刪除任何照片。
    /// 只在「完整相簿存取權」時清理（部分存取時查不到不代表被刪除）。
    func pruneDeletedPhotos() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized, let db = db else { return }
        var assetIds: [String] = []
        do {
            for row in try db.prepare("SELECT asset_id FROM PhotoFeatures UNION SELECT asset_id FROM UserAlbumPhotos").run() {
                if let assetId = row[0] as? String, !assetId.isEmpty { assetIds.append(assetId) }
            }
        } catch {
            print("讀取照片清單失敗: \(error)")
            return
        }
        let missing = splitExistingAssetIds(assetIds).missingIds
        if !missing.isEmpty { removeMissingAssetsFromDatabase(assetIds: missing) }
    }

    /// 唯讀查詢：哪些照片目前仍存在且可存取。不會清理或修改任何資料。
    func existingAssetIds(_ assetIds: [String]) -> Set<String> {
        guard !assetIds.isEmpty else { return [] }
        return Set(splitExistingAssetIds(assetIds).validIds)
    }

    private func splitExistingAssetIds(_ assetIds: [String]) -> (validIds: [String], missingIds: [String]) {
        let uniqueAssetIds = Array(NSOrderedSet(array: assetIds)).compactMap { $0 as? String }
        guard !uniqueAssetIds.isEmpty else { return ([], []) }

        var existingIds = Set<String>()
        for chunk in uniqueAssetIds.chunked(into: 200) {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
            fetchResult.enumerateObjects { asset, _, _ in
                existingIds.insert(asset.localIdentifier)
            }
        }

        let validIds = assetIds.filter { existingIds.contains($0) }
        let missingIds = uniqueAssetIds.filter { !existingIds.contains($0) }
        return (validIds, missingIds)
    }

    private func removeMissingAssetsFromDatabase(assetIds: [String]) {
        guard !assetIds.isEmpty else { return }

        var didUpdate = false
        writeQueue.sync {
            guard let db = self.db else { return }
            do {
                // 這些照片已不存在於系統相簿（使用者在「照片」App 中刪除），只清理 App 自己的資料。
                // 包在同一個 transaction：上千張時只寫一次硬碟
                try db.transaction {
                    for assetId in assetIds {
                        try db.prepare("DELETE FROM UserAlbumPhotos WHERE asset_id = ?").run(assetId)
                        try db.prepare("DELETE FROM PhotoFeatures WHERE asset_id = ?").run(assetId)
                        try? db.prepare("DELETE FROM PhotoTags WHERE asset_id = ? AND source = 'auto'").run(assetId)
                        try? db.prepare("DELETE FROM PhotoAnalysisState WHERE asset_id = ?").run(assetId)
                    }
                }
                didUpdate = true
            } catch {
                print("清理失效照片失敗: \(error)")
            }
        }

        if didUpdate {
            removeFromFeatureCache(assetIds: assetIds)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
            }
        }
    }

    private func fetchAssetsMap(for assetIds: [String]) -> [String: PHAsset] {
        guard !assetIds.isEmpty else { return [:] }
        var assetsById: [String: PHAsset] = [:]
        for chunk in assetIds.chunked(into: 200) {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
            fetchResult.enumerateObjects { asset, _, _ in
                assetsById[asset.localIdentifier] = asset
            }
        }
        return assetsById
    }

    private func resolvedDayKey(asset: PHAsset, metadata: [String: Any]) -> String {
        if let dayKey = metadata["dayKey"] as? String, !dayKey.isEmpty {
            return dayKey
        }
        if let date = asset.creationDate {
            return metadataDayFormatter.string(from: date)
        }
        return ""
    }

    private func resolvedLocationLabel(asset: PHAsset, metadata: [String: Any]) -> String {
        if let locationText = metadata["locationText"] as? String,
           !locationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return locationText
        }
        if let coordinateText = metadata["coordinateText"] as? String,
           !coordinateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return coordinateText
        }
        if let location = asset.location {
            return String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
        }
        return ""
    }

    private func journeyTitle(from locationLabel: String, fallbackDayKey: String) -> String {
        let parts = locationLabel
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = parts.first, !first.isEmpty {
            return first
        }
        return fallbackDayKey
    }

    private func journeySubtitle(dayKey: String, locationLabel: String) -> String {
        let title = journeyTitle(from: locationLabel, fallbackDayKey: dayKey)
        let trailingLocation = locationLabel
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .dropFirst()
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        let parts = [dayKey, trailingLocation]
            .filter { !$0.isEmpty && $0.lowercased() != title.lowercased() }
        return parts.joined(separator: " • ")
    }

    private func sourceInfo(for asset: PHAsset) -> (label: String, detail: String) {
        let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
        let normalizedFilename = filename.lowercased()

        let appHints: [(token: String, label: String)] = [
            ("whatsapp", "WhatsApp"),
            ("instagram", "Instagram"),
            ("telegram", "Telegram"),
            ("line", "LINE"),
            ("messenger", "Messenger"),
            ("facebook", "Facebook"),
            ("discord", "Discord"),
            ("slack", "Slack"),
            ("xiaohongshu", "Xiaohongshu"),
            ("rednote", "Rednote"),
            ("tiktok", "TikTok"),
            ("douyin", "Douyin"),
            ("wechat", "WeChat")
        ]

        if let appHint = appHints.first(where: { normalizedFilename.contains($0.token) }) {
            return (appHint.label, filename)
        }

        if asset.sourceType.contains(.typeCloudShared) {
            return ("Shared Album", filename)
        }

        if asset.sourceType.contains(.typeiTunesSynced) {
            return ("Synced Import", filename)
        }

        if !filename.isEmpty && !isGenericCameraFilename(filename) {
            return ("Downloaded / Imported", filename)
        }

        return ("", filename)
    }

    private func isGenericCameraFilename(_ filename: String) -> Bool {
        let uppercased = filename.uppercased()
        let commonPrefixes = ["IMG_", "DSC_", "PXL_", "MVIMG_", "VID_", "PHOTO_", "IMAGE_"]
        return commonPrefixes.contains { uppercased.hasPrefix($0) }
    }

    private func parsedMetadataInfo(from metadata: String) -> (date: String, dayKey: String, locationText: String, coordinateText: String)? {
        guard let dict = try? metadataDictionary(from: metadata) else { return nil }
        let date = (dict["date"] as? String ?? "").lowercased()
        let dayKey = (dict["dayKey"] as? String ?? "").lowercased()
        let locationText = (dict["locationText"] as? String ?? "").lowercased()
        let coordinateText = (dict["coordinateText"] as? String ?? "").lowercased()
        return (date: date, dayKey: dayKey, locationText: locationText, coordinateText: coordinateText)
    }

    private func metadataSearchScore(
        query: String,
        normalizedDateQuery: String?,
        metadata: (date: String, dayKey: String, locationText: String, coordinateText: String)
    ) -> Float {
        var score: Float = 0

        if let normalizedDateQuery, !metadata.dayKey.isEmpty {
            if metadata.dayKey == normalizedDateQuery {
                score += 2.4
            } else if metadata.dayKey.contains(normalizedDateQuery) {
                score += 1.2
            }
        }

        if !metadata.locationText.isEmpty {
            if metadata.locationText == query {
                score += 2.0
            } else if metadata.locationText.contains(query) {
                score += 1.5
            }
        }

        if !metadata.coordinateText.isEmpty, metadata.coordinateText.contains(query) {
            score += 1.0
        }

        if !metadata.date.isEmpty, metadata.date.contains(query) {
            score += 0.8
        }

        return score
    }

    private func normalizedDayKey(from query: String) -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        for formatter in queryDateFormatters {
            if let date = formatter.date(from: trimmedQuery) {
                let outputFormatter = DateFormatter()
                outputFormatter.locale = Locale(identifier: "en_US_POSIX")
                outputFormatter.timeZone = .current
                outputFormatter.dateFormat = "yyyy-MM-dd"
                return outputFormatter.string(from: date).lowercased()
            }
        }

        let regexPatterns = [
            #"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$"#,
            #"^(\d{4})年(\d{1,2})月(\d{1,2})日$"#
        ]

        for pattern in regexPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmedQuery, range: NSRange(trimmedQuery.startIndex..., in: trimmedQuery)),
               match.numberOfRanges == 4,
               let yearRange = Range(match.range(at: 1), in: trimmedQuery),
               let monthRange = Range(match.range(at: 2), in: trimmedQuery),
               let dayRange = Range(match.range(at: 3), in: trimmedQuery) {
                let year = String(trimmedQuery[yearRange])
                let month = String(trimmedQuery[monthRange]).leftPadding(toLength: 2, withPad: "0")
                let day = String(trimmedQuery[dayRange]).leftPadding(toLength: 2, withPad: "0")
                return "\(year)-\(month)-\(day)".lowercased()
            }
        }

        return nil
    }

    func fetchPhotoDetail(assetId: String) -> (metadata: String, tag: String)? {
        guard let db = db else { return nil }
        do {
            let query = """
            SELECT p.metadata, c.keyword
            FROM PhotoFeatures p
            LEFT JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE p.asset_id = ?
            """
            if let row = try db.prepare(query).run(assetId).first(where: { _ in true }) {
                return (row[0] as? String ?? "{}", row[1] as? String ?? "Unknown")
            }
        } catch {}
        return nil
    }
    
    // MARK: - 抓取全部照片 (UI 顯示用)
    /// 依照片拍攝時間（PhotoKit creationDate，唯讀）排序；找不到的照片保持原順序排在最後。
    func sortAssetIdsByCreationDate(_ assetIds: [String], newestFirst: Bool = true) -> [String] {
        guard assetIds.count > 1 else { return assetIds }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: !newestFirst)]
        let result = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: options)
        var ordered: [String] = []
        ordered.reserveCapacity(assetIds.count)
        var seen = Set<String>()
        result.enumerateObjects { asset, _, _ in
            if seen.insert(asset.localIdentifier).inserted { ordered.append(asset.localIdentifier) }
        }
        ordered.append(contentsOf: assetIds.filter { !seen.contains($0) })
        return ordered
    }

    /// 依拍攝時間由新到舊排列照片清單。
    func sortedNewestFirst(_ photos: [PhotoListItem]) -> [PhotoListItem] {
        let order = sortAssetIdsByCreationDate(photos.map(\.id), newestFirst: true)
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return photos.sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
    }

    /// 首頁「全部照片」：依拍攝時間新到舊。
    /// 比 sortedNewestFirst(fetchAllPhotosWithDetails()) 快：日期直接由 SQLite 取出（不必逐筆解析 JSON），
    /// 照片庫只查一次（同時排序與確認照片仍存在）。結果與原本相同。
    func fetchAllPhotosNewestFirst() -> [PhotoListItem] {
        guard let db = db else { return [] }
        var itemsById: [String: PhotoListItem] = [:]
        var ids: [String] = []
        do {
            let query = """
            SELECT p.asset_id, p.is_favorite, COALESCE(c.keyword, ''),
                   CASE WHEN json_valid(p.metadata) THEN json_extract(p.metadata, '$.date') END
            FROM PhotoFeatures p
            LEFT JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            ORDER BY p.rowid DESC
            """
            for row in try db.prepare(query).run() {
                guard let assetId = row[0] as? String, itemsById[assetId] == nil else { continue }
                let item = PhotoListItem(id: assetId, isFavorite: (row[1] as? Int64 ?? 0) == 1,
                                         tag: row[2] as? String ?? "", date: row[3] as? String ?? "")
                itemsById[assetId] = item
                ids.append(assetId)
            }
        } catch {
            // 舊版 SQLite 沒有 JSON 函式時退回原本的做法
            print("讀取全部照片（快速）失敗，改用原本方式: \(error)")
            return sortedNewestFirst(fetchAllPhotosWithDetails())
        }
        guard !ids.isEmpty else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var ordered: [PhotoListItem] = []
        ordered.reserveCapacity(ids.count)
        var seen = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options).enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            if seen.insert(id).inserted, let item = itemsById[id] { ordered.append(item) }
        }
        // 與 sanitizePhotoListItems 相同：完整存取權時，查不到的照片代表已被刪除，只清理 App 自己的資料
        let missing = ids.filter { !seen.contains($0) }
        if !missing.isEmpty && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
            removeMissingAssetsFromDatabase(assetIds: missing)
        }
        return ordered
    }

    func fetchAllPhotosWithDetails() -> [PhotoListItem] {
        guard let db = db else { return [] }
        var results: [PhotoListItem] = []
        
        do {
            let query = """
            SELECT p.asset_id, p.is_favorite, COALESCE(c.keyword, ''), p.metadata
            FROM PhotoFeatures p
            LEFT JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            ORDER BY p.rowid DESC
            """
            for row in try db.prepare(query).run() {
                guard let assetId = row[0] as? String else { continue }
                let isFav = (row[1] as? Int64 ?? 0) == 1
                let tag = row[2] as? String ?? ""
                var date = ""
                
                if let meta = row[3] as? String,
                   let data = meta.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let d = dict["date"] as? String {
                    date = d
                }
                results.append(PhotoListItem(id: assetId, isFavorite: isFav, tag: tag, date: date))
            }
        } catch {
            print("讀取全部照片失敗: \(error)")
        }
        
        return sanitizePhotoListItems(results)
    }

    /// 舊版抽象語意搜尋的場景圖（SceneGraphs 資料表）已由 AbstractSearch 模組取代
    /// （新資料存在 Application Support/AbstractSearch.sqlite）。這張表只存 App 自己產生的 AI 分析結果，
    /// 刪除它不影響任何照片或相簿。資料表不存在時不做任何事。
    private func dropLegacySceneGraphTable() {
        guard let db = db else { return }
        do {
            try db.execute("DROP TABLE IF EXISTS SceneGraphs")
        } catch {
            print("刪除舊版 SceneGraphs 資料表失敗: \(error)")
        }
    }
}

// MARK: - 照片特徵快取

/// 一張照片在快取中的資料：向量（移除 AI 分析後為 nil）與解析好的 metadata（搜尋用）。
struct CachedPhotoFeature {
    var embedding: [Float]?
    var metadata: (date: String, dayKey: String, locationText: String, coordinateText: String)?
}

extension DatabaseManager {

    /// 第一次使用時從資料庫載入（之後只做增量更新）。App 啟動後會在背景先載入一次。
    func warmUpFeatureCache() {
        DispatchQueue.global(qos: .utility).async { _ = self.featureCacheSnapshot() }
    }

    /// 所有照片（含沒有向量、只有 metadata 的照片）
    func featureCacheSnapshot() -> [String: CachedPhotoFeature] {
        featureCacheLock.lock()
        defer { featureCacheLock.unlock() }
        if !featureCacheLoaded {
            featureCache = loadFeatureRows(assetIds: nil)
            featureCacheLoaded = true
        }
        return featureCache
    }

    /// 有向量、未移除 AI 分析的照片（與 PersonalizationStore.activeEmbeddings() 相同的範圍，但不讀資料庫）。
    /// 回傳的陣列和快取共用記憶體（copy-on-write），不會複製向量。
    func cachedActiveEmbeddings() -> [(assetId: String, embedding: [Float])] {
        featureCacheSnapshot().compactMap { id, feature in
            guard let vector = feature.embedding, !vector.isEmpty else { return nil }
            return (assetId: id, embedding: vector)
        }
    }

    /// 重新讀取指定照片（寫入向量、移除 AI 分析、重新分析之後呼叫）。快取還沒載入時不做事。
    func refreshFeatureCache(assetIds: [String]) {
        guard !assetIds.isEmpty else { return }
        featureCacheLock.lock()
        defer { featureCacheLock.unlock() }
        guard featureCacheLoaded else { return }
        let fresh = loadFeatureRows(assetIds: assetIds)
        for id in assetIds { featureCache[id] = fresh[id] }   // 資料表中已不存在 → 移除
    }

    fileprivate func updateCachedMetadata(assetId: String, json: String) {
        featureCacheLock.lock()
        defer { featureCacheLock.unlock() }
        guard featureCacheLoaded, featureCache[assetId] != nil else { return }
        featureCache[assetId]?.metadata = parsedMetadataInfo(from: json)
    }

    fileprivate func removeFromFeatureCache(assetIds: [String]) {
        featureCacheLock.lock()
        defer { featureCacheLock.unlock() }
        for id in assetIds { featureCache[id] = nil }
    }

    /// nil = 全部照片
    private func loadFeatureRows(assetIds: [String]?) -> [String: CachedPhotoFeature] {
        guard let db = db else { return [:] }
        var result: [String: CachedPhotoFeature] = [:]
        func add(_ row: [Binding?]) {
            guard let assetId = row[0] as? String else { return }
            var embedding: [Float]?
            if let blob = row[2] as? Blob, !blob.bytes.isEmpty {
                embedding = Data(blob.bytes).toArray(type: Float.self)
            }
            result[assetId] = CachedPhotoFeature(embedding: embedding,
                                                 metadata: parsedMetadataInfo(from: (row[1] as? String) ?? ""))
        }
        do {
            if let assetIds {
                let statement = try db.prepare("SELECT asset_id, metadata, image_embedding FROM PhotoFeatures WHERE asset_id = ?")
                for id in assetIds {
                    for row in try statement.run(id) { add(row) }
                }
            } else {
                result.reserveCapacity(10_000)
                for row in try db.prepare("SELECT asset_id, metadata, image_embedding FROM PhotoFeatures").run() { add(row) }
            }
        } catch {
            print("載入照片特徵快取失敗: \(error)")
        }
        return result
    }
}

// MARK: - 輔助擴充 (Extensions)
extension Data {
    func toArray<T>(type: T.Type) -> [T] {
        return self.withUnsafeBytes { pointer in
            Array(UnsafeBufferPointer(start: pointer.baseAddress!.assumingMemoryBound(to: T.self), count: self.count / MemoryLayout<T>.size))
        }
    }
}

extension String {
    fileprivate func leftPadding(toLength: Int, withPad pad: String) -> String {
        guard count < toLength else { return self }
        return String(repeating: pad, count: toLength - count) + self
    }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - 搜尋結果篩選與相似照片

extension DatabaseManager {

    /// 搜尋結果篩選用的資料：拍攝時間、地區、是不是截圖（一次讀出；只讀取，不修改任何資料）
    func searchFacts(for assetIds: [String]) -> [String: PhotoSearchFacts] {
        guard let db = db, !assetIds.isEmpty else { return [:] }
        let unique = Array(Set(assetIds))
        var metadataById: [String: String] = [:]
        for chunk in unique.chunked(into: 400) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let bindings: [Binding?] = chunk.map { $0 }
            if let rows = try? db.prepare("SELECT asset_id, metadata FROM PhotoFeatures WHERE asset_id IN (\(placeholders))").run(bindings) {
                for row in rows {
                    if let id = row[0] as? String { metadataById[id] = row[1] as? String ?? "{}" }
                }
            }
        }
        let assets = fetchAssetsMap(for: unique)
        var gridCache: [String: GeoRegion?] = [:]
        var result: [String: PhotoSearchFacts] = [:]
        for id in unique {
            let asset = assets[id]
            let dict = (metadataById[id].flatMap { $0.data(using: .utf8) })
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var region: GeoRegion?
            if let name = dict["regionName"] as? String, !name.isEmpty {
                region = GeoRegion(name: name, country: dict["regionCountry"] as? String ?? "",
                                   countryCode: dict["regionCountryCode"] as? String ?? "")
            } else if let lat = asset?.location?.coordinate.latitude ?? (dict["latitude"] as? Double),
                      let lon = asset?.location?.coordinate.longitude ?? (dict["longitude"] as? Double) {
                let key = RegionNaming.gridKey(latitude: lat, longitude: lon)
                if let cached = gridCache[key] {
                    region = cached
                } else {
                    region = cachedRegion(gridKey: key)
                    gridCache[key] = region
                }
            }
            guard asset != nil || !dict.isEmpty else { continue }
            result[id] = PhotoSearchFacts(date: asset?.creationDate, region: region?.name, country: region?.country,
                                          countryCode: region?.countryCode,
                                          isScreenshot: asset?.mediaSubtypes.contains(.photoScreenshot) ?? false)
        }
        return result
    }

    /// 搜尋句子裡可以認出來的地名：你照片裡出現過的地區與國家（地區快取裡查得到的）
    func knownSearchPlaces() -> [SearchKnownPlace] {
        guard let db = db, let rows = try? db.prepare(
            "SELECT DISTINCT region_name, country, country_code FROM GeoRegionCache"
        ).run() else { return [] }
        var regionNames = Set<String>()
        var countries: [String: String] = [:]
        for row in rows {
            let name = row[0] as? String ?? ""
            let country = row[1] as? String ?? ""
            let code = (row[2] as? String ?? "").uppercased()
            if !name.isEmpty && name != country { regionNames.insert(name) }
            if !country.isEmpty, !code.isEmpty { countries[code] = country }
        }
        var places: [SearchKnownPlace] = []
        var countryNames = Set<String>()
        for (code, name) in countries {
            places.append(SearchKnownPlace(name: name, filter: .country(code: code, name: name)))
            countryNames.insert(name)
            // 地區資料的國名（例如「臺灣」）之外，也認常用的中文國名（例如「台灣」「韓國」）
            let common = ShoppingCountry.name(for: code)
            if common != name && common != code {
                places.append(SearchKnownPlace(name: common, filter: .country(code: code, name: name)))
                countryNames.insert(common)
            }
        }
        // 有些國家（例如泰國）的照片沒有更細的地區，地區名稱就是國名：搜尋「泰國」時要用整個國家，
        // 不能只找「地區叫泰國」的那幾張（在曼谷拍的照片地區是「曼谷」，會被漏掉）
        for name in regionNames.sorted() where !countryNames.contains(name) {
            places.insert(SearchKnownPlace(name: name, filter: .region(name: name)), at: 0)
        }
        return places
    }

    /// 和這張照片最像的照片（MobileCLIP 照片向量的相似度，不含自己），由像到不像
    func similarPhotos(to assetId: String, limit: Int = 60, minimumScore: Float = 0.5) -> [(assetId: String, score: Float)] {
        let cache = featureCacheSnapshot()
        guard let target = cache[assetId]?.embedding, !target.isEmpty else { return [] }
        var targetNorm: Float = 0
        vDSP_svesq(target, 1, &targetNorm, vDSP_Length(target.count))
        guard targetNorm > 0 else { return [] }
        var scored: [(assetId: String, score: Float)] = []
        scored.reserveCapacity(cache.count)
        for (id, feature) in cache where id != assetId {
            guard let vector = feature.embedding, vector.count == target.count else { continue }
            var dot: Float = 0, norm: Float = 0
            vDSP_dotpr(target, 1, vector, 1, &dot, vDSP_Length(target.count))
            vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
            guard norm > 0 else { continue }
            let score = dot / (targetNorm.squareRoot() * norm.squareRoot())
            if score >= minimumScore { scored.append((id, score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.assetId < $1.assetId }
        let top = Array(scored.prefix(limit * 2))
        let existing = existingAssetIds(top.map(\.assetId))
        return Array(top.filter { existing.contains($0.assetId) }.prefix(limit))
    }
}


// MARK: - 照片被刪除時自動更新

/// 監聽系統相簿的變動（使用者在「照片」App 刪除照片後回到 App），不用按「整理」就把已刪除的照片從畫面上拿掉。
/// 只讀取相簿、只清理 App 自己的資料，不會修改、移動或刪除任何照片。
final class PhotoLibraryDeletionWatcher: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoLibraryDeletionWatcher()

    private var registered = false
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.photoai.deletionWatcher", qos: .utility)

    /// 有相簿存取權時開始監聽（不會跳出權限詢問）；App 回到前景時也檢查一次。
    /// 部分存取（.limited）也監聽，讓喜好項目可以同步；清理已刪除照片仍只在完整存取時進行（pruneDeletedPhotos 自己會檢查）。
    func start() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        if !registered {
            registered = true
            PHPhotoLibrary.shared().register(self)
            NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                                   name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        schedule()
    }

    @objc private func appBecameActive() { schedule() }

    func photoLibraryDidChange(_ changeInstance: PHChange) { schedule() }

    /// 短時間內的多次變動合併成一次檢查
    private func schedule() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem {
                // 喜好項目先同步：只查系統的喜好項目，很快；清理已刪除照片要逐一比對所有照片，照片多時要好幾秒，
                // 放在前面會讓最愛晚很久才出現。
                DatabaseManager.shared.syncSystemFavorites()
                DatabaseManager.shared.pruneDeletedPhotos()
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }
}

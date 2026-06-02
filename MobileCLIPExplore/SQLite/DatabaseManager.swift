import Foundation
import CoreML
import SQLite
import UIKit // 🌟 需要 UIKit 來處理 UIImage

class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: Connection?
    
    private init() {
        copyDatabaseIfNeeded()
        connectDatabase()
        createNotesTableIfNeeded()
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
        } catch { print("連接資料庫失敗: \(error)") }
    }

    // MARK: - 照片分類查詢
    func fetchGroupedCategories() -> [(main: String, subs: [String])] {
        guard let db = db else { return [] }
        var groupedDict: [String: [String]] = [:]
        do {
            let query = "SELECT parent_category, keyword FROM ClusterSummary"
            let statement = try db.prepare(query)
            for row in try statement.run() {
                if let parent = row[0] as? String, let keyword = row[1] as? String {
                    groupedDict[parent, default: []].append(keyword)
                }
            }
        } catch { print("讀取階層分類失敗: \(error)") }
        return groupedDict.map { (main: $0.key, subs: $0.value) }.sorted { $0.main < $1.main }
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
        return assetIds
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
        return results
    }

    // MARK: - 照片同步與 AI 自動分類邏輯
    func insertPhotoFeature(assetId: String, metadata: String, embeddingData: Data) {
        guard let db = db else { return }
        let photoEmbedding = embeddingData.toArray(type: Float.self)
        let targetClusterId = findBestMatchClusterId(for: photoEmbedding, threshold: 0.21) ?? -1
        
        do {
            let insertQuery = """
            INSERT OR REPLACE INTO PhotoFeatures (asset_id, metadata, image_embedding, cluster_id, is_favorite) 
            VALUES (?, ?, ?, ?, 0)
            """
            let statement = try db.prepare(insertQuery)
            try statement.run(assetId, metadata, Blob(bytes: [UInt8](embeddingData)), targetClusterId)
        } catch { print("寫入照片失敗: \(error)") }
    }

    private func findBestMatchClusterId(for photoEmbedding: [Float], threshold: Float) -> Int? {
        guard let db = db else { return nil }
        var bestId: Int? = nil
        var maxSim: Float = -1.0
        
        do {
            let query = """
            SELECT c.cluster_id, s.word_embedding 
            FROM ClusterSummary c
            JOIN SemanticDictionary s ON c.keyword = s.keyword
            """
            for row in try db.prepare(query).run() {
                let id = Int(row[0] as? Int64 ?? 1)
                if let blob = row[1] as? Blob {
                    let wordEmbedding = Data(blob.bytes).toArray(type: Float.self)
                    let sim = cosineSimilarity(photoEmbedding, wordEmbedding)
                    if sim > maxSim {
                        maxSim = sim
                        bestId = id
                    }
                }
            }
        } catch { print("比對失敗: \(error)") }
        
        return maxSim >= threshold ? bestId : nil
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        let dotProduct = zip(a, b).map(*).reduce(0, +)
        let magA = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let magB = sqrt(b.map { $0 * $0 }.reduce(0, +))
        return (magA * magB) == 0 ? 0 : dotProduct / (magA * magB)
    }

    func fetchAllScannedAssetIds() -> Set<String> {
        guard let db = db else { return [] }
        var ids = Set<String>()
        do {
            for row in try db.prepare("SELECT asset_id FROM PhotoFeatures").run() {
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

    // 含 tag 與日期的詳細查詢 (供 CategoryDetailView 搜尋用)
    func fetchPhotosWithDetails(for keyword: String) -> [(id: String, isFavorite: Bool, tag: String, date: String)] {
        guard let db = db else { return [] }
        var results: [(id: String, isFavorite: Bool, tag: String, date: String)] = []
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
                results.append((id: assetId, isFavorite: isFav, tag: tag, date: date))
            }
        } catch { print("fetchPhotosWithDetails failed: \(error)") }
        return results
    }

    func countAllPhotos() -> Int {
        guard let db = db else { return 0 }
        if let row = try? db.prepare("SELECT COUNT(*) FROM PhotoFeatures").run().first(where: { _ in true }),
           let n = row[0] as? Int64 { return Int(n) }
        return 0
    }

    // MARK: - 照片操作
    func toggleFavorite(assetId: String) {
        guard let db = db else { return }
        do {
            try db.prepare("UPDATE PhotoFeatures SET is_favorite = CASE WHEN is_favorite = 1 THEN 0 ELSE 1 END WHERE asset_id = ?").run(assetId)
            NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
        } catch {}
    }

    func deletePhoto(assetId: String) {
        guard let db = db else { return }
        do {
            try db.prepare("DELETE FROM PhotoFeatures WHERE asset_id = ?").run(assetId)
            NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
        } catch {}
    }

    func movePhoto(assetId: String, to targetKeyword: String) {
        guard let db = db else { return }
        do {
            let getID = "SELECT cluster_id FROM ClusterSummary WHERE keyword = ?"
            if let row = try db.prepare(getID).run(targetKeyword).first(where: { _ in true }) {
                let tid = row[0] as? Int64 ?? 1
                try db.prepare("UPDATE PhotoFeatures SET cluster_id = ? WHERE asset_id = ?").run(tid, assetId)
                NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
            }
        } catch {}
    }

    // MARK: - AI Agent 筆記功能 (🌟 已升級圖片支援)
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
            
            // 兼容舊資料表：若沒有 image_assets 欄位則自動補上
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

    // 🌟 返回內容與載入的圖片
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

    // 🌟 插入筆記並儲存圖片
    func insertNote(title: String, content: String, images: [UIImage] = []) {
        guard let db = db else { return }
        
        let filenames = images.compactMap { saveImageToDisk(image: $0) }
        let assetsString = filenames.joined(separator: ",")
        
        do {
            let q = "INSERT INTO AgentNotes (note_id, title, content, image_assets) VALUES (?, ?, ?, ?)"
            try db.prepare(q).run(UUID().uuidString, title, content, assetsString)
        } catch { print("新增筆記失敗") }
    }

    func toggleNoteFavorite(noteId: String) {
        guard let db = db else { return }
        do { try db.prepare("UPDATE AgentNotes SET is_favorite = CASE WHEN is_favorite = 1 THEN 0 ELSE 1 END WHERE note_id = ?").run(noteId) } catch {}
    }

    func deleteNote(noteId: String) {
        guard let db = db else { return }
        do { try db.prepare("DELETE FROM AgentNotes WHERE note_id = ?").run(noteId) } catch {}
    }
    
    // MARK: - 本機圖片存取輔助 (🌟 新增)
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
    func searchPhotos(text: String, textEmbedding: [Float]? = nil) -> [String] {
        guard let db = db else { return [] }
        var scoredResults: [(id: String, score: Float)] = []
        let lowerText = text.lowercased()

        do {
            // JOIN ClusterSummary 以取得 tag，一併加入關鍵字比對
            let query = """
            SELECT p.asset_id, p.metadata, p.image_embedding, COALESCE(c.keyword, '')
            FROM PhotoFeatures p
            LEFT JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            """
            for row in try db.prepare(query).run() {
                guard let assetId = row[0] as? String else { continue }
                let metadata = (row[1] as? String) ?? ""
                let tag      = (row[3] as? String) ?? ""
                var totalScore: Float = 0.0

                if !lowerText.isEmpty {
                    // tag 完整匹配給較高分，partial 也算
                    if tag.lowercased() == lowerText {
                        totalScore += 1.5
                    } else if tag.lowercased().contains(lowerText) {
                        totalScore += 1.0
                    }

                    // metadata JSON 中的日期字串比對
                    if let data = metadata.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let date = dict["date"] as? String,
                       date.lowercased().contains(lowerText) {
                        totalScore += 0.8
                    }
                }

                // 語意向量相似度
                if let queryVector = textEmbedding, let blob = row[2] as? Blob {
                    let imageVector = Data(blob.bytes).toArray(type: Float.self)
                    totalScore += cosineSimilarity(queryVector, imageVector)
                }

                if totalScore >= 0.21 {
                    scoredResults.append((id: assetId, score: totalScore))
                }
            }
        } catch { print("搜尋失敗: \(error)") }

        return scoredResults.sorted { $0.score > $1.score }.map { $0.id }
    }

    func fetchPhotoDetail(assetId: String) -> (metadata: String, tag: String)? {
        guard let db = db else { return nil }
        do {
            let query = """
            SELECT p.metadata, c.keyword
            FROM PhotoFeatures p
            JOIN ClusterSummary c ON p.cluster_id = c.cluster_id
            WHERE p.asset_id = ?
            """
            if let row = try db.prepare(query).run(assetId).first(where: { _ in true }) {
                return (row[0] as? String ?? "{}", row[1] as? String ?? "Unknown")
            }
        } catch {}
        return nil
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

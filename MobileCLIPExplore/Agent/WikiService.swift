// WikiService.swift
//
// 個人 Wiki 筆記改存在手機（PhotoAI.sqlite 的 WikiNotes 表，見 PersonalizationCore/WikiStore.swift）。
// Agent 後端只負責對話、判斷要不要存、寫出筆記內容；這裡負責：
// - 列表、搜尋、刪除筆記（不需要網路）
// - 對話前先在手機上找出相關筆記，一起送給後端（後端不再讀寫自己的資料庫）
// - 依後端回傳的決定（新建／更新／略過）把筆記寫進手機
// - 記錄筆記對應的照片（只存照片識別碼，不複製、不修改照片）
//
// 文字向量用手機內建的 NLContextualEmbedding（和智慧搜尋同一個模型），不需要下載其他模型。

import Foundation
import Photos

extension Notification.Name {
    /// 筆記新增、更新或刪除（例如在相簿頁整理成回憶筆記）：Wiki 列表要重新讀取
    static let wikiNotesUpdated = Notification.Name("WikiNotesUpdated")
}

/// 送給後端的相關筆記（對應 /turn 的 local_notes）
struct LocalWikiNote: Codable {
    let topic: String
    let summary: String
    let content: String
    let score: Double
}

enum WikiServiceError: LocalizedError {
    case notSignedIn
    var errorDescription: String? { "請先登入，個人 Wiki 存在這支手機的帳號資料裡。" }
}

final class WikiService {
    static let shared = WikiService()

    /// 搜尋門檻：校正後的語意分數＋文字比對加分。手機的文字模型和後端不同，數值是初始值，可依實際結果調整。
    static let minScore = 0.35
    /// 每次對話最多帶幾篇相關筆記給後端
    static let notesPerTurn = 5

    private let embedder = WikiEmbedder()

    private init() {}

    private func context() throws -> (store: PersonalizationStore, userId: String) {
        guard let store = DatabaseManager.shared.personalization,
              let userId = LocalUserSession.currentUserId, !userId.isEmpty else { throw WikiServiceError.notSignedIn }
        return (store, userId)
    }

    // MARK: 列表、搜尋、刪除（給 APIService 原本的介面使用）

    func list(limit: Int) async throws -> [WikiItem] {
        let (store, userId) = try context()
        return try await Self.background {
            try store.wikiNotes(userId: userId).prefix(limit).map(Self.item)
        }
    }

    func search(query: String, topK: Int) async throws -> WikiSearchResult {
        let outcome = try await searchOutcome(query: query, topK: topK, minScore: Self.minScore)
        func candidate(_ hit: WikiSearchHit) -> WikiCandidate {
            WikiCandidate(topic: hit.note.topic, summary: hit.note.summary, content: hit.note.content, score: hit.score)
        }
        return WikiSearchResult(query: outcome.query, status: outcome.status,
                                exact: outcome.exact.map(candidate), candidates: outcome.candidates.map(candidate))
    }

    func delete(topic: String) async throws {
        let (store, userId) = try context()
        _ = try await Self.background { try store.deleteWikiNote(userId: userId, topic: topic) }
        Self.postUpdated()
    }

    func note(topic: String) async throws -> WikiNote? {
        let (store, userId) = try context()
        return try await Self.background { try store.wikiNote(userId: userId, topic: topic) }
    }

    /// 這篇筆記記錄的照片識別碼（存筆記時對話用到的照片，依加入順序）
    func photoAssetIds(topic: String) async throws -> [String] {
        let (store, userId) = try context()
        return try await Self.background { try store.wikiPhotoAssetIds(userId: userId, topic: topic) }
    }

    /// 使用者自己編輯筆記（可改主題）。回傳更新後的筆記資料。
    func edit(oldTopic: String, newTopic: String, summary: String, content: String) async throws -> WikiItem? {
        let (store, userId) = try context()
        let topic = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = WikiText.compactContent(content)
        let cleanSummary = WikiText.compactSummary(summary)
        let finalSummary = cleanSummary.isEmpty ? topic : cleanSummary
        let vector = try? await embedder.embed(WikiText.embeddingText(topic: topic, summary: finalSummary, content: body))
        let model = await embedder.modelName
        try await Self.background {
            try store.editWikiNote(userId: userId, oldTopic: oldTopic, newTopic: topic, summary: finalSummary, content: body,
                                   embedding: vector, embeddingModel: vector == nil ? nil : model)
        }
        if topic != oldTopic {
            WikiImageStorage.rename(from: oldTopic, to: topic)
            WikiFavorites.rename(from: oldTopic, to: topic)
        }
        Self.postUpdated()
        return try await item(topic: topic)
    }

    /// 從筆記移除一張照片（只刪連結，照片本身不受影響）
    func unlinkPhoto(topic: String, assetId: String) async throws {
        let (store, userId) = try context()
        try await Self.background { try store.unlinkWikiPhoto(userId: userId, topic: topic, assetId: assetId) }
        Self.postUpdated()
    }

    /// 筆記列表的縮圖：照片最多的那一天中間的一張（避開截圖），和照片總數。沒有照片時回傳 nil。
    func cover(topic: String) async -> (assetId: String, count: Int)? {
        guard let ids = try? await photoAssetIds(topic: topic), !ids.isEmpty else { return nil }
        return try? await Self.background { () -> (assetId: String, count: Int)? in
            let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var assets: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
            guard !assets.isEmpty else { return nil }
            let calendar = Calendar.current
            let photos = assets.filter { !$0.mediaSubtypes.contains(.photoScreenshot) }
            let pool = photos.isEmpty ? assets : photos
            let byDay = Dictionary(grouping: pool) { asset in
                asset.creationDate.map { calendar.startOfDay(for: $0) } ?? .distantPast
            }
            let busiest = byDay.max { $0.value.count < $1.value.count }?.value ?? pool
            let sorted = busiest.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            return (sorted[sorted.count / 2].localIdentifier, assets.count)
        } ?? nil
    }

    /// 包含這張照片的筆記主題（照片頁顯示「出現在哪些筆記」）
    func topics(containing assetId: String) async throws -> [String] {
        let (store, userId) = try context()
        return try await Self.background { try store.wikiTopics(containing: assetId, userId: userId) }
    }

    /// 打開筆記頁用的資料
    func item(topic: String) async throws -> WikiItem? {
        try await note(topic: topic).map(Self.item)
    }

    /// 首頁搜尋：符合的筆記（最符合的在前）
    func matchingNotes(query: String, limit: Int) async -> [WikiItem] {
        guard let outcome = try? await searchOutcome(query: query, topK: limit, minScore: Self.minScore) else { return [] }
        var hits = outcome.candidates
        if let exact = outcome.exact, !hits.contains(where: { $0.note.topic == exact.note.topic }) { hits.insert(exact, at: 0) }
        return hits.prefix(limit).map { Self.item($0.note) }
    }

    // MARK: 對話

    /// 這輪對話相關的筆記（送給後端判斷要新建還是合併）。使用者選了「延續筆記」時，那篇一定會帶上。
    func relatedNotes(for message: String, targetTopic: String?) async -> [LocalWikiNote] {
        var notes: [LocalWikiNote] = []
        if let outcome = try? await searchOutcome(query: message, topK: Self.notesPerTurn, minScore: Self.minScore) {
            var hits = outcome.candidates
            if let exact = outcome.exact, !hits.contains(where: { $0.note.topic == exact.note.topic }) { hits.insert(exact, at: 0) }
            notes = hits.prefix(Self.notesPerTurn).map {
                LocalWikiNote(topic: $0.note.topic, summary: $0.note.summary, content: $0.note.content, score: $0.score)
            }
        }
        if let targetTopic, !targetTopic.isEmpty, !notes.contains(where: { $0.topic == targetTopic }),
           let target = try? await note(topic: targetTopic) {
            notes.insert(LocalWikiNote(topic: target.topic, summary: target.summary, content: target.content, score: 1), at: 0)
        }
        return notes
    }

    /// 套用後端的決定。回傳實際的動作（created／updated）與主題；略過或無效時回傳 nil。
    func apply(decision: String?, topic: String?, summary: String?, content: String?,
               assetIds: [String]) async throws -> (action: String, topic: String)? {
        guard let decision, decision == "store" || decision == "update",
              let rawTopic = topic?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTopic.isEmpty else { return nil }
        // 筆記一律存成繁體中文（Agent 或手機上的模型有時會照抄截圖裡的簡體字）
        let proposed = TraditionalChinese.convert(rawTopic)
        let summary = summary.map(TraditionalChinese.convert)
        let body = WikiText.compactContent(TraditionalChinese.convert(content ?? ""))
        guard !WikiText.needsRewrite(body) else { return nil }
        let (store, userId) = try context()
        let isUpdate = decision == "update"
        let finalTopic = try await Self.background {
            try store.uniqueWikiTopic(userId: userId, proposed: proposed, preserveExisting: isUpdate)
        }
        let cleanSummary = WikiText.compactSummary(summary ?? "")
        let finalSummary = cleanSummary.isEmpty ? finalTopic : cleanSummary
        let vector = try? await embedder.embed(WikiText.embeddingText(topic: finalTopic, summary: finalSummary, content: body))
        let model = await embedder.modelName
        try await Self.background {
            try store.saveWikiNote(userId: userId, topic: finalTopic, summary: finalSummary, content: body,
                                   embedding: vector, embeddingModel: vector == nil ? nil : model)
            try store.linkWikiPhotos(userId: userId, topic: finalTopic, assetIds: assetIds)
        }
        Self.postUpdated()
        return (isUpdate ? "updated" : "created", finalTopic)
    }

    // MARK: 內部

    private func searchOutcome(query: String, topK: Int, minScore: Double) async throws -> WikiSearchOutcome {
        let (store, userId) = try context()
        try await refreshEmbeddingsIfNeeded(store: store, userId: userId)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let vector = (try? await embedder.embed(trimmed)) ?? []
        let model = await embedder.modelName
        let floor = await embedder.similarityFloor
        return try await Self.background {
            try store.searchWikiNotes(userId: userId, query: trimmed, queryVector: vector, model: model,
                                      topK: topK, minScore: minScore,
                                      calibrate: { Double(min(max(($0 - floor) / (1 - floor), 0), 1)) })
        }
    }

    /// 還沒有向量、或向量是舊模型算的筆記，補算一次
    private func refreshEmbeddingsIfNeeded(store: PersonalizationStore, userId: String) async throws {
        let model = await embedder.modelName
        guard !model.isEmpty else { return }
        let pending = try await Self.background { try store.wikiNotesNeedingEmbedding(userId: userId, model: model) }
        for note in pending {
            guard let vector = try? await embedder.embed(WikiText.embeddingText(topic: note.topic, summary: note.summary, content: note.content)) else { continue }
            try await Self.background { try store.updateWikiEmbedding(userId: userId, topic: note.topic, embedding: vector, model: model) }
        }
    }

    private static func postUpdated() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .wikiNotesUpdated, object: nil) }
    }

    private static func item(_ note: WikiNote) -> WikiItem {
        WikiItem(topic: note.topic, summary: note.summary, preview: String(note.content.prefix(200)), updated_at: note.updatedAt)
    }

    private static func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// 文字向量（手機內建 NLContextualEmbedding，第一次使用時下載／載入模型資產）
private actor WikiEmbedder {
    private var embedder: ASContextualEmbedder?
    private var prepared = false

    var modelName: String { embedder?.modelName ?? (try? load())?.modelName ?? "" }

    /// 「完全不相關」兩段文字的典型相似度：沿用智慧搜尋用照片描述校正出來的值，沒有時用 0.5
    var similarityFloor: Float {
        guard let name = embedder?.modelName,
              let saved = UserDefaults.standard.object(forKey: "ASAbstractSearch.simFloor.\(name)") as? Float else { return 0.5 }
        return min(saved, 0.95)
    }

    private func load() throws -> ASContextualEmbedder {
        if let embedder { return embedder }
        let created = try ASContextualEmbedder()
        embedder = created
        return created
    }

    func embed(_ text: String) async throws -> [Float] {
        let model = try load()
        if !prepared {
            try await model.prepare()
            prepared = true
        }
        return try model.embed([text]).first ?? []
    }
}

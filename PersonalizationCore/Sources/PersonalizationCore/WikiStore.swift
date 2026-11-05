// WikiStore.swift
//
// 個人 Wiki 筆記存在手機的資料庫（PhotoAI.sqlite 的 WikiNotes／WikiNotePhotos 表，migration v6）。
// 以前筆記存在 Agent 後端（電腦）上，每支手機一份副本；現在後端只負責「對話、判斷要不要存、寫筆記內容」，
// 筆記的儲存、列表、搜尋、刪除都在手機上完成，沒有網路也能瀏覽與搜尋。
//
// 搜尋規則移植自組員後端 skills.py 的 search_wiki_pages（第二版），並修正一個問題：
// 「查詢和筆記沒有共同字詞就扣分」原本會套用兩次（分數 × 0.6 × 0.6），這裡只套用一次。
// 語意分數改用手機上的文字向量（由 App 傳入），先校正到 0～1 再加上文字比對的加分。
//
// 本檔案只依賴 Foundation 與 SQLite.swift，可在 macOS 用 swift test 驗證。

import Foundation
import SQLite

struct WikiNote: Equatable, Identifiable {
    var id: String { topic }
    let topic: String
    let summary: String
    let content: String
    /// SQLite CURRENT_TIMESTAMP（UTC，"yyyy-MM-dd HH:mm:ss"）
    let createdAt: String?
    let updatedAt: String?
}

struct WikiSearchHit: Equatable {
    let note: WikiNote
    let score: Double
}

struct WikiSearchOutcome: Equatable {
    let query: String
    /// empty（沒有任何筆記）／exact（主題完全相同）／related（有夠像的筆記）／none
    let status: String
    let exact: WikiSearchHit?
    let candidates: [WikiSearchHit]
}

// MARK: - 文字處理與計分（與後端規則相同）

enum WikiText {
    /// 筆記主題最多幾個字（後端 limit_wiki_topic）
    static let maxTopicLength = 10
    static let maxSummaryLength = 80
    static let maxContentLength = 5000
    static let placeholders = ["TODO", "TBD", "PLACEHOLDER", "None", "null"]

    /// 中文連續字切成兩字一組（單一個字就保留單字），英數字串整段保留。對應 skills._tokenize。
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var cjk: [Character] = []
        var ascii = ""

        func flushCJK() {
            if cjk.count == 1 {
                tokens.append(String(cjk[0]))
            } else if cjk.count > 1 {
                for index in 0..<(cjk.count - 1) { tokens.append(String(cjk[index...index + 1])) }
            }
            cjk.removeAll()
        }
        func flushASCII() {
            if !ascii.isEmpty { tokens.append(ascii) }
            ascii = ""
        }

        for character in text.lowercased() {
            if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
               (0x4E00...0x9FFF).contains(scalar.value) {
                flushASCII()
                cjk.append(character)
            } else if character.isASCII && (character.isLetter || character.isNumber) {
                flushCJK()
                ascii.append(character)
            } else {
                flushCJK()
                flushASCII()
            }
        }
        flushCJK()
        flushASCII()
        return tokens
    }

    /// 去掉空白並轉小寫（skills._normalize_text）
    static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace })
    }

    /// 算向量用的文字：主題＋摘要＋內容前 1,800 字（skills._candidate_text）
    static func embeddingText(topic: String, summary: String, content: String) -> String {
        "\(topic)\n\(summary)\n\(String(content.prefix(1800)))"
    }

    /// 摘要：一句話、最多 80 字（my_agent._compact_wiki_summary）
    static func compactSummary(_ summary: String) -> String {
        let collapsed = summary.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(maxSummaryLength))
    }

    /// 內容：重複的行只留一行，最多 5,000 字（my_agent._compact_wiki_content）
    static func compactContent(_ content: String) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for line in content.components(separatedBy: "\n") {
            let key = normalize(line)
            if !key.isEmpty {
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            var trimmed = line
            while trimmed.last?.isWhitespace == true { trimmed.removeLast() }
            kept.append(trimmed)
        }
        var compacted = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if compacted.count > maxContentLength {
            var head = String(compacted.prefix(maxContentLength - 20))
            while head.last?.isWhitespace == true { head.removeLast() }
            compacted = head + "\n...[內容已精簡]"
        }
        return compacted
    }

    /// 內容是空的或有 TODO 之類的佔位字（my_agent.wiki_content_needs_rewrite）
    static func needsRewrite(_ content: String) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || placeholders.contains { content.contains($0) }
    }

    /// 一筆筆記的分數。semantic 是已校正到 0～1 的語意相似度。
    static func score(query: String, note: WikiNote, semantic: Double) -> Double {
        var score = semantic
        let normQuery = normalize(query)
        let normTopic = normalize(note.topic)
        if !normQuery.isEmpty && normQuery == normTopic {
            score += 0.35
        } else if !normTopic.isEmpty && (normQuery.contains(normTopic) || (!normQuery.isEmpty && normTopic.contains(normQuery))) {
            score += 0.18
        }

        let queryTokens = Set(tokenize(query))
        let evidence = Set(tokenize(note.topic)).union(tokenize(note.summary)).union(tokenize(String(note.content.prefix(1800))))
        let overlap = queryTokens.intersection(evidence).count
        if overlap > 0 { score += min(0.08, 0.02 * Double(overlap)) }

        // 沒有任何共同字詞的語意相似（例如「東京自由行路線」對到「航班搜尋路線」）降權；只套用一次
        if overlap == 0 {
            score *= 0.60
        } else if overlap == 1 && queryTokens.count >= 3 && score < 0.70 {
            score *= 0.65
        }

        // 關鍵字直接出現在筆記裡：不論語意分數高低都算找到
        // （搜尋「生乳捲」要找到「亞尼克原味生乳捲」；短查詢的語意向量往往不夠準）
        if !normQuery.isEmpty {
            if normTopic.contains(normQuery) {
                score = max(score, 0.80)
            } else if normQuery.count >= 2 && normalize(note.summary).contains(normQuery) {
                score = max(score, 0.60)
            } else if normQuery.count >= 2 && normalize(note.content).contains(normQuery) {
                score = max(score, 0.50)
            }
        }
        return min(score, 1.0)
    }
}

// MARK: - 資料庫

extension PersonalizationStore {

    private func wikiNote(from row: [Binding?]) -> WikiNote? {
        guard let topic = row[0] as? String else { return nil }
        return WikiNote(topic: topic,
                        summary: row[1] as? String ?? "",
                        content: row[2] as? String ?? "",
                        createdAt: row[3] as? String,
                        updatedAt: row[4] as? String)
    }

    /// 全部筆記，最近更新的在前
    func wikiNotes(userId: String) throws -> [WikiNote] {
        guard !userId.isEmpty else { return [] }
        return try query("""
        SELECT topic, summary, content, created_at, updated_at FROM WikiNotes
        WHERE user_id = ? ORDER BY updated_at DESC, topic
        """, userId).compactMap(wikiNote(from:))
    }

    func wikiNote(userId: String, topic: String) throws -> WikiNote? {
        try query("""
        SELECT topic, summary, content, created_at, updated_at FROM WikiNotes WHERE user_id = ? AND topic = ?
        """, userId, topic).first.flatMap(wikiNote(from:))
    }

    /// 新增或更新筆記（更新時保留建立時間）。向量由 App 用手機上的文字模型算好傳入。
    func saveWikiNote(userId: String, topic: String, summary: String, content: String,
                      embedding: [Float]?, embeddingModel: String?) throws {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        let blob = embedding.map { Blob(bytes: EmbeddingCodec.encode($0)) }
        try write {
            try exec("""
            INSERT INTO WikiNotes (user_id, topic, summary, content, embedding, embedding_model)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id, topic) DO UPDATE SET
                summary = excluded.summary,
                content = excluded.content,
                embedding = excluded.embedding,
                embedding_model = excluded.embedding_model,
                updated_at = CURRENT_TIMESTAMP
            """, userId, topic, summary, content, blob, embeddingModel)
        }
    }

    /// 刪除筆記與它的照片連結（只刪 App 自己的資料，照片本身不受影響）
    @discardableResult
    func deleteWikiNote(userId: String, topic: String) throws -> Bool {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        return try write {
            try exec("DELETE FROM WikiNotePhotos WHERE user_id = ? AND topic = ?", userId, topic)
            try exec("DELETE FROM WikiNotes WHERE user_id = ? AND topic = ?", userId, topic)
            return db.changes > 0
        }
    }

    /// 向量不是用這個模型算的筆記（第一次使用或換了模型）
    func wikiNotesNeedingEmbedding(userId: String, model: String) throws -> [WikiNote] {
        try query("""
        SELECT topic, summary, content, created_at, updated_at FROM WikiNotes
        WHERE user_id = ? AND (embedding IS NULL OR embedding_model IS NOT ?)
        """, userId, model).compactMap(wikiNote(from:))
    }

    func updateWikiEmbedding(userId: String, topic: String, embedding: [Float], model: String) throws {
        try write {
            try exec("UPDATE WikiNotes SET embedding = ?, embedding_model = ? WHERE user_id = ? AND topic = ?",
                     Blob(bytes: EmbeddingCodec.encode(embedding)), model, userId, topic)
        }
    }

    /// 搜尋筆記。queryVector 與筆記向量都由同一個模型算出；calibrate 把餘弦相似度校正到 0～1。
    func searchWikiNotes(userId: String, query text: String, queryVector: [Float], model: String,
                         topK: Int = 5, minScore: Double,
                         calibrate: (Float) -> Double) throws -> WikiSearchOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = try query("""
        SELECT topic, summary, content, created_at, updated_at, embedding, embedding_model FROM WikiNotes WHERE user_id = ?
        """, userId)
        guard !rows.isEmpty else { return WikiSearchOutcome(query: trimmed, status: "empty", exact: nil, candidates: []) }

        let normQuery = WikiText.normalize(trimmed)
        var exact: WikiSearchHit?
        var scored: [WikiSearchHit] = []
        for row in rows {
            guard let note = wikiNote(from: row) else { continue }
            var semantic = 0.0
            if let blob = row[5] as? Blob, (row[6] as? String) == model {
                let vector = EmbeddingCodec.decode(blob.bytes)
                if vector.count == queryVector.count {
                    semantic = calibrate(MultiLabelTagger.dot(queryVector, vector))
                }
            }
            let hit = WikiSearchHit(note: note, score: (WikiText.score(query: trimmed, note: note, semantic: semantic) * 10_000).rounded() / 10_000)
            scored.append(hit)
            if !normQuery.isEmpty && normQuery == WikiText.normalize(note.topic) { exact = hit }
        }
        scored.sort { ($0.score, $1.note.topic) > ($1.score, $0.note.topic) }
        let candidates = Array(scored.prefix(max(topK, 0)).filter { $0.score >= minScore })
        let status = exact != nil ? "exact" : (candidates.isEmpty ? "none" : "related")
        return WikiSearchOutcome(query: trimmed, status: status, exact: exact, candidates: candidates)
    }

    /// 主題最多 10 個字，且不覆蓋另一篇筆記（重複時加上「(2)」）。對應 my_agent.limit_wiki_topic。
    func uniqueWikiTopic(userId: String, proposed: String, preserveExisting: Bool) throws -> String {
        let normalized = proposed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var candidate = String(normalized.prefix(WikiText.maxTopicLength))
        if candidate.isEmpty { candidate = "untitled" }
        let existing = Set(try query("SELECT topic FROM WikiNotes WHERE user_id = ?", userId).compactMap { $0[0] as? String })
        if preserveExisting && candidate == normalized && existing.contains(candidate) { return candidate }

        let base = candidate
        var suffixNumber = 2
        while existing.contains(candidate) {
            let suffix = "(\(suffixNumber))"
            candidate = String(base.prefix(WikiText.maxTopicLength - suffix.count)) + suffix
            suffixNumber += 1
        }
        return candidate
    }

    // MARK: 筆記 ↔ 照片

    /// 記錄筆記對應的照片（只存識別碼）。已存在的連結不重複。
    func linkWikiPhotos(userId: String, topic: String, assetIds: [String]) throws {
        guard !assetIds.isEmpty else { return }
        try write {
            let start = try scalarInt("SELECT COUNT(*) FROM WikiNotePhotos WHERE user_id = ? AND topic = ?", userId, topic)
            for (offset, assetId) in assetIds.enumerated() {
                try exec("""
                INSERT OR IGNORE INTO WikiNotePhotos (user_id, topic, asset_id, position) VALUES (?, ?, ?, ?)
                """, userId, topic, assetId, Int64(start + offset))
            }
        }
    }

    func wikiPhotoAssetIds(userId: String, topic: String) throws -> [String] {
        try query("SELECT asset_id FROM WikiNotePhotos WHERE user_id = ? AND topic = ? ORDER BY position",
                  userId, topic).compactMap { $0[0] as? String }
    }

    /// 使用者自己編輯筆記：可以改主題（換名字）、摘要與內容。改名時照片連結一起搬過去；新名字已被別篇使用時丟出錯誤。
    func editWikiNote(userId: String, oldTopic: String, newTopic: String, summary: String, content: String,
                      embedding: [Float]?, embeddingModel: String?) throws {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        let topic = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, topic.count <= WikiText.maxTopicLength else { throw PersonalizationError.invalidCategoryName }
        let blob = embedding.map { Blob(bytes: EmbeddingCodec.encode($0)) }
        try write {
            if topic != oldTopic,
               try scalarInt("SELECT COUNT(*) FROM WikiNotes WHERE user_id = ? AND topic = ?", userId, topic) > 0 {
                throw PersonalizationError.duplicateCategoryName(topic)
            }
            try exec("""
            UPDATE WikiNotes SET topic = ?, summary = ?, content = ?, embedding = ?, embedding_model = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE user_id = ? AND topic = ?
            """, topic, summary, content, blob, embeddingModel, userId, oldTopic)
            guard db.changes > 0 else { throw PersonalizationError.analysisFailed("找不到這篇筆記") }
            if topic != oldTopic {
                try exec("UPDATE WikiNotePhotos SET topic = ? WHERE user_id = ? AND topic = ?", topic, userId, oldTopic)
            }
        }
    }

    /// 從筆記移除一張照片的連結（只刪連結，照片本身不受影響）
    func unlinkWikiPhoto(userId: String, topic: String, assetId: String) throws {
        try write {
            try exec("DELETE FROM WikiNotePhotos WHERE user_id = ? AND topic = ? AND asset_id = ?", userId, topic, assetId)
        }
    }

    /// 提到這張照片的筆記（照片詳細頁可以列出相關筆記）
    func wikiTopics(containing assetId: String, userId: String) throws -> [String] {
        try query("SELECT topic FROM WikiNotePhotos WHERE user_id = ? AND asset_id = ? ORDER BY created_at DESC",
                  userId, assetId).compactMap { $0[0] as? String }
    }
}

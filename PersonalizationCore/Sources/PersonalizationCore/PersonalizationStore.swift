// PersonalizationStore.swift
//
// 個人化分類系統的資料存取層（只依賴 Foundation + SQLite.swift，可在 macOS 執行 swift test）。
//
// 照片安全原則（本檔案的硬性限制）：
// - 本檔案「只」操作 App 自己的 SQLite 資料，不會也不能存取系統相簿或任何照片檔案。
// - 「移除 AI 分析資料」只清除向量、場景圖、自動標籤與自動分類；
//   保留照片識別資訊（asset_id）、最愛、metadata、主題相簿成員、手動標籤與其他照片的資料。
// - 所有寫入都在單一 transaction 中完成：任一步驟失敗就整批回滾，資料維持原狀，可直接重試。

import Foundation
import SQLite

// MARK: - 錯誤

enum PersonalizationError: Error, LocalizedError, Equatable {
    case notSignedIn
    case notAuthorized
    case invalidAssetId
    case unknownNode(String)
    case unknownInterest(String)
    case notTopLevel(String)
    case photoNotAccessible
    case analysisFailed(String)
    case invalidCategoryName
    case duplicateCategoryName(String)
    case needsExamples

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "尚未登入，無法變更 AI 分析資料。"
        case .notAuthorized: return "這筆 AI 分析資料屬於其他帳號，無法變更。"
        case .invalidAssetId: return "照片識別碼無效。"
        case .unknownNode(let id): return "找不到分類：\(id)"
        case .unknownInterest(let id): return "找不到興趣定位：\(id)"
        case .notTopLevel(let id): return "不是大分類：\(id)"
        case .photoNotAccessible: return "無法讀取這張照片（可能已不在相簿中，或未授權存取）。"
        case .analysisFailed(let reason): return "分析失敗：\(reason)"
        case .invalidCategoryName: return "請輸入名稱（最多 40 個字）。"
        case .duplicateCategoryName(let name): return "已經有「\(name)」了。"
        case .needsExamples: return "請至少選 1 張已掃描過的範例照片。"
        }
    }
}

// MARK: - 資料模型

enum OnboardingStatus: String {
    case pending
    case completed
    case skipped
}

struct PhotoTagRecord: Identifiable, Hashable {
    var id: String { nodeId }
    let nodeId: String
    let score: Double?
    let source: TagSource
    let status: TagStatus
}

struct CandidateTag: Identifiable, Hashable {
    var id: String { assetId + "|" + nodeId }
    let assetId: String
    let nodeId: String
    let score: Double?
}

struct AIAnalysisRemovalReport: Equatable {
    let assetId: String
    let vectorRemoved: Bool
    let clusterCleared: Bool
    let autoTagsRemoved: Int
    let manualTagsKept: Int
    let albumMembershipsKept: Int
}

struct ThemeAlbumMembership: Identifiable, Hashable {
    let id: String      // album_id
    let title: String
}

// MARK: - Store

final class PersonalizationStore {

    static let defaultLocalUserId = "local-default-user"

    let db: Connection
    let catalog: TaxonomyCatalog
    private let writeQueue: DispatchQueue

    /// - Parameter writeQueue: 傳入 App 既有的資料庫寫入佇列，確保與 DatabaseManager 的寫入序列化。
    ///   注意：不可在該佇列上（例如 DatabaseManager 的 writeQueue.sync 內）呼叫本類別的寫入方法，否則會死結。
    init(db: Connection,
         catalog: TaxonomyCatalog = .builtIn,
         writeQueue: DispatchQueue = DispatchQueue(label: "com.photoai.personalization.write")) {
        self.db = db
        self.catalog = catalog
        self.writeQueue = writeQueue
    }

    // MARK: 基礎工具（internal：同一個模組裡其他檔案的 extension 也會用，例如 WikiStore.swift）

    func write<T>(_ body: () throws -> T) throws -> T {
        try writeQueue.sync { () throws -> T in
            var result: T?
            try db.transaction {
                result = try body()
            }
            guard let value = result else {
                throw PersonalizationError.analysisFailed("transaction produced no result")
            }
            return value
        }
    }

    func exec(_ sql: String, _ args: Binding?...) throws {
        try db.run(sql, args)
    }

    func query(_ sql: String, _ args: Binding?...) throws -> [[Binding?]] {
        var rows: [[Binding?]] = []
        for row in try db.prepare(sql).run(args) {
            rows.append(row)
        }
        return rows
    }

    func scalarInt(_ sql: String, _ args: Binding?...) throws -> Int {
        Int(try db.scalar(sql, args) as? Int64 ?? 0)
    }

    func tableExists(_ table: String) throws -> Bool {
        try PersonalizationSchema.tableExists(db, table)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func timestamp(_ date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }

    // MARK: Migration + 目錄

    func migrate() throws {
        try writeQueue.sync {
            _ = try PersonalizationSchema.migrate(db)
        }
    }

    /// 將內建分類目錄同步到資料庫。目錄版本相同時不做任何事。回傳是否有更新。
    @discardableResult
    func seedCatalogIfNeeded() throws -> Bool {
        let stored = try db.scalar(
            "SELECT meta_value FROM PersonalizationMeta WHERE meta_key = 'catalog_version'"
        ) as? String
        let nodeCount = try scalarInt("SELECT COUNT(*) FROM TaxonomyNodes WHERE is_builtin = 1 AND is_active = 1")
        if stored == catalog.catalogStamp && nodeCount == catalog.nodes.count {
            return false
        }

        let version = Int64(catalog.catalogVersion)
        return try write {
            for node in catalog.nodes {
                try exec("""
                INSERT INTO TaxonomyNodes
                    (node_id, parent_id, level, name_zh, name_en, summary_zh, summary_en, examples_zh,
                     icon, recognition, sort_order, is_builtin, is_active, catalog_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 1, ?)
                ON CONFLICT(node_id) DO UPDATE SET
                    parent_id = excluded.parent_id,
                    level = excluded.level,
                    name_zh = excluded.name_zh,
                    name_en = excluded.name_en,
                    summary_zh = excluded.summary_zh,
                    summary_en = excluded.summary_en,
                    examples_zh = excluded.examples_zh,
                    icon = excluded.icon,
                    recognition = excluded.recognition,
                    sort_order = excluded.sort_order,
                    is_active = 1,
                    catalog_version = excluded.catalog_version
                WHERE TaxonomyNodes.is_builtin = 1
                """,
                node.id, node.parentId, Int64(node.level), node.nameZh, node.nameEn,
                node.summaryZh, node.summaryEn, node.examplesZh, node.icon,
                node.recognition.rawValue, Int64(node.sortOrder), version)

                for prompt in node.prompts {
                    try exec("INSERT OR IGNORE INTO TaxonomyPrompts (node_id, prompt, embedding) VALUES (?, ?, NULL)",
                             node.id, prompt)
                }
                // 容易混淆的畫面：一樣算文字向量，存在「節點ID#not」底下，只用來排除誤判
                for prompt in node.confusers {
                    try exec("INSERT OR IGNORE INTO TaxonomyPrompts (node_id, prompt, embedding) VALUES (?, ?, NULL)",
                             TaxonomyNode.confuserKey(node.id), prompt)
                }
            }

            // 新的大分類：選過來源大分類的使用者自動選取（含預設子分類），已有設定的不覆蓋。
            // 要在搬移偏好之前做：來源大分類若在本版被合併，搬移後就查不到誰選過它。
            for (newTop, sources) in catalog.topLevelAdditions.sorted(by: { $0.key < $1.key }) where !sources.isEmpty {
                let placeholders = Array(repeating: "?", count: sources.count).joined(separator: ", ")
                let sourceBindings: [Binding?] = sources.map { $0 }
                var users: [String] = []
                for row in try db.prepare("""
                SELECT DISTINCT user_id FROM UserCategoryPreferences
                WHERE is_enabled = 1 AND node_id IN (\(placeholders))
                """).run(sourceBindings) {
                    if let userId = row[0] as? String { users.append(userId) }
                }
                for userId in users {
                    try exec("""
                    INSERT OR IGNORE INTO UserCategoryPreferences (user_id, node_id, is_enabled, source, updated_at)
                    VALUES (?, ?, 1, 'selection', CURRENT_TIMESTAMP)
                    """, userId, newTop)
                    for child in InterestRecommender.defaultEnabledDescendants(ofTopLevel: newTop, catalog: catalog) {
                        try exec("""
                        INSERT OR IGNORE INTO UserCategoryPreferences (user_id, node_id, is_enabled, source, updated_at)
                        VALUES (?, ?, 1, 'auto_from_parent', CURRENT_TIMESTAMP)
                        """, userId, child.id)
                    }
                }
            }

            // 被合併的節點：把標籤與偏好搬到取代它的節點（同一張照片兩邊都有時，手動標籤優先）。
            for (old, new) in catalog.nodeRedirects.sorted(by: { $0.key < $1.key }) {
                try exec("""
                DELETE FROM PhotoTags
                WHERE node_id = ? AND source = 'auto'
                  AND EXISTS (SELECT 1 FROM PhotoTags o
                              WHERE o.user_id = PhotoTags.user_id AND o.asset_id = PhotoTags.asset_id
                                AND o.node_id = ? AND o.source = 'manual')
                """, new, old)
                try exec("UPDATE OR IGNORE PhotoTags SET node_id = ? WHERE node_id = ?", new, old)
                try exec("DELETE FROM PhotoTags WHERE node_id = ?", old)
                try exec("UPDATE OR IGNORE UserCategoryPreferences SET node_id = ? WHERE node_id = ?", new, old)
                try exec("DELETE FROM UserCategoryPreferences WHERE node_id = ?", old)
            }

            // 被合併的興趣定位：選過舊興趣的使用者改成取代它的興趣。
            for (old, new) in catalog.interestRedirects.sorted(by: { $0.key < $1.key }) {
                try exec("UPDATE OR IGNORE UserInterests SET interest_id = ? WHERE interest_id = ?", new, old)
                try exec("DELETE FROM UserInterests WHERE interest_id = ?", old)
            }

            // 目錄中已不存在的內建節點只停用，不刪除（避免手動標籤失去對應）。
            try exec("UPDATE TaxonomyNodes SET is_active = 0 WHERE is_builtin = 1 AND catalog_version <> ?", version)

            // 移除目錄中已不再使用的 prompt（只影響文字向量，不影響照片向量）。
            let currentPrompts = Set(catalog.nodes.flatMap { node in
                node.prompts.map { node.id + "\u{1F}" + $0 }
                    + node.confusers.map { TaxonomyNode.confuserKey(node.id) + "\u{1F}" + $0 }
            })
            for row in try query("SELECT node_id, prompt FROM TaxonomyPrompts") {
                guard let nodeId = row[0] as? String, let prompt = row[1] as? String else { continue }
                if !currentPrompts.contains(nodeId + "\u{1F}" + prompt) {
                    try exec("DELETE FROM TaxonomyPrompts WHERE node_id = ? AND prompt = ?", nodeId, prompt)
                }
            }

            try exec("""
            INSERT INTO PersonalizationMeta (meta_key, meta_value) VALUES ('catalog_version', ?)
            ON CONFLICT(meta_key) DO UPDATE SET meta_value = excluded.meta_value
            """, catalog.catalogStamp)
            return true
        }
    }

    /// 需要計算文字向量的 prompt。
    func promptsNeedingEmbedding() throws -> [(nodeId: String, prompt: String)] {
        try query("SELECT node_id, prompt FROM TaxonomyPrompts WHERE embedding IS NULL ORDER BY node_id")
            .compactMap { row in
                guard let nodeId = row[0] as? String, let prompt = row[1] as? String else { return nil }
                return (nodeId: nodeId, prompt: prompt)
            }
    }

    /// 沿用既有 SemanticDictionary 的文字向量（同一模型、同一 "a photo of" 模板），避免重複計算。
    @discardableResult
    func reuseExistingDictionaryEmbeddings() throws -> Int {
        guard try tableExists("SemanticDictionary") else { return 0 }
        return try write {
            try exec("""
            UPDATE TaxonomyPrompts
            SET embedding = (
                SELECT s.word_embedding FROM SemanticDictionary s
                WHERE lower(s.keyword) = lower(TaxonomyPrompts.prompt) AND s.word_embedding IS NOT NULL
                LIMIT 1
            )
            WHERE embedding IS NULL AND EXISTS (
                SELECT 1 FROM SemanticDictionary s
                WHERE lower(s.keyword) = lower(TaxonomyPrompts.prompt) AND s.word_embedding IS NOT NULL
            )
            """)
            return db.changes
        }
    }

    /// 從 App 內附的 PhotoAI.sqlite（唯讀開啟）匯入預先算好的分類文字向量，手機上就不必用文字模型現算。
    /// 向量是在電腦上用同一個 mobileclip_s2_text 模型、同樣的「a photo of」模板算出的。
    /// - Returns: 匯入的 prompt 數。來源檔或資料表不存在時回傳 0（之後照舊在手機上補算）。
    @discardableResult
    func importPrecomputedPromptEmbeddings(fromDatabaseAt path: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let source = try Connection(path, readonly: true)
        let hasTable = (try source.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'PrecomputedPromptEmbeddings'"
        ) as? Int64 ?? 0) > 0
        guard hasTable else { return 0 }

        var vectors: [String: Blob] = [:]
        for row in try source.prepare(
            "SELECT prompt, embedding FROM PrecomputedPromptEmbeddings WHERE template = 'a photo of'"
        ).run() {
            guard let prompt = row[0] as? String, let blob = row[1] as? Blob,
                  blob.bytes.count == 512 * MemoryLayout<Float>.size else { continue }
            vectors[prompt] = blob
        }
        let missing = try promptsNeedingEmbedding()
        guard !vectors.isEmpty, !missing.isEmpty else { return 0 }
        return try write {
            var imported = 0
            for item in missing {
                let key = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let blob = vectors[key] else { continue }
                try exec("UPDATE TaxonomyPrompts SET embedding = ? WHERE node_id = ? AND prompt = ? AND embedding IS NULL",
                         blob, item.nodeId, item.prompt)
                imported += db.changes
            }
            return imported
        }
    }

    func savePromptEmbedding(nodeId: String, prompt: String, embedding: [Float]) throws {
        guard !embedding.isEmpty else { return }
        let blob = Blob(bytes: EmbeddingCodec.encode(embedding))
        try write {
            try exec("UPDATE TaxonomyPrompts SET embedding = ? WHERE node_id = ? AND prompt = ?", blob, nodeId, prompt)
        }
    }

    /// 回傳 nodeId → 文字向量；容易混淆的畫面以「節點ID#not」為 key 一起回傳（只屬於啟用中的節點）。
    func loadPromptEmbeddings() throws -> [String: [[Float]]] {
        var result: [String: [[Float]]] = [:]
        let active = Set(try query("SELECT node_id FROM TaxonomyNodes WHERE is_active = 1").compactMap { $0[0] as? String })
        let rows = try query("SELECT node_id, embedding FROM TaxonomyPrompts WHERE embedding IS NOT NULL")
        for row in rows {
            guard let nodeId = row[0] as? String, let blob = row[1] as? Blob else { continue }
            let owner = nodeId.hasSuffix(TaxonomyNode.confuserSuffix)
                ? String(nodeId.dropLast(TaxonomyNode.confuserSuffix.count)) : nodeId
            guard active.contains(owner) else { continue }
            let vector = EmbeddingCodec.decode(blob.bytes)
            if !vector.isEmpty { result[nodeId, default: []].append(vector) }
        }
        return result
    }

    // MARK: 使用者（本機帳號）

    /// 依 email 取得或建立本機帳號 ID。沒有 email 時使用單一的本機預設帳號。
    func resolveUser(email: String?, displayName: String?) throws -> String {
        let normalizedEmail = (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedName = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = trimmedName.isEmpty ? nil : trimmedName

        return try write {
            if normalizedEmail.isEmpty {
                try exec("INSERT OR IGNORE INTO UserProfiles (user_id, email, display_name) VALUES (?, NULL, ?)",
                         Self.defaultLocalUserId, name)
                return Self.defaultLocalUserId
            }
            if let existing = try db.scalar("SELECT user_id FROM UserProfiles WHERE email = ?", normalizedEmail) as? String {
                if let name {
                    try exec("UPDATE UserProfiles SET display_name = ?, updated_at = CURRENT_TIMESTAMP WHERE user_id = ?", name, existing)
                }
                return existing
            }
            let userId = "local-" + UUID().uuidString.lowercased()
            try exec("INSERT INTO UserProfiles (user_id, email, display_name) VALUES (?, ?, ?)", userId, normalizedEmail, name)
            return userId
        }
    }

    /// 既有（升級前）資料沒有擁有者，由目前登入的帳號認領。不會改動已有擁有者的資料。
    func claimLegacyData(for userId: String) throws {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        try write {
            if try tableExists("PhotoFeatures") {
                try exec("UPDATE PhotoFeatures SET owner_user_id = ? WHERE owner_user_id IS NULL", userId)
            }
            if try tableExists("UserAlbums") {
                try exec("UPDATE UserAlbums SET owner_user_id = ? WHERE owner_user_id IS NULL", userId)
            }
        }
    }

    func onboardingStatus(userId: String) throws -> OnboardingStatus {
        let raw = try db.scalar("SELECT onboarding_status FROM UserProfiles WHERE user_id = ?", userId) as? String
        return raw.flatMap(OnboardingStatus.init(rawValue:)) ?? .pending
    }

    func setOnboardingStatus(userId: String, _ status: OnboardingStatus) throws {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        try write {
            try exec("""
            INSERT INTO UserProfiles (user_id, onboarding_status) VALUES (?, ?)
            ON CONFLICT(user_id) DO UPDATE SET onboarding_status = excluded.onboarding_status, updated_at = CURRENT_TIMESTAMP
            """, userId, status.rawValue)
        }
    }

    // MARK: 興趣定位

    func interestIds(userId: String) throws -> Set<String> {
        Set(try query("SELECT interest_id FROM UserInterests WHERE user_id = ?", userId).compactMap { $0[0] as? String })
    }

    func saveInterests(userId: String, interestIds: Set<String>) throws {
        try validateInterests(userId: userId, interestIds: interestIds)
        try write { try writeInterestsUnlocked(userId: userId, interestIds: interestIds) }
    }

    private func validateInterests(userId: String, interestIds: Set<String>) throws {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        for id in interestIds where catalog.interest(id) == nil {
            throw PersonalizationError.unknownInterest(id)
        }
    }

    private func writeInterestsUnlocked(userId: String, interestIds: Set<String>) throws {
        try exec("DELETE FROM UserInterests WHERE user_id = ?", userId)
        for id in interestIds.sorted() {
            try exec("INSERT INTO UserInterests (user_id, interest_id) VALUES (?, ?)", userId, id)
        }
    }

    /// 一次儲存興趣、大分類與引導狀態（單一 transaction：全部成功或全部不變）。
    func savePersonalization(userId: String, interestIds: Set<String>, topLevelIds: Set<String>, status: OnboardingStatus) throws {
        try validateInterests(userId: userId, interestIds: interestIds)
        try validateTopLevel(topLevelIds)
        try write {
            try writeInterestsUnlocked(userId: userId, interestIds: interestIds)
            try writeTopLevelUnlocked(userId: userId, topLevelIds: topLevelIds)
            try exec("""
            INSERT INTO UserProfiles (user_id, onboarding_status) VALUES (?, ?)
            ON CONFLICT(user_id) DO UPDATE SET onboarding_status = excluded.onboarding_status, updated_at = CURRENT_TIMESTAMP
            """, userId, status.rawValue)
        }
    }

    // MARK: 分類偏好

    /// 使用者啟用的所有節點（L1 + 自動 / 手動啟用的子分類）。
    func enabledNodeIds(userId: String) throws -> Set<String> {
        Set(try query("SELECT node_id FROM UserCategoryPreferences WHERE user_id = ? AND is_enabled = 1", userId)
            .compactMap { $0[0] as? String })
    }

    func selectedTopLevelIds(userId: String) throws -> Set<String> {
        try enabledNodeIds(userId: userId).filter { catalog.node($0)?.level == 1 }
    }

    /// 偏好改變後：讓此帳號的照片重新做多標籤比對（沿用既有照片向量，不重算向量、不動手動標籤）。
    @discardableResult
    func invalidateAutoTagging(userId: String) throws -> Int {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        return try write {
            try exec("UPDATE PhotoAnalysisState SET status = 'stale' WHERE user_id = ? AND status = 'tagged'", userId)
            return db.changes
        }
    }

    func hasSavedCategorySelection(userId: String) throws -> Bool {
        try scalarInt("SELECT COUNT(*) FROM UserCategoryPreferences WHERE user_id = ?", userId) > 0
    }

    /// 儲存大分類選擇，並自動啟用（或取消自動啟用）其預設子分類。使用者手動調整過的子分類會被保留。
    func saveTopLevelSelection(userId: String, topLevelIds: Set<String>) throws {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        try validateTopLevel(topLevelIds)
        try write { try writeTopLevelUnlocked(userId: userId, topLevelIds: topLevelIds) }
    }

    private func validateTopLevel(_ topLevelIds: Set<String>) throws {
        for id in topLevelIds {
            guard let node = catalog.node(id) else { throw PersonalizationError.unknownNode(id) }
            guard node.level == 1 else { throw PersonalizationError.notTopLevel(id) }
        }
    }

    private func writeTopLevelUnlocked(userId: String, topLevelIds: Set<String>) throws {
        for top in catalog.topLevelNodes {
            let isSelected = topLevelIds.contains(top.id)
            try exec("""
            INSERT INTO UserCategoryPreferences (user_id, node_id, is_enabled, source, updated_at)
            VALUES (?, ?, ?, 'selection', CURRENT_TIMESTAMP)
            ON CONFLICT(user_id, node_id) DO UPDATE SET
                is_enabled = excluded.is_enabled, source = 'selection', updated_at = CURRENT_TIMESTAMP
            """, userId, top.id, Int64(isSelected ? 1 : 0))

            for child in InterestRecommender.defaultEnabledDescendants(ofTopLevel: top.id, catalog: catalog) {
                if isSelected {
                    try exec("""
                    INSERT INTO UserCategoryPreferences (user_id, node_id, is_enabled, source, updated_at)
                    VALUES (?, ?, 1, 'auto_from_parent', CURRENT_TIMESTAMP)
                    ON CONFLICT(user_id, node_id) DO UPDATE SET
                        is_enabled = 1, updated_at = CURRENT_TIMESTAMP
                    WHERE UserCategoryPreferences.source <> 'manual'
                    """, userId, child.id)
                } else {
                    try exec("""
                    DELETE FROM UserCategoryPreferences
                    WHERE user_id = ? AND node_id = ? AND source = 'auto_from_parent'
                    """, userId, child.id)
                }
            }
        }
    }

    /// 使用者手動開關單一子分類（會覆蓋自動啟用的設定）。
    func setNodeEnabled(userId: String, nodeId: String, enabled: Bool) throws {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        guard catalog.node(nodeId) != nil else { throw PersonalizationError.unknownNode(nodeId) }
        try write {
            try exec("""
            INSERT INTO UserCategoryPreferences (user_id, node_id, is_enabled, source, updated_at)
            VALUES (?, ?, ?, 'manual', CURRENT_TIMESTAMP)
            ON CONFLICT(user_id, node_id) DO UPDATE SET
                is_enabled = excluded.is_enabled, source = 'manual', updated_at = CURRENT_TIMESTAMP
            """, userId, nodeId, Int64(enabled ? 1 : 0))
        }
    }

    // MARK: 多標籤標記

    /// 需要（重新）標記的照片：有既有向量、未被移除 AI 分析、且尚未用目前版本標記。
    /// 直接讀取既有 PhotoFeatures.image_embedding，不重新計算照片向量。
    func assetsPendingTagging(userId: String, taggerVersion: String, limit: Int) throws -> [(assetId: String, embedding: [Float])] {
        guard !userId.isEmpty, limit > 0 else { return [] }
        return try query("""
        SELECT p.asset_id, p.image_embedding
        FROM PhotoFeatures p
        LEFT JOIN PhotoAnalysisState s ON s.asset_id = p.asset_id AND s.user_id = ?
        WHERE p.image_embedding IS NOT NULL
          AND p.ai_removed_at IS NULL
          AND (s.asset_id IS NULL OR s.status <> 'tagged' OR s.tagger_version IS NOT ?)
        ORDER BY p.rowid DESC
        LIMIT ?
        """, userId, taggerVersion, Int64(limit))
        .compactMap { row in
            guard let assetId = row[0] as? String, let blob = row[1] as? Blob else { return nil }
            return (assetId: assetId, embedding: EmbeddingCodec.decode(blob.bytes))
        }
    }

    /// 還需要（重新）標記的照片數，用於顯示進度。
    func pendingTaggingCount(userId: String, taggerVersion: String) throws -> Int {
        guard !userId.isEmpty else { return 0 }
        return try scalarInt("""
        SELECT COUNT(*)
        FROM PhotoFeatures p
        LEFT JOIN PhotoAnalysisState s ON s.asset_id = p.asset_id AND s.user_id = ?
        WHERE p.image_embedding IS NOT NULL
          AND p.ai_removed_at IS NULL
          AND (s.asset_id IS NULL OR s.status <> 'tagged' OR s.tagger_version IS NOT ?)
        """, userId, taggerVersion)
    }

    /// 以新的自動結果取代該照片「自動」產生的標籤。手動標籤（含使用者拒絕過的）一律保留且優先。
    /// 回傳 false 表示照片在這期間被移除 AI 分析，因此未寫入。
    @discardableResult
    func applyAutoTags(userId: String, assetId: String, suggestions: [TagSuggestion], taggerVersion: String) throws -> Bool {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        return try write {
            try applyAutoTagsUnlocked(userId: userId, assetId: assetId, suggestions: suggestions, taggerVersion: taggerVersion)
        }
    }

    /// 一次寫入多張照片的自動標籤（同一個 transaction，重新分類上萬張照片時快很多）。
    /// 規則與 applyAutoTags 完全相同；回傳實際寫入的張數。
    @discardableResult
    func applyAutoTagsBatch(userId: String, items: [(assetId: String, suggestions: [TagSuggestion])],
                            taggerVersion: String) throws -> Int {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        guard !items.isEmpty else { return 0 }
        return try write {
            var written = 0
            for item in items {
                if try applyAutoTagsUnlocked(userId: userId, assetId: item.assetId,
                                             suggestions: item.suggestions, taggerVersion: taggerVersion) {
                    written += 1
                }
            }
            return written
        }
    }

    private func applyAutoTagsUnlocked(userId: String, assetId: String, suggestions: [TagSuggestion],
                                       taggerVersion: String) throws -> Bool {
        let stateRows = try query(
            "SELECT ai_removed_at, image_embedding IS NOT NULL FROM PhotoFeatures WHERE asset_id = ?",
            assetId
        )
        guard let state = stateRows.first,
              state[0] == nil,
              (state[1] as? Int64 ?? 0) == 1 else {
            return false
        }

        // 只取代分類目錄的自動標籤；「我的 IP」的比對結果（node_id 含「:」）由 ReferenceMatcher 另外管理
        try exec("DELETE FROM PhotoTags WHERE user_id = ? AND asset_id = ? AND source = 'auto' AND instr(node_id, ':') = 0",
                 userId, assetId)
        for suggestion in suggestions where suggestion.status != .rejected {
            try exec("""
            INSERT OR IGNORE INTO PhotoTags
                (user_id, asset_id, node_id, score, source, status, tagger_version)
            VALUES (?, ?, ?, ?, 'auto', ?, ?)
            """, userId, assetId, suggestion.nodeId, Double(suggestion.score), suggestion.status.rawValue, taggerVersion)
        }
        try exec("""
        INSERT INTO PhotoAnalysisState (user_id, asset_id, status, tagger_version, last_error, updated_at)
        VALUES (?, ?, 'tagged', ?, NULL, CURRENT_TIMESTAMP)
        ON CONFLICT(user_id, asset_id) DO UPDATE SET
            status = 'tagged', tagger_version = excluded.tagger_version, last_error = NULL, updated_at = CURRENT_TIMESTAMP
        """, userId, assetId, taggerVersion)
        return true
    }

    // MARK: 從使用者的回答學習

    /// 使用者回答過的照片（分類目錄的手動標籤）：正例＝確認／手動加入，反例＝拒絕。最近回答的在前。
    /// 「我的 IP」由 ReferenceMatcher 另外處理，不在這裡。被移除 AI 分析的照片不算。
    func feedbackExamples(userId: String) throws -> (positives: [String: [[Float]]], negatives: [String: [[Float]]]) {
        var positives: [String: [[Float]]] = [:]
        var negatives: [String: [[Float]]] = [:]
        guard !userId.isEmpty else { return (positives, negatives) }
        for row in try query("""
        SELECT t.node_id, t.status, f.image_embedding
        FROM PhotoTags t JOIN PhotoFeatures f ON f.asset_id = t.asset_id
        WHERE t.user_id = ? AND t.source = 'manual' AND t.status IN ('accepted', 'rejected')
          AND instr(t.node_id, ':') = 0
          AND f.image_embedding IS NOT NULL AND f.ai_removed_at IS NULL
        ORDER BY t.updated_at DESC
        """, userId) {
            guard let nodeId = row[0] as? String, catalog.node(nodeId) != nil,
                  let status = row[1] as? String, let blob = row[2] as? Blob else { continue }
            let vector = MultiLabelTagger.normalized(EmbeddingCodec.decode(blob.bytes))
            guard !vector.isEmpty else { continue }
            if status == TagStatus.accepted.rawValue {
                positives[nodeId, default: []].append(vector)
            } else {
                negatives[nodeId, default: []].append(vector)
            }
        }
        return (positives, negatives)
    }

    /// 匯出訓練資料用：每一筆回答（照片、分類、是／不是）和照片向量（已正規化）。最近回答的在前。
    func trainingLabels(userId: String) throws -> [TrainingLabel] {
        guard !userId.isEmpty else { return [] }
        var result: [TrainingLabel] = []
        for row in try query("""
        SELECT t.asset_id, t.node_id, t.status, f.image_embedding
        FROM PhotoTags t JOIN PhotoFeatures f ON f.asset_id = t.asset_id
        WHERE t.user_id = ? AND t.source = 'manual' AND t.status IN ('accepted', 'rejected')
          AND instr(t.node_id, ':') = 0
          AND f.image_embedding IS NOT NULL AND f.ai_removed_at IS NULL
        ORDER BY t.updated_at DESC
        """, userId) {
            guard let assetId = row[0] as? String, let nodeId = row[1] as? String, catalog.node(nodeId) != nil,
                  let status = row[2] as? String, let blob = row[3] as? Blob else { continue }
            let vector = MultiLabelTagger.normalized(EmbeddingCodec.decode(blob.bytes))
            guard !vector.isEmpty else { continue }
            result.append(TrainingLabel(assetId: assetId, nodeId: nodeId, isPositive: status == TagStatus.accepted.rawValue,
                                        embedding: vector))
        }
        return result
    }

    /// 每個分類回答過幾張：是／不是
    func trainingLabelCounts(userId: String) throws -> [String: (positive: Int, negative: Int)] {
        guard !userId.isEmpty else { return [:] }
        var counts: [String: (positive: Int, negative: Int)] = [:]
        for row in try query("""
        SELECT node_id, SUM(CASE WHEN status = 'accepted' THEN 1 ELSE 0 END), SUM(CASE WHEN status = 'rejected' THEN 1 ELSE 0 END)
        FROM PhotoTags
        WHERE user_id = ? AND source = 'manual' AND status IN ('accepted', 'rejected') AND instr(node_id, ':') = 0
        GROUP BY node_id
        """, userId) {
            guard let nodeId = row[0] as? String else { continue }
            counts[nodeId] = (Int(row[1] as? Int64 ?? 0), Int(row[2] as? Int64 ?? 0))
        }
        return counts
    }

    /// 這個分類已經回答過的照片（標記模式不再列出）
    func answeredAssetIds(userId: String, nodeId: String) throws -> Set<String> {
        guard !userId.isEmpty else { return [] }
        return Set(try query("""
        SELECT asset_id FROM PhotoTags WHERE user_id = ? AND node_id = ? AND source = 'manual'
        """, userId, nodeId).compactMap { $0[0] as? String })
    }

    /// 使用者回答的「版本」：回答有變（多回答、改答案）就不同，App 用來決定要不要依新的回答重新分類。
    func feedbackSignature(userId: String) throws -> String {
        guard !userId.isEmpty else { return "0" }
        let row = try query("""
        SELECT COUNT(*), SUM(CASE WHEN status = 'accepted' THEN 1 ELSE 0 END), MAX(updated_at)
        FROM PhotoTags
        WHERE user_id = ? AND source = 'manual' AND status IN ('accepted', 'rejected') AND instr(node_id, ':') = 0
        """, userId).first
        let count = row?[0] as? Int64 ?? 0
        let accepted = row?[1] as? Int64 ?? 0
        let latest = row?[2] as? String ?? ""
        return "\(count)-\(accepted)-\(latest)"
    }

    func tags(userId: String, assetId: String) throws -> [PhotoTagRecord] {
        try query("""
        SELECT node_id, score, source, status FROM PhotoTags
        WHERE user_id = ? AND asset_id = ?
        ORDER BY CASE status WHEN 'accepted' THEN 0 WHEN 'candidate' THEN 1 ELSE 2 END, score DESC
        """, userId, assetId)
        .compactMap { row in
            guard let nodeId = row[0] as? String,
                  let source = (row[2] as? String).flatMap(TagSource.init(rawValue:)),
                  let status = (row[3] as? String).flatMap(TagStatus.init(rawValue:)) else { return nil }
            return PhotoTagRecord(nodeId: nodeId, score: row[1] as? Double, source: source, status: status)
        }
    }

    /// 使用者手動新增或確認標籤（來源改為 manual，之後的自動標記不會覆蓋）。
    func addOrConfirmTag(userId: String, assetId: String, nodeId: String) throws {
        try setManualTag(userId: userId, assetId: assetId, nodeId: nodeId, status: .accepted)
    }

    /// 使用者拒絕或移除標籤：記錄為手動「拒絕」，避免下次自動標記又加回來。
    func rejectTag(userId: String, assetId: String, nodeId: String) throws {
        try setManualTag(userId: userId, assetId: assetId, nodeId: nodeId, status: .rejected)
    }

    private func setManualTag(userId: String, assetId: String, nodeId: String, status: TagStatus) throws {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        guard !assetId.isEmpty else { throw PersonalizationError.invalidAssetId }
        let resolvedId: String
        if let node = catalog.node(nodeId), node.level >= 2 {
            resolvedId = node.id
        } else if CustomCategory.isCustomNodeId(nodeId), try customCategory(nodeId: nodeId, userId: userId) != nil {
            resolvedId = nodeId   // 我的 IP：手動確認 = 新的範例、手動拒絕 = 反例
        } else {
            throw PersonalizationError.unknownNode(nodeId)
        }
        try write {
            try exec("""
            INSERT INTO PhotoTags (user_id, asset_id, node_id, score, source, status, tagger_version)
            VALUES (?, ?, ?, NULL, 'manual', ?, NULL)
            ON CONFLICT(user_id, asset_id, node_id) DO UPDATE SET
                source = 'manual', status = excluded.status, updated_at = CURRENT_TIMESTAMP
            """, userId, assetId, resolvedId, status.rawValue)
        }
    }

    /// asset → 已確認的節點（不含拒絕與待確認）。
    func acceptedTagMap(userId: String) throws -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        for row in try query("SELECT asset_id, node_id FROM PhotoTags WHERE user_id = ? AND status = 'accepted'", userId) {
            guard let assetId = row[0] as? String, let nodeId = row[1] as? String else { continue }
            map[assetId, default: []].insert(nodeId)
        }
        return map
    }

    func candidateTags(userId: String, limit: Int = 200) throws -> [CandidateTag] {
        try query("""
        SELECT asset_id, node_id, score FROM PhotoTags
        WHERE user_id = ? AND status = 'candidate'
        ORDER BY score DESC
        LIMIT ?
        """, userId, Int64(limit))
        .compactMap { row in
            guard let assetId = row[0] as? String, let nodeId = row[1] as? String else { return nil }
            return CandidateTag(assetId: assetId, nodeId: nodeId, score: row[2] as? Double)
        }
    }

    /// 每個節點（含其所有子孫）底下有幾張已確認的照片。一張照片可同時計入多個分類。
    func photoCountsByNode(userId: String) throws -> [String: Int] {
        Self.photoCounts(from: try acceptedTagMap(userId: userId), catalog: catalog)
    }

    static func photoCounts(from tagMap: [String: Set<String>], catalog: TaxonomyCatalog) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (_, nodes) in tagMap {
            var covered = Set<String>()
            for nodeId in nodes {
                covered.insert(nodeId)
                for ancestor in catalog.ancestors(of: nodeId) { covered.insert(ancestor.id) }
            }
            for nodeId in covered { counts[nodeId, default: 0] += 1 }
        }
        return counts
    }

    /// 跨分類搜尋：照片必須同時符合所有選取的分類（每個分類包含其子孫）。結果依最新優先。
    func assetIds(userId: String, matchingAll nodeIds: [String]) throws -> [String] {
        let tagMap = try acceptedTagMap(userId: userId)
        let matched = Self.filter(tagMap: tagMap, matchingAll: nodeIds, catalog: catalog)
        guard !matched.isEmpty else { return [] }
        // 依 PhotoFeatures.rowid 由新到舊排序；沒有 PhotoFeatures 列的照片排最後。
        let order = try recencyOrder()
        return matched.sorted { (order[$0] ?? -1, $0) > (order[$1] ?? -1, $1) }
    }

    static func filter(tagMap: [String: Set<String>], matchingAll nodeIds: [String], catalog: TaxonomyCatalog) -> Set<String> {
        let requirements: [Set<String>] = nodeIds.map { id in
            Set([id] + catalog.descendants(of: id).map(\.id))
        }
        guard !requirements.isEmpty else { return [] }
        var result = Set<String>()
        for (assetId, tags) in tagMap {
            if requirements.allSatisfy({ !$0.isDisjoint(with: tags) }) {
                result.insert(assetId)
            }
        }
        return result
    }

    /// 依標籤名稱（中英文）搜尋照片，供主搜尋列合併結果使用。
    /// 「我的 IP」的名稱也算：搜尋 IP 名稱會找到已加入那個 IP 的照片（待確認的不算）。
    func assetIds(userId: String, matchingTagText text: String) throws -> [String] {
        let nodes = catalog.searchNodes(matching: text)
        let customNodeIds = try customNodeIds(userId: userId, matchingName: text)
        guard !nodes.isEmpty || !customNodeIds.isEmpty else { return [] }
        let tagMap = try acceptedTagMap(userId: userId)
        var result = Set<String>()
        for node in nodes {
            result.formUnion(Self.filter(tagMap: tagMap, matchingAll: [node.id], catalog: catalog))
        }
        if !customNodeIds.isEmpty {
            for (assetId, tags) in tagMap where !tags.isDisjoint(with: customNodeIds) {
                result.insert(assetId)
            }
        }
        return Array(result).sorted()
    }

    /// 名稱符合搜尋字的「我的 IP」在 PhotoTags 裡的節點 ID（例如「ip:6F1C…」）。
    /// - 搜尋字包含 IP 名稱（「五條悟的立牌」→ 五條悟），或 IP 名稱包含搜尋字（「五條」→ 五條悟，至少 2 個字）
    /// - 符合的是作品時，底下的角色一起算（搜尋「咒術迴戰」也找得到五條悟的照片）
    /// - 不分大小寫、全形半形，忽略空白
    func customNodeIds(userId: String, matchingName text: String) throws -> Set<String> {
        let query = Self.normalizedSearchName(text)
        guard !query.isEmpty else { return [] }
        let all = try customCategories(userId: userId)
        let matched = all.filter { category in
            let name = Self.normalizedSearchName(category.name)
            guard !name.isEmpty else { return false }
            return query.contains(name) || (query.count >= 2 && name.contains(query))
        }
        guard !matched.isEmpty else { return [] }
        let matchedIds = Set(matched.map(\.id))
        var ids = Set(matched.map(\.nodeId))
        for child in all where child.parentId.map(matchedIds.contains) == true {
            ids.insert(child.nodeId)
        }
        return ids
    }

    static func normalizedSearchName(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).filter { !$0.isWhitespace }
    }

    /// 目前仍有效的照片向量（被移除 AI 分析的照片回傳 nil）。直接讀取既有資料，不重新計算。
    func embedding(forAssetId assetId: String) throws -> [Float]? {
        guard let row = try query(
            "SELECT image_embedding FROM PhotoFeatures WHERE asset_id = ? AND ai_removed_at IS NULL",
            assetId
        ).first, let blob = row[0] as? Blob else { return nil }
        let vector = EmbeddingCodec.decode(blob.bytes)
        return vector.isEmpty ? nil : vector
    }

    /// asset_id → PhotoFeatures.rowid（數字越大越新），用於「最新優先」排序。
    func recencyOrder() throws -> [String: Int64] {
        var order: [String: Int64] = [:]
        guard try tableExists("PhotoFeatures") else { return order }
        for row in try query("SELECT asset_id, rowid FROM PhotoFeatures") {
            if let id = row[0] as? String, let rowid = row[1] as? Int64 { order[id] = rowid }
        }
        return order
    }

    // MARK: 主題相簿（沿用既有 UserAlbums / UserAlbumPhotos）

    func themeAlbums(containing assetId: String, userId: String) throws -> [ThemeAlbumMembership] {
        guard try tableExists("UserAlbums"), try tableExists("UserAlbumPhotos") else { return [] }
        return try query("""
        SELECT a.album_id, a.title
        FROM UserAlbumPhotos ap
        JOIN UserAlbums a ON a.album_id = ap.album_id
        WHERE ap.asset_id = ? AND (a.owner_user_id IS NULL OR a.owner_user_id = ?)
        ORDER BY a.created_at ASC
        """, assetId, userId)
        .compactMap { row in
            guard let id = row[0] as? String, let title = row[1] as? String else { return nil }
            return ThemeAlbumMembership(id: id, title: title)
        }
    }

    // MARK: 移除 AI 分析資料

    /// 照片是否已被使用者移除 AI 分析（同步流程與場景圖建立會略過這些照片）。
    func isAIAnalysisRemoved(assetId: String) throws -> Bool {
        try scalarInt("SELECT COUNT(*) FROM PhotoFeatures WHERE asset_id = ? AND ai_removed_at IS NOT NULL", assetId) > 0
    }

    func aiRemovedAssetIds() throws -> Set<String> {
        Set(try query("SELECT asset_id FROM PhotoFeatures WHERE ai_removed_at IS NOT NULL").compactMap { $0[0] as? String })
    }

    /// 只移除「指定照片、目前帳號」可安全刪除的 AI 資料。
    ///
    /// 會移除：該照片的特徵向量、場景圖、此帳號的自動標籤 / 候選、自動分類結果。
    /// 會保留：原始照片（本方法完全不接觸相簿）、asset_id、最愛、metadata、主題相簿成員、手動標籤、
    ///         手動「移動到其他相簿」的分類、其他照片與其他帳號的資料。
    ///
    /// 整個流程在單一 transaction 中執行；任何一步失敗都會回滾並丟出錯誤，呼叫端可直接重試。
    func removeAIAnalysis(userId: String, assetId: String, now: Date = Date()) throws -> AIAnalysisRemovalReport {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        guard !assetId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PersonalizationError.invalidAssetId }
        let removedAt = timestamp(now)

        return try write {
            let existing = try query(
                "SELECT owner_user_id, image_embedding IS NOT NULL, cluster_id, cluster_source FROM PhotoFeatures WHERE asset_id = ?",
                assetId
            ).first

            // 權限檢查：向量屬於其他帳號時拒絕（升級前的無主資料視為可由目前帳號處理）。
            if let existing, let owner = existing[0] as? String, owner != userId {
                throw PersonalizationError.notAuthorized
            }

            var vectorRemoved = false
            var clusterCleared = false
            if let existing {
                vectorRemoved = (existing[1] as? Int64 ?? 0) == 1
                let hadCluster = existing[2] != nil
                let isManualCluster = (existing[3] as? String) == "manual"
                clusterCleared = hadCluster && !isManualCluster

                try exec("""
                UPDATE PhotoFeatures
                SET image_embedding = NULL,
                    cluster_id = CASE WHEN cluster_source = 'manual' THEN cluster_id ELSE NULL END,
                    ai_removed_at = ?,
                    owner_user_id = COALESCE(owner_user_id, ?)
                WHERE asset_id = ? AND (owner_user_id IS NULL OR owner_user_id = ?)
                """, removedAt, userId, assetId, userId)
                guard db.changes == 1 else { throw PersonalizationError.notAuthorized }
            } else {
                // 照片尚未被掃描：留下最小識別紀錄，讓同步流程之後不會再自動分析它。
                try exec("""
                INSERT INTO PhotoFeatures (asset_id, metadata, image_embedding, cluster_id, is_favorite, owner_user_id, ai_removed_at)
                VALUES (?, '{}', NULL, NULL, 0, ?, ?)
                """, assetId, userId, removedAt)
            }

            try exec("DELETE FROM PhotoTags WHERE user_id = ? AND asset_id = ? AND source = 'auto'", userId, assetId)
            let autoTagsRemoved = db.changes
            // 照片中的文字（OCR）、臉的數量也是 AI 分析資料
            if try tableExists("PhotoText") {
                try exec("DELETE FROM PhotoText WHERE asset_id = ?", assetId)
            }
            if try tableExists("PhotoFaces") {
                try exec("DELETE FROM PhotoFaces WHERE asset_id = ?", assetId)
            }

            let manualTagsKept = try scalarInt(
                "SELECT COUNT(*) FROM PhotoTags WHERE user_id = ? AND asset_id = ? AND source = 'manual'",
                userId, assetId
            )
            var albumsKept = 0
            if try tableExists("UserAlbumPhotos") {
                albumsKept = try scalarInt("SELECT COUNT(*) FROM UserAlbumPhotos WHERE asset_id = ?", assetId)
            }

            try exec("""
            INSERT INTO PhotoAnalysisState (user_id, asset_id, status, tagger_version, last_error, updated_at)
            VALUES (?, ?, 'removed', NULL, NULL, CURRENT_TIMESTAMP)
            ON CONFLICT(user_id, asset_id) DO UPDATE SET
                status = 'removed', tagger_version = NULL, last_error = NULL, updated_at = CURRENT_TIMESTAMP
            """, userId, assetId)

            return AIAnalysisRemovalReport(
                assetId: assetId,
                vectorRemoved: vectorRemoved,
                clusterCleared: clusterCleared,
                autoTagsRemoved: autoTagsRemoved,
                manualTagsKept: manualTagsKept,
                albumMembershipsKept: albumsKept
            )
        }
    }

    /// 重新分析前的準備：解除「已移除」標記、清掉舊的自動結果。
    /// （智慧搜尋的場景圖存在 AbstractSearch.sqlite，由 App 端的 AbstractSearchCoordinator 處理。）
    /// 之後由 App 重新從相簿「讀取」照片並產生新向量；本方法不接觸照片本身。
    /// 若之後的分析失敗，照片會維持「沒有向量、未被排除」的狀態，下次同步會自動重試。
    func prepareReanalysis(userId: String, assetId: String) throws {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        guard !assetId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PersonalizationError.invalidAssetId }
        try write {
            let existing = try query("SELECT owner_user_id FROM PhotoFeatures WHERE asset_id = ?", assetId).first
            if let existing, let owner = existing[0] as? String, owner != userId {
                throw PersonalizationError.notAuthorized
            }
            try exec("""
            UPDATE PhotoFeatures SET ai_removed_at = NULL, owner_user_id = COALESCE(owner_user_id, ?)
            WHERE asset_id = ?
            """, userId, assetId)
            try exec("DELETE FROM PhotoTags WHERE user_id = ? AND asset_id = ? AND source = 'auto'", userId, assetId)
            if try tableExists("PhotoText") {
                try exec("DELETE FROM PhotoText WHERE asset_id = ?", assetId)   // 重新分析時也重新辨識文字
            }
            if try tableExists("PhotoFaces") {
                try exec("DELETE FROM PhotoFaces WHERE asset_id = ?", assetId)  // 以前人臉偵測留下的資料
            }
            try exec("""
            INSERT INTO PhotoAnalysisState (user_id, asset_id, status, tagger_version, last_error, updated_at)
            VALUES (?, ?, 'pending', NULL, NULL, CURRENT_TIMESTAMP)
            ON CONFLICT(user_id, asset_id) DO UPDATE SET
                status = 'pending', tagger_version = NULL, last_error = NULL, updated_at = CURRENT_TIMESTAMP
            """, userId, assetId)
        }
    }

    func markAnalysisFailed(userId: String, assetId: String, reason: String) throws {
        guard !userId.isEmpty else { return }
        try write {
            try exec("""
            INSERT INTO PhotoAnalysisState (user_id, asset_id, status, tagger_version, last_error, updated_at)
            VALUES (?, ?, 'failed', NULL, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(user_id, asset_id) DO UPDATE SET
                status = 'failed', last_error = excluded.last_error, updated_at = CURRENT_TIMESTAMP
            """, userId, assetId, reason)
        }
    }

    func analysisStatus(userId: String, assetId: String) throws -> (status: String, lastError: String?)? {
        guard let row = try query(
            "SELECT status, last_error FROM PhotoAnalysisState WHERE user_id = ? AND asset_id = ?",
            userId, assetId
        ).first, let status = row[0] as? String else { return nil }
        return (status, row[1] as? String)
    }
}

// MARK: - 我的 IP（使用者自訂分類）
//
// 只管理 App 自己的分類資料：建立、改名、刪除分類都不會碰到原始照片或系統相簿。

extension PersonalizationStore {

    func customCategories(userId: String, kind: CustomCategoryKind? = nil) throws -> [CustomCategory] {
        guard !userId.isEmpty else { return [] }
        return try query("""
        SELECT category_id, kind, name, parent_category_id, cover_asset_id FROM UserCustomCategories
        WHERE user_id = ? AND (? IS NULL OR kind = ?)
        ORDER BY created_at, category_id
        """, userId, kind?.rawValue, kind?.rawValue)
        .compactMap { row in
            guard let id = row[0] as? String,
                  let kind = (row[1] as? String).flatMap(CustomCategoryKind.init(rawValue:)),
                  let name = row[2] as? String else { return nil }
            return CustomCategory(id: id, kind: kind, name: name,
                                  parentId: row[3] as? String, coverAssetId: row[4] as? String)
        }
    }

    func customCategory(nodeId: String, userId: String) throws -> CustomCategory? {
        guard let parsed = CustomCategory.parse(nodeId: nodeId) else { return nil }
        return try customCategories(userId: userId, kind: parsed.kind).first { $0.id == parsed.id }
    }

    private func validatedName(_ name: String, userId: String, kind: CustomCategoryKind, excluding categoryId: String?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { throw PersonalizationError.invalidCategoryName }
        let duplicate = try customCategories(userId: userId, kind: kind).contains {
            $0.id != categoryId && $0.name.compare(trimmed, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
        }
        if duplicate { throw PersonalizationError.duplicateCategoryName(trimmed) }
        return trimmed
    }

    /// 建立分類並把範例照片記為手動確認（範例必須已有照片向量）。
    /// - Parameter parentId: 上層 IP（只能是最上層的 IP，最多兩層），nil 代表建立最上層。
    @discardableResult
    func createCustomCategory(userId: String, kind: CustomCategoryKind, name: String,
                              exampleAssetIds: [String], parentId: String? = nil,
                              id: String = UUID().uuidString) throws -> CustomCategory {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        let finalName = try validatedName(name, userId: userId, kind: kind, excluding: nil)
        if let parentId {
            guard let parent = try customCategories(userId: userId, kind: kind).first(where: { $0.id == parentId }),
                  parent.parentId == nil else { throw PersonalizationError.notAuthorized }
        }
        let examples = Array(Set(exampleAssetIds.filter { !$0.isEmpty }))
        let withVectors = try examples.filter { try embedding(forAssetId: $0) != nil }
        guard !withVectors.isEmpty else { throw PersonalizationError.needsExamples }

        let category = CustomCategory(id: id, kind: kind, name: finalName, parentId: parentId)
        try write {
            try exec("""
            INSERT INTO UserCustomCategories (category_id, user_id, kind, name, parent_category_id) VALUES (?, ?, ?, ?, ?)
            """, category.id, userId, kind.rawValue, finalName, parentId)
            for assetId in withVectors {
                try exec("""
                INSERT INTO PhotoTags (user_id, asset_id, node_id, score, source, status, tagger_version)
                VALUES (?, ?, ?, NULL, 'manual', 'accepted', NULL)
                ON CONFLICT(user_id, asset_id, node_id) DO UPDATE SET
                    source = 'manual', status = 'accepted', updated_at = CURRENT_TIMESTAMP
                """, userId, assetId, category.nodeId)
            }
        }
        return category
    }

    func renameCustomCategory(userId: String, categoryId: String, name: String) throws {
        guard let existing = try customCategories(userId: userId).first(where: { $0.id == categoryId }) else {
            throw PersonalizationError.notAuthorized
        }
        let finalName = try validatedName(name, userId: userId, kind: existing.kind, excluding: categoryId)
        try write {
            try exec("""
            UPDATE UserCustomCategories SET name = ?, updated_at = CURRENT_TIMESTAMP
            WHERE category_id = ? AND user_id = ?
            """, finalName, categoryId, userId)
        }
    }

    /// 刪除分類：只刪除 App 的分類與對應標籤，照片本身、系統相簿、主題相簿都不受影響。
    func deleteCustomCategory(userId: String, categoryId: String) throws {
        guard let existing = try customCategories(userId: userId).first(where: { $0.id == categoryId }) else {
            throw PersonalizationError.notAuthorized
        }
        try write {
            try exec("DELETE FROM PhotoTags WHERE user_id = ? AND node_id = ?", userId, existing.nodeId)
            // 底下的角色不刪除，改成最上層
            try exec("UPDATE UserCustomCategories SET parent_category_id = NULL WHERE parent_category_id = ? AND user_id = ?",
                     categoryId, userId)
            try exec("DELETE FROM UserCustomCategories WHERE category_id = ? AND user_id = ?", categoryId, userId)
        }
    }

    /// 設定（或清除）相簿封面。只存照片識別碼。
    func setCustomCategoryCover(userId: String, categoryId: String, assetId: String?) throws {
        guard try customCategories(userId: userId).contains(where: { $0.id == categoryId }) else {
            throw PersonalizationError.notAuthorized
        }
        try write {
            try exec("""
            UPDATE UserCustomCategories SET cover_asset_id = ?, updated_at = CURRENT_TIMESTAMP
            WHERE category_id = ? AND user_id = ?
            """, assetId, categoryId, userId)
        }
    }

    /// 範例（手動確認）與反例（手動拒絕）的照片。
    func customExamples(userId: String, nodeId: String) throws -> (positives: [String], negatives: [String]) {
        var positives: [String] = []
        var negatives: [String] = []
        for row in try query("""
        SELECT asset_id, status FROM PhotoTags
        WHERE user_id = ? AND node_id = ? AND source = 'manual'
        """, userId, nodeId) {
            guard let assetId = row[0] as? String, let status = row[1] as? String else { continue }
            if status == TagStatus.accepted.rawValue { positives.append(assetId) }
            if status == TagStatus.rejected.rawValue { negatives.append(assetId) }
        }
        return (positives, negatives)
    }

    /// 以新的比對結果取代這個分類的「自動」結果；手動確認與拒絕一律保留（主鍵衝突時忽略自動結果）。
    @discardableResult
    func replaceAutoMatches(userId: String, nodeId: String, matches: [ReferenceMatch]) throws -> Int {
        guard try customCategory(nodeId: nodeId, userId: userId) != nil else { throw PersonalizationError.notAuthorized }
        return try write {
            try exec("DELETE FROM PhotoTags WHERE user_id = ? AND node_id = ? AND source = 'auto'", userId, nodeId)
            var inserted = 0
            for match in matches where match.status != .rejected {
                try exec("""
                INSERT OR IGNORE INTO PhotoTags (user_id, asset_id, node_id, score, source, status, tagger_version)
                SELECT ?, asset_id, ?, ?, 'auto', ?, ?
                FROM PhotoFeatures WHERE asset_id = ? AND ai_removed_at IS NULL
                """, userId, nodeId, Double(match.score), match.status.rawValue, ReferenceMatcher.version, match.assetId)
                inserted += db.changes
            }
            return inserted
        }
    }

    /// 所有仍有效的照片向量（已移除 AI 分析的照片不包含）。直接讀取既有資料，不重新計算。
    func activeEmbeddings() throws -> [(assetId: String, embedding: [Float])] {
        try query("""
        SELECT asset_id, image_embedding FROM PhotoFeatures
        WHERE image_embedding IS NOT NULL AND ai_removed_at IS NULL
        """).compactMap { row in
            guard let assetId = row[0] as? String, let blob = row[1] as? Blob else { return nil }
            let vector = EmbeddingCodec.decode(blob.bytes)
            return vector.isEmpty ? nil : (assetId: assetId, embedding: vector)
        }
    }

    /// 每個自訂分類目前已確認的照片數。
    func customCategoryCounts(userId: String) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in try query("""
        SELECT node_id, COUNT(*) FROM PhotoTags
        WHERE user_id = ? AND status = 'accepted' AND instr(node_id, ':') > 0
        GROUP BY node_id
        """, userId) {
            if let nodeId = row[0] as? String, let count = row[1] as? Int64 { counts[nodeId] = Int(count) }
        }
        return counts
    }
}

// MARK: - 標記進度

extension PersonalizationStore {

    /// 已用目前版本標記完成的照片（演唱會場次只用標記完成的照片當起點）。
    func taggedAssetIds(userId: String, taggerVersion: String) throws -> Set<String> {
        guard !userId.isEmpty else { return [] }
        return Set(try query("""
        SELECT asset_id FROM PhotoAnalysisState
        WHERE user_id = ? AND status = 'tagged' AND tagger_version = ?
        """, userId, taggerVersion).compactMap { $0[0] as? String })
    }

    /// 用某個分類目錄版本標記過的照片（不管之後使用者回答了什麼）。
    /// 回答改變時版本後面會多出不同的「/fb-…」，演唱會場次不必因此等全部重新分類完。
    func taggedAssetIds(userId: String, taggerVersionPrefix prefix: String) throws -> Set<String> {
        guard !userId.isEmpty, !prefix.isEmpty else { return [] }
        return Set(try query("""
        SELECT asset_id FROM PhotoAnalysisState
        WHERE user_id = ? AND status = 'tagged' AND substr(tagger_version, 1, ?) = ?
        """, userId, Int64(prefix.count), prefix).compactMap { $0[0] as? String })
    }
}

// MARK: - 演唱會場次

extension PersonalizationStore {

    /// 指定分類的標記狀態（自動或手動、確認／待確認／拒絕），用來找演唱會場次的起點與使用者拒絕過的照片。
    func tagStatuses(userId: String, nodeIds: Set<String>) throws -> [(assetId: String, nodeId: String, status: TagStatus, isManual: Bool)] {
        guard !userId.isEmpty, !nodeIds.isEmpty else { return [] }
        let wanted = nodeIds
        return try query("SELECT asset_id, node_id, status, source FROM PhotoTags WHERE user_id = ?", userId)
            .compactMap { row in
                guard let assetId = row[0] as? String, let nodeId = row[1] as? String, wanted.contains(nodeId),
                      let raw = row[2] as? String, let status = TagStatus(rawValue: raw) else { return nil }
                return (assetId, nodeId, status, (row[3] as? String) == "manual")
            }
    }
}

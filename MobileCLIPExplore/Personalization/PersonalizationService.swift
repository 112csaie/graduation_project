// PersonalizationService.swift
//
// App 端的個人化分類服務：連接 PersonalizationStore（資料庫）、既有 MobileCLIP 模型與系統相簿（唯讀）。
//
// 照片安全：
// - 本檔案只用 PHAsset.fetchAssets（唯讀查詢）確認照片存在；不使用任何 PHAssetChangeRequest /
//   PHAssetCollectionChangeRequest / performChanges，也不讀寫任何照片檔案。
// - 「移除 AI 分析資料」與「重新分析」只改動 App 自己的 SQLite 資料。

import Foundation
import Photos
import CoreLocation

// MARK: - 本機帳號 Session

/// 目前登入的本機帳號 ID。專案目前沒有雲端帳號，這個 ID 用來區分同一台裝置上不同 email 的偏好、標籤與資料擁有權。
enum LocalUserSession {
    private static let key = "currentLocalUserId"

    static var currentUserId: String? {
        let value = UserDefaults.standard.string(forKey: key)
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func set(_ userId: String?) {
        if let userId, !userId.isEmpty {
            UserDefaults.standard.set(userId, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

extension Notification.Name {
    /// 標籤、偏好或 AI 分析資料改變時發出（UI 重新載入用）。
    static let personalizationUpdated = Notification.Name("PersonalizationUpdated")
    /// 重新分類進度：userInfo ["done": Int, "total": Int]。
    static let personalizationTaggingProgress = Notification.Name("PersonalizationTaggingProgress")
}

// MARK: - 瀏覽資料

/// 分類瀏覽中的一個項目（個人化分類的一個小分類；一張照片可同時屬於多個項目）。
struct PersonalCategoryItem: Identifiable, Hashable {
    var id: String { node.id }
    let node: TaxonomyNode
    let photoCount: Int
    let coverAssetId: String?
    let isRelatedToInterests: Bool
    let isEnabled: Bool
}

struct PersonalCategorySection: Identifiable, Hashable {
    var id: String { node.id }
    let node: TaxonomyNode
    let isEnabled: Bool
    let isRecommended: Bool
    let photoCount: Int
    let items: [PersonalCategoryItem]
}

/// 「我的 IP」相簿卡片。
struct CustomCategorySummary: Identifiable, Hashable {
    var id: String { category.nodeId }
    let category: CustomCategory
    let photoCount: Int
    let coverAssetId: String?
    /// 待確認張數（作品含底下角色）
    var candidateCount: Int = 0

    var albumSummary: CategoryAlbumSummary {
        CategoryAlbumSummary(id: category.nodeId, title: category.name, coverAssetId: coverAssetId, photoCount: photoCount)
    }
}

/// 「IP」頁的一組：作品（或團體）本身 + 底下的角色。作品相簿包含角色的照片。
struct IPGroup: Identifiable, Hashable {
    var id: String { work.id }
    let work: CustomCategorySummary
    let characters: [CustomCategorySummary]
}

struct IPBrowseData {
    var groups: [IPGroup] = []
    var candidateCount = 0
    static let empty = IPBrowseData()
}

struct PersonalBrowseData {
    let enabledSections: [PersonalCategorySection]
    let otherSections: [PersonalCategorySection]
    let candidateCount: Int
    let categorizedPhotoCount: Int
    let hasSelectedCategories: Bool
    let enabledCategoryCount: Int

    static let empty = PersonalBrowseData(enabledSections: [], otherSections: [], candidateCount: 0, categorizedPhotoCount: 0,
                                          hasSelectedCategories: false, enabledCategoryCount: 0)
}

struct SavedPersonalization {
    let interestIds: Set<String>
    let topLevelIds: Set<String>
    let hasSavedCategories: Bool
}

// MARK: - Service

final class PersonalizationService {

    static let shared = PersonalizationService()

    let catalog: TaxonomyCatalog = .builtIn
    let thresholds: TaggingThresholds = .default
    /// 分類目錄＋門檻的版本（不含使用者的回答）
    var baseTaggerVersion: String { MultiLabelTagger.version(catalog: catalog, thresholds: thresholds) }
    /// 標記版本：分類目錄、門檻或使用者的回答（是／不是）改變時不同 → 用既有照片向量重新分類
    var taggerVersion: String { baseTaggerVersion + "/fb-" + feedbackSignature }

    // MARK: 從使用者的回答學習

    private let feedbackLock = NSLock()
    private var cachedFeedbackSignature: (userId: String, value: String)?
    /// 依回答建立的範例（只在 workQueue 上讀寫）
    private var feedbackModel: (signature: String, feedback: TagFeedback)?
    private var feedbackRetagScheduled = false

    /// 使用者回答（分類目錄的手動標籤）的版本；回答改變時才重新查詢
    private var feedbackSignature: String {
        feedbackLock.lock()
        defer { feedbackLock.unlock() }
        guard let store, let userId = LocalUserSession.currentUserId else { return "0" }
        if let cached = cachedFeedbackSignature, cached.userId == userId { return cached.value }
        let value = (try? store.feedbackSignature(userId: userId)) ?? "0"
        cachedFeedbackSignature = (userId, value)
        return value
    }

    /// 回答過的照片當範例（回答改變才重建）。只在 workQueue 上呼叫。
    private func feedbackOnQueue(store: PersonalizationStore, userId: String) -> TagFeedback? {
        let signature = feedbackSignature
        if let model = feedbackModel, model.signature == signature { return model.feedback }
        guard let examples = try? store.feedbackExamples(userId: userId) else { return nil }
        let feedback = TagFeedback(positives: examples.positives, negatives: examples.negatives)
        feedbackModel = (signature, feedback)
        return feedback
    }

    /// 使用者回答了分類（是／不是／手動加入）：幾秒後依新的回答重新分類，
    /// 連續回答很多張時只重新分類一次。
    private func feedbackChanged(nodeId: String) {
        guard !CustomCategory.isCustomNodeId(nodeId) else { return }   // 我的 IP 由 ReferenceMatcher 處理
        feedbackLock.lock()
        cachedFeedbackSignature = nil
        let alreadyScheduled = feedbackRetagScheduled
        feedbackRetagScheduled = true
        feedbackLock.unlock()
        guard !alreadyScheduled else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
            self.feedbackLock.lock()
            self.feedbackRetagScheduled = false
            self.cachedFeedbackSignature = nil
            self.feedbackLock.unlock()
            self.scheduleTagging()
        }
    }

    /// 標記工作在單一序列佇列上執行，避免重複計算。
    /// userInitiated：掃描（同為 userInitiated）進行中也能分到 CPU，掃描與分類才會同步前進。
    /// 標記本身只是向量點積，很輕，不會明顯拖慢掃描。
    private let workQueue = DispatchQueue(label: "com.photoai.personalization.work", qos: .userInitiated)
    private var cachedTagger: MultiLabelTagger?    // 只在 workQueue 上讀寫
    private var sessionTaggedCount = 0             // 這次啟動累計分類張數（只在 workQueue 上讀寫）
    private var pendingScheduled = false
    private let scheduleLock = NSLock()

    // 我的 IP：比對在獨立佇列執行（不和分類目錄的標記互相等待），多次觸發會合併成一次
    fileprivate let customQueue = DispatchQueue(label: "com.photoai.personalization.custom", qos: .utility)
    fileprivate let customLock = NSLock()
    fileprivate var customPendingAll = false
    fileprivate var customPendingIds = Set<String>()
    fileprivate var customScheduled = false
    fileprivate var customNameCache: [String: String] = [:]   // nodeId → 名稱（customLock 保護）

    private init() {}

    private var store: PersonalizationStore? { DatabaseManager.shared.personalization }

    var isAvailable: Bool { store != nil }

    private func requireUser() throws -> (store: PersonalizationStore, userId: String) {
        guard let store else { throw PersonalizationError.analysisFailed("個人化資料庫尚未就緒") }
        guard let userId = LocalUserSession.currentUserId else { throw PersonalizationError.notSignedIn }
        return (store, userId)
    }

    // MARK: Session

    /// 登入 / 註冊後呼叫：取得本機帳號 ID，並讓升級前的無主資料歸屬於此帳號。
    @discardableResult
    func signIn(email: String?, displayName: String?) -> String? {
        guard let store else { return nil }
        do {
            let userId = try store.resolveUser(email: email, displayName: displayName)
            LocalUserSession.set(userId)
            try store.claimLegacyData(for: userId)
            return userId
        } catch {
            print("[Personalization] 登入建立本機帳號失敗: \(error)")
            return nil
        }
    }

    /// 升級前就已登入（isLoggedIn = true 但沒有本機帳號 ID）的使用者，在啟動時補建。
    func restoreSessionIfNeeded(email: String, displayName: String) {
        guard LocalUserSession.currentUserId == nil else { return }
        signIn(email: email, displayName: displayName)
    }

    func signOut() {
        LocalUserSession.set(nil)
        LiveEventCenter.shared.reset()
    }

    func needsOnboarding() -> Bool {
        guard let store, let userId = LocalUserSession.currentUserId else { return false }
        return ((try? store.onboardingStatus(userId: userId)) ?? .completed) == .pending
    }

    // MARK: 偏好

    func loadSavedPersonalization() throws -> SavedPersonalization {
        let (store, userId) = try requireUser()
        return SavedPersonalization(
            interestIds: try store.interestIds(userId: userId),
            topLevelIds: try store.selectedTopLevelIds(userId: userId),
            hasSavedCategories: try store.hasSavedCategorySelection(userId: userId)
        )
    }

    /// 儲存興趣與大分類。只改變偏好，不會刪除或重算任何照片向量與標籤。
    func savePersonalization(interestIds: Set<String>, topLevelIds: Set<String>, status: OnboardingStatus) throws {
        let (store, userId) = try requireUser()
        let previousTopLevel = try store.selectedTopLevelIds(userId: userId)
        let previousInterests = try store.interestIds(userId: userId)
        try store.savePersonalization(userId: userId, interestIds: interestIds, topLevelIds: topLevelIds, status: status)
        if previousTopLevel != topLevelIds || previousInterests != interestIds {
            // 興趣或大分類改變 → 全部照片用既有向量重新比對（不重算向量、不動手動 tag）
            try store.invalidateAutoTagging(userId: userId)
            scheduleTagging()
        }
        postUpdate()
    }

    func skipOnboarding() throws {
        let (store, userId) = try requireUser()
        try store.setOnboardingStatus(userId: userId, .skipped)
    }

    // MARK: 多標籤標記（沿用既有向量）

    /// 在背景排程一次標記（重複呼叫會合併成一次）。
    func scheduleTagging() {
        scheduleLock.lock()
        if pendingScheduled { scheduleLock.unlock(); return }
        pendingScheduled = true
        scheduleLock.unlock()

        workQueue.async {
            self.scheduleLock.lock()
            self.pendingScheduled = false
            self.scheduleLock.unlock()
            self.tagAllPendingOnQueue()
        }
    }

    /// 提早準備分類文字向量（同步開始時呼叫），讓第一批照片掃描完就能立即分類，不必等文字模型。
    func prepareTaggerInBackground() {
        workQueue.async {
            guard let store = self.store else { return }
            _ = self.preparedTaggerOnQueue(store: store)
        }
        // 啟動時整理一次我的 IP（例如清掉有角色的作品先前留下的待確認）
        scheduleCustomMatching(delay: 5)
        // 演唱會場次（只在記憶體中，每次啟動重新偵測）
        LiveEventCenter.shared.queue.asyncAfter(deadline: .now() + 8) { LiveEventCenter.shared.refreshIfNeeded() }
    }

    /// 分批處理到全部完成，並回報進度（Classification 頁面顯示「正在分類 1,200 / 4,000」）。
    /// 掃描期間會持續有新照片加入，因此每批結束後重新計算總數。
    private func tagAllPendingOnQueue() {
        guard let store, let userId = LocalUserSession.currentUserId else { return }
        var remaining = (try? store.pendingTaggingCount(userId: userId, taggerVersion: taggerVersion)) ?? 0
        guard remaining > 0 else { return }
        let timingStart = PerfLog.now()   // PF-04 重新分類速度
        var done = 0
        postProgress(done: 0, total: remaining)
        // 畫面重新整理（分類頁會重讀全部標籤）最多每 4 秒一次，跑完再一次；進度數字照常每批更新
        var lastUpdate = Date.distantPast
        while true {
            let count = tagPendingPhotosOnQueue(limit: 200)
            guard count > 0 else { break }
            done += count
            sessionTaggedCount += count
            remaining = (try? store.pendingTaggingCount(userId: userId, taggerVersion: taggerVersion)) ?? 0
            postProgress(done: done, total: done + remaining)
            if Date().timeIntervalSince(lastUpdate) >= 4 {
                postUpdate()
                lastUpdate = Date()
                // 一有新照片就開始辨識像紙張或卡片的照片（同時只會有一個辨識工作）
                PhotoTextCoordinator.shared.schedulePaperScan(delay: 0)
            }
        }
        // 迴圈結束代表已經沒有可以標記的照片（掃描期間新加入的照片也在迴圈裡處理掉了）
        postProgress(done: done, total: done)
        if done > 0 { PerfLog.log("分類", since: timingStart, count: done) }
        if done > 0 { postUpdate() }
        // 新掃描的照片也比對「我的 IP」、重新整理演唱會場次；像紙張或卡片的照片辨識文字（票根、收據…）
        if done > 0 {
            scheduleCustomMatching(delay: 1)
            LiveEventCenter.shared.refreshIfNeeded(force: true)
            PhotoTextCoordinator.shared.schedulePaperScan(delay: 0)
        }
        // 以前人臉偵測留下的資料清掉（不再偵測人臉）
        clearOldFaceDataOnce()
    }

    /// 準備分類文字向量的進度（第一次使用或分類目錄更新後）：userInfo ["preparing": Int, "preparingTotal": Int]。
    private func postPreparing(done: Int, total: Int) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .personalizationTaggingProgress, object: nil,
                                            userInfo: ["preparing": done, "preparingTotal": total])
        }
    }

    private func postProgress(done: Int, total: Int) {
        let session = sessionTaggedCount   // 在 workQueue 上讀取
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .personalizationTaggingProgress, object: nil,
                                            userInfo: ["done": done, "total": total, "sessionDone": session])
        }
    }

    /// 同步版本（供背景任務使用）。不可在主執行緒呼叫。
    @discardableResult
    func tagPendingPhotos(limit: Int) -> Int {
        let count = workQueue.sync { tagPendingPhotosOnQueue(limit: limit) }
        if count > 0 { postUpdate() }
        return count
    }

    private func tagPendingPhotosOnQueue(limit: Int) -> Int {
        guard let store, let userId = LocalUserSession.currentUserId else { return 0 }
        guard let tagger = preparedTaggerOnQueue(store: store) else { return 0 }

        do {
            let pending = try store.assetsPendingTagging(userId: userId, taggerVersion: taggerVersion, limit: limit)
            let (preferred, boosted) = try preferenceContext(store: store, userId: userId)
            // 照片中的文字（OCR）當作分類線索
            let texts = (try? store.normalizedPhotoTexts(assetIds: pending.map(\.assetId))) ?? [:]
            // 你回答過的照片當範例：很像「不是」的拿掉、很像「是」的加入
            let feedback = feedbackOnQueue(store: store, userId: userId)
            let results = pending.map { item -> (assetId: String, suggestions: [TagSuggestion]) in
                var suggestions = tagger.suggestTags(for: item.embedding, preferredTopLevelIds: preferred, boostedNodeIds: boosted)
                if let feedback { suggestions = feedback.apply(suggestions, imageEmbedding: item.embedding) }
                let withText = withTextHints(suggestions, text: texts[item.assetId], embedding: item.embedding,
                                             tagger: tagger, assetId: item.assetId)
                return (item.assetId, withPeopleHints(withText, assetId: item.assetId))
            }
            // 整批寫入同一個 transaction（不必每張照片各寫一次硬碟）
            let tagged = try store.applyAutoTagsBatch(userId: userId, items: results, taggerVersion: taggerVersion)
            if tagged > 0 { print("[Personalization] 多標籤標記完成：\(tagged) 張（沿用既有照片向量）") }
            return tagged
        } catch {
            print("[Personalization] 多標籤標記失敗: \(error)")
            return 0
        }
    }

    /// 準備分類文字向量：先沿用 SemanticDictionary 既有向量，再用既有文字模型補算缺少的部分。
    private func preparedTaggerOnQueue(store: PersonalizationStore) -> MultiLabelTagger? {
        if let cachedTagger { return cachedTagger }
        do {
            try store.reuseExistingDictionaryEmbeddings()
            // 先用 App 內附、預先算好的向量（不需要在手機上跑文字模型）；只有新的描述才現算
            if let bundled = Bundle.main.path(forResource: "PhotoAI", ofType: "sqlite") {
                let imported = (try? store.importPrecomputedPromptEmbeddings(fromDatabaseAt: bundled)) ?? 0
                if imported > 0 { print("[Personalization] 匯入預先計算的分類文字向量：\(imported) 筆") }
            }
            let missing = try store.promptsNeedingEmbedding()
            for (index, item) in missing.enumerated() {
                if index % 10 == 0 { postPreparing(done: index, total: missing.count) }
                guard let vector = DatabaseManager.shared.computeTextEmbedding(for: item.prompt) else { continue }
                try store.savePromptEmbedding(nodeId: item.nodeId, prompt: item.prompt, embedding: vector)
            }
            if !missing.isEmpty { postPreparing(done: missing.count, total: missing.count) }
            let embeddings = try store.loadPromptEmbeddings()
            guard !embeddings.isEmpty else {
                print("[Personalization] 沒有可用的分類文字向量（文字模型可能無法載入），暫不標記。")
                return nil
            }
            let tagger = MultiLabelTagger(catalog: catalog, promptEmbeddings: embeddings, thresholds: thresholds)
            cachedTagger = tagger
            return tagger
        } catch {
            print("[Personalization] 準備分類文字向量失敗: \(error)")
            return nil
        }
    }

    /// 使用者選取的大分類 + 興趣相關細分類（影響自動確認門檻）。
    private func preferenceContext(store: PersonalizationStore, userId: String) throws -> (Set<String>, Set<String>) {
        let preferred = try store.selectedTopLevelIds(userId: userId)
        let boosted = InterestRecommender.relatedNodeIds(selectedInterestIds: try store.interestIds(userId: userId), catalog: catalog)
        return (preferred, boosted)
    }

    private func tagSingleAssetOnQueue(assetId: String) throws {
        let (store, userId) = try requireUser()
        guard let tagger = preparedTaggerOnQueue(store: store) else {
            throw PersonalizationError.analysisFailed("分類文字向量尚未就緒")
        }
        guard let embedding = try store.embedding(forAssetId: assetId) else {
            throw PersonalizationError.analysisFailed("找不到照片向量")
        }
        let (preferred, boosted) = try preferenceContext(store: store, userId: userId)
        let text = (try? store.normalizedPhotoTexts(assetIds: [assetId]))?[assetId]
        var suggestions = tagger.suggestTags(for: embedding, preferredTopLevelIds: preferred, boostedNodeIds: boosted)
        if let feedback = feedbackOnQueue(store: store, userId: userId) {
            suggestions = feedback.apply(suggestions, imageEmbedding: embedding)
        }
        try store.applyAutoTags(userId: userId, assetId: assetId,
                                suggestions: withPeopleHints(withTextHints(suggestions, text: text, embedding: embedding,
                                                                           tagger: tagger, assetId: assetId), assetId: assetId),
                                taggerVersion: taggerVersion)
    }

    // MARK: 回憶草稿的畫面線索

    /// 每張照片最像的分類名稱（含沒達到確認門檻的），只用既有的照片向量，不重新分析照片。不可在主執行緒呼叫。
    func visualGuesses(for assetIds: [String], limit: Int = 3) -> [String: [String]] {
        guard !assetIds.isEmpty else { return [:] }
        let wanted = Set(assetIds)
        let embeddings = DatabaseManager.shared.cachedActiveEmbeddings().filter { wanted.contains($0.assetId) }
        return workQueue.sync {
            guard let store, let tagger = preparedTaggerOnQueue(store: store) else { return [:] }
            var result: [String: [String]] = [:]
            for item in embeddings {
                let names = tagger.topGuesses(for: item.embedding, limit: limit).compactMap { catalog.node($0.nodeId)?.nameZh }
                if !names.isEmpty { result[item.assetId] = names }
            }
            return result
        }
    }

    // MARK: 智慧搜尋建圖的線索

    /// 智慧搜尋建圖用：照片上的文字（沒有辨識過文字的照片不列，照一般照片建圖），
    /// 以及最像的幾個分類（中文名稱、相似度）。文字很多的照片（文件、收據、截圖）就不必請模型看圖。不可在主執行緒呼叫。
    /// 分類整理很久時（例如分類更新後重新分類上千張照片）最多等這麼久，不讓智慧分析一直卡在 0 張
    private static let searchHintWait: TimeInterval = 2

    func searchBuildHints(for assetIds: [String]) -> [String: (text: String, tags: [(name: String, score: Double)])] {
        guard !assetIds.isEmpty else { return [:] }
        let wanted = Set(assetIds)
        let embeddings = DatabaseManager.shared.cachedActiveEmbeddings().filter { wanted.contains($0.assetId) }
        // 以前用 workQueue.sync 等：分類整理在跑時（workQueue 一直被占用），智慧分析就停在 0 張等它整理完。
        // 改成最多等 searchHintWait 秒；等不到這批就不用文字線索（文字很多的照片改由模型看圖，結果一樣找得到）。
        let box = SearchHintBox()
        let done = DispatchSemaphore(value: 0)
        workQueue.async {
            defer { done.signal() }
            guard !box.isAbandoned, let store = self.store, let tagger = self.preparedTaggerOnQueue(store: store) else { return }
            var result: [String: (text: String, tags: [(name: String, score: Double)])] = [:]
            for item in embeddings {
                guard let text = (try? store.photoText(assetId: item.assetId)) ?? nil else { continue }
                let tags = tagger.topGuesses(for: MultiLabelTagger.normalized(item.embedding), limit: 3, minScore: 0.1, marginFromBest: 0.05)
                    .map { (name: self.displayName(for: $0.nodeId), score: Double($0.score)) }
                result[item.assetId] = (text, tags)
            }
            box.set(result)
        }
        if done.wait(timeout: .now() + Self.searchHintWait) == .timedOut {
            box.abandon()
            print("[抽象搜尋] 分類整理中，這批照片先不用文字線索")
            return [:]
        }
        return box.value
    }

    // MARK: 照片文字（OCR）線索

    /// 分類名稱與常見關鍵字（只算一次）
    private lazy var textHintTerms = PhotoTextHints.terms(for: catalog)
    /// 菜色類分類：菜單、筆記上的菜名不當作線索（只在 workQueue 上讀）
    private lazy var textHintDishIds = PhotoTextHints.dishNodeIds(for: catalog)

    /// 一次性：以前菜單、筆記上的菜名被當成「麵食」等菜色的待確認，照新規則重新整理這些照片。不可在主執行緒呼叫。
    func recheckDishTextCandidatesOnce() {
        let key = "recheckDishTextCandidates.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        workQueue.async {
            guard let context = try? self.requireUser(),
                  self.preparedTaggerOnQueue(store: context.store) != nil else { return }   // 分類還沒準備好：下次再做
            let dish = self.textHintDishIds
            let candidates = (try? context.store.candidateTags(userId: context.userId, limit: 1_000_000)) ?? []
            let ids = Array(Set(candidates.filter { dish.contains($0.nodeId) }.map(\.assetId)))
            var updated = 0
            for assetId in ids where (try? self.tagSingleAssetOnQueue(assetId: assetId)) != nil { updated += 1 }
            UserDefaults.standard.set(true, forKey: key)
            if updated > 0 {
                print("[文字辨識] 重新整理菜色待確認 \(updated) 張")
                self.postUpdate()
            }
        }
    }

    /// 照片向量的分類結果＋文字線索：兩者一致 → 確認；只有文字提到 → 待確認
    /// 看起來像紙張或卡片的照片，再由文字直接決定是票根、收據、證件、菜單或體組成
    /// 螢幕截圖（訂票頁面、海報截圖…）不會被當成票根、收據這些紙張類
    private func withTextHints(_ suggestions: [TagSuggestion], text: String?,
                               embedding: [Float], tagger: MultiLabelTagger, assetId: String) -> [TagSuggestion] {
        guard let text, !text.isEmpty else { return suggestions }
        return PhotoTextHints.combine(suggestions, normalizedText: text, terms: textHintTerms,
                                      looksLikePaper: tagger.looksLikePaper(embedding),
                                      isScreenshot: screenshotAssetIdsOnQueue().contains(assetId),
                                      dishNodeIds: textHintDishIds)
    }

    // MARK: 標記模式（協助訓練分類判斷器）

    /// 可以標記的分類：看畫面判斷的小分類（只能手動的不算）。
    /// 收據、票根平常要照片文字佐證；標記夠多、訓練出判斷器後，判斷器很確定時也會直接標上。
    var labelableNodes: [TaxonomyNode] {
        catalog.taggableNodes.filter { $0.level == 3 && $0.recognition == .visual }
    }

    /// 每個分類回答過幾張（是／不是），包含平常在「待確認」回答的
    func trainingLabelCounts() -> [String: (positive: Int, negative: Int)] {
        guard let context = try? requireUser() else { return [:] }
        return (try? context.store.trainingLabelCounts(userId: context.userId)) ?? [:]
    }

    /// 這個分類「最需要人判斷」的照片（還沒回答過的）：一半是最像的（多半是「是」），
    /// 一半是分數在門檻附近的（模型最沒把握）。只用既有照片向量，不重新分析照片。不可在主執行緒呼叫。
    func labelingCandidates(nodeId: String, limit: Int = 30) -> [String] {
        workQueue.sync {
            guard let context = try? requireUser(),
                  let tagger = preparedTaggerOnQueue(store: context.store) else { return [] }
            let answered = (try? context.store.answeredAssetIds(userId: context.userId, nodeId: nodeId)) ?? []
            var scored: [(id: String, score: Float)] = []
            for item in DatabaseManager.shared.cachedActiveEmbeddings() where !answered.contains(item.assetId) {
                if let score = tagger.nodeScore(nodeId, for: MultiLabelTagger.normalized(item.embedding)) {
                    scored.append((item.assetId, score))
                }
            }
            scored.sort { $0.score > $1.score }
            let pool = Array(scored.prefix(600))
            let top = pool.prefix(limit / 2)
            let threshold = tagger.defaultAcceptScore(for: nodeId)
            let taken = Set(top.map(\.id))
            let uncertain = pool.filter { !taken.contains($0.id) }
                .sorted { abs($0.score - threshold) < abs($1.score - threshold) }
                .prefix(limit - top.count)
            // 交錯排列：不會一整頁都是「是」或都是「不是」
            var result: [String] = []
            for index in 0..<max(top.count, uncertain.count) {
                if index < top.count { result.append(top[top.startIndex + index].id) }
                if index < uncertain.count { result.append(uncertain[uncertain.startIndex + index].id) }
            }
            return result
        }
    }

    /// 匯出所有回答（照片向量＋是／不是，不含照片）成 JSON 檔，給組員合併訓練。不可在主執行緒呼叫。
    func exportTrainingLabels(contributor: String) throws -> URL {
        let (store, userId) = try requireUser()
        let labels = try store.trainingLabels(userId: userId)
        guard !labels.isEmpty else { throw PersonalizationError.analysisFailed("還沒有標記任何照片") }
        let name = contributor.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try TrainingLabelExport.make(labels, contributor: name.isEmpty ? "未命名" : name,
                                                catalogVersion: catalog.catalogVersion)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let safeName = (name.isEmpty ? "未命名" : name).replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selfIE標記_\(safeName)_\(formatter.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: 人像：自拍用系統「自拍」相簿

    /// 自拍分類有沒有開啟（只讀目錄，不偵測人臉）
    private lazy var selfieAllowed: Bool = catalog.node(PeopleHints.selfie)?.enabledByDefault == true

    /// 系統「自拍」相簿裡的照片標成自拍；其他照片不標自拍
    private func withPeopleHints(_ suggestions: [TagSuggestion], assetId: String) -> [TagSuggestion] {
        PeopleHints.combine(suggestions, isSelfie: selfieAssetIdsOnQueue().contains(assetId),
                            selfieAllowed: selfieAllowed, maxAccepted: thresholds.maxAccepted)
    }

    /// iPhone「照片」App 內建「自拍」相簿的照片（只讀名單，不讀圖）。一分鐘內重用。只在 workQueue 上呼叫。
    private var selfieIdsCache: Set<String> = []
    private var selfieIdsLoadedAt: Date?

    private func selfieAssetIdsOnQueue() -> Set<String> {
        if let loaded = selfieIdsLoadedAt, Date().timeIntervalSince(loaded) < 60 { return selfieIdsCache }
        var ids = Set<String>()
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil)
            .enumerateObjects { collection, _, _ in
                PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
            }
        selfieIdsCache = ids
        selfieIdsLoadedAt = Date()
        return ids
    }

    /// 以前人臉偵測存下的資料（人臉數量與大小）：不再使用，清掉一次。只在 workQueue 上呼叫。
    private func clearOldFaceDataOnce() {
        let key = "clearedFaceData.v1"
        guard !UserDefaults.standard.bool(forKey: key), let store else { return }
        if let cleared = try? store.clearFaceData() {
            UserDefaults.standard.set(true, forKey: key)
            if cleared > 0 { print("[人像] 清除舊的人臉偵測資料 \(cleared) 筆") }
        }
    }

    /// 螢幕截圖的照片（只查 PhotoKit 的照片類型，不讀圖）。一分鐘內重用。只在 workQueue 上呼叫。
    private var screenshotIdsCache: Set<String> = []
    private var screenshotIdsLoadedAt: Date?

    private func screenshotAssetIdsOnQueue() -> Set<String> {
        if let loaded = screenshotIdsLoadedAt, Date().timeIntervalSince(loaded) < 60 { return screenshotIdsCache }
        let ids = Self.fetchScreenshotIds()
        screenshotIdsCache = ids
        screenshotIdsLoadedAt = Date()
        return ids
    }

    // MARK: 紙張與卡片的文字辨識

    /// 判斷「像不像紙張」用的標記器與結果快取（paperLock 保護）。
    /// 不使用 workQueue：分類進行中也能同時找出要辨識文字的照片，不必等分類全部跑完。
    private let paperLock = NSLock()
    private var paperTagger: MultiLabelTagger?
    private var paperTaggerVersion = ""
    /// 已確認「不像紙張」的照片（同一個分類版本只判斷一次）
    private var paperCheckedIds = Set<String>()

    /// 還沒辨識文字、而且看起來像紙張或卡片的照片（新的優先）。其他照片不會自動辨識文字。不可在主執行緒呼叫。
    func paperPhotosNeedingOCR(limit: Int) -> [String] {
        guard let store, limit > 0 else { return [] }
        let pending = (try? store.assetsPendingOCR(limit: 1_000_000)) ?? []
        guard !pending.isEmpty else { return [] }
        let embeddings = Dictionary(DatabaseManager.shared.cachedActiveEmbeddings().map { ($0.assetId, $0.embedding) },
                                    uniquingKeysWith: { first, _ in first })
        // 螢幕截圖不算紙張（訂機票的座位、海報截圖…），不自動辨識
        let screenshots = Self.fetchScreenshotIds()

        paperLock.lock()
        defer { paperLock.unlock() }
        if paperTagger == nil || paperTaggerVersion != baseTaggerVersion {
            // 分類文字向量還沒準備好（第一次使用、分類剛更新）就等下次
            guard let prompts = try? store.loadPromptEmbeddings(), !prompts.isEmpty,
                  ((try? store.promptsNeedingEmbedding()) ?? []).isEmpty else { return [] }
            paperTagger = MultiLabelTagger(catalog: catalog, promptEmbeddings: prompts, thresholds: thresholds)
            paperTaggerVersion = baseTaggerVersion
            paperCheckedIds = []
        }
        guard let tagger = paperTagger else { return [] }
        var result: [String] = []
        for id in pending where !paperCheckedIds.contains(id) {
            guard let embedding = embeddings[id] else { continue }
            if !screenshots.contains(id), tagger.looksLikePaper(embedding) {
                result.append(id)
                if result.count >= limit { break }
            } else {
                paperCheckedIds.insert(id)
            }
        }
        return result
    }

    /// 螢幕截圖的照片 ID（只查 PhotoKit 的照片類型，不讀圖）
    /// - Parameter withinDays: 只要最近幾天內拍的截圖；nil 是全部
    static func fetchScreenshotIds(withinDays: Int? = nil) -> Set<String> {
        let options = PHFetchOptions()
        let isScreenshot = NSPredicate(format: "(mediaSubtypes & %d) != 0", Int(PHAssetMediaSubtype.photoScreenshot.rawValue))
        if let withinDays, let since = Calendar.current.date(byAdding: .day, value: -withinDays, to: Date()) {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                isScreenshot, NSPredicate(format: "creationDate > %@", since as NSDate),
            ])
        } else {
            options.predicate = isScreenshot
        }
        var ids = Set<String>()
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }

    /// 新辨識出文字的照片：重新整理它們的自動標籤（手動標籤不受影響）
    func applyTextHints(assetIds: [String]) {
        guard !assetIds.isEmpty else { return }
        workQueue.async {
            var updated = 0
            for assetId in assetIds where (try? self.tagSingleAssetOnQueue(assetId: assetId)) != nil {
                updated += 1
            }
            if updated > 0 { self.postUpdate() }
        }
    }

    // MARK: 標籤操作

    func tags(for assetId: String) -> [PhotoTagRecord] {
        guard let context = try? requireUser() else { return [] }
        let store = context.store, userId = context.userId
        return (try? store.tags(userId: userId, assetId: assetId)) ?? []
    }

    func confirmTag(assetId: String, nodeId: String) throws {
        let (store, userId) = try requireUser()
        try store.addOrConfirmTag(userId: userId, assetId: assetId, nodeId: nodeId)
        postUpdate()
        feedbackChanged(nodeId: nodeId)   // 「是」→ 這個分類的新範例
        if CustomCategory.isCustomNodeId(nodeId) {
            // 「是」→ 新的範例（也是同作品其他角色的反例）：稍等一下再重新比對，連續回答多張時只算一次
            scheduleCustomMatching(nodeIds: Set(customSiblingFamily(of: nodeId)), delay: 2)
        }
    }

    func rejectTag(assetId: String, nodeId: String) throws {
        let (store, userId) = try requireUser()
        try store.rejectTag(userId: userId, assetId: assetId, nodeId: nodeId)
        feedbackChanged(nodeId: nodeId)   // 「不是」→ 這個分類的反例
        if LiveEventDetector.allNodeIds.contains(nodeId) || showsLiveEvents(for: nodeId) {
            LiveEventCenter.shared.exclude(assetId: assetId)   // 從演唱會／主題樂園場次移除
        }
        postUpdate()
        if CustomCategory.isCustomNodeId(nodeId) {
            scheduleCustomMatching(nodeIds: [nodeId], delay: 2)   // 「不是」→ 反例
        }
    }

    func themeAlbums(containing assetId: String) -> [ThemeAlbumMembership] {
        guard let context = try? requireUser() else { return [] }
        let store = context.store, userId = context.userId
        return (try? store.themeAlbums(containing: assetId, userId: userId)) ?? []
    }

    func analysisStatus(for assetId: String) -> (isRemoved: Bool, status: String?, lastError: String?) {
        guard let context = try? requireUser() else { return (false, nil, nil) }
        let store = context.store, userId = context.userId
        let removed = (try? store.isAIAnalysisRemoved(assetId: assetId)) ?? false
        let state = try? store.analysisStatus(userId: userId, assetId: assetId)
        return (removed, state?.status, state?.lastError)
    }

    // MARK: 瀏覽與跨分類搜尋

    /// 個人化分類的瀏覽資料：使用者選取的大分類排前面（族群相關的細分類優先），
    /// 未選取但有照片的大分類放在「其他分類」，照樣可以找到。
    func loadBrowseData() throws -> PersonalBrowseData {
        let (store, userId) = try requireUser()
        var tagMap = try store.acceptedTagMap(userId: userId)

        // 只顯示目前仍存在且可存取的照片（唯讀查詢，不清理任何資料）。
        let existing = DatabaseManager.shared.existingAssetIds(Array(tagMap.keys))
        tagMap = tagMap.filter { existing.contains($0.key) }
        // 演唱會場次的照片（排隊、場外、暗場）也算進「演唱會」相簿
        tagMap = tagMapIncludingLiveEvents(tagMap)

        let counts = PersonalizationStore.photoCounts(from: tagMap, catalog: catalog)
        let order = try store.recencyOrder()
        let interests = try store.interestIds(userId: userId)
        let enabled = try store.enabledNodeIds(userId: userId)
        let enabledTop = enabled.filter { catalog.node($0)?.level == 1 }
        let related = InterestRecommender.relatedNodeIds(selectedInterestIds: interests, catalog: catalog)
        let recommendedTop = Set(InterestRecommender.rankTopLevel(selectedInterestIds: interests, catalog: catalog)
            .filter(\.isRecommended).map(\.node.id))

        // 每個節點的封面：含該節點（或其子孫）的最新照片。
        var coverByNode: [String: (assetId: String, rank: Int64)] = [:]
        for (assetId, nodes) in tagMap {
            let rank = order[assetId] ?? -1
            var covered = Set<String>()
            for nodeId in nodes {
                covered.insert(nodeId)
                catalog.ancestors(of: nodeId).forEach { covered.insert($0.id) }
            }
            for nodeId in covered where (coverByNode[nodeId]?.rank ?? Int64.min) < rank {
                coverByNode[nodeId] = (assetId, rank)
            }
        }

        let orderedTop = InterestRecommender.browseOrder(enabledTopLevelIds: enabledTop, selectedInterestIds: interests, catalog: catalog)
        var enabledSections: [PersonalCategorySection] = []
        var otherSections: [PersonalCategorySection] = []

        for top in orderedTop {
            let items = catalog.descendants(of: top.id)
                .filter { $0.level == 3 }
                .compactMap { node -> PersonalCategoryItem? in
                    let count = counts[node.id] ?? 0
                    guard count > 0 else { return nil }
                    return PersonalCategoryItem(node: node, photoCount: count,
                                                coverAssetId: coverByNode[node.id]?.assetId,
                                                isRelatedToInterests: related.contains(node.id),
                                                isEnabled: enabled.contains(node.id))
                }
                .sorted { lhs, rhs in
                    let l = (lhs.isRelatedToInterests ? 0 : 1, lhs.isEnabled ? 0 : 1)
                    let r = (rhs.isRelatedToInterests ? 0 : 1, rhs.isEnabled ? 0 : 1)
                    if l != r { return l < r }
                    if lhs.photoCount != rhs.photoCount { return lhs.photoCount > rhs.photoCount }
                    return lhs.node.sortOrder < rhs.node.sortOrder
                }

            let section = PersonalCategorySection(
                node: top,
                isEnabled: enabledTop.contains(top.id),
                isRecommended: recommendedTop.contains(top.id),
                photoCount: counts[top.id] ?? 0,
                items: items
            )
            if section.isEnabled {
                enabledSections.append(section)
            } else if !items.isEmpty {
                otherSections.append(section)
            }
        }

        // 大分類由上到下依照片數量多到少排列；數量相同時維持推薦順序（sort 為穩定排序）。
        enabledSections.sort { $0.photoCount > $1.photoCount }
        otherSections.sort { $0.photoCount > $1.photoCount }

        let candidates = try store.candidateTags(userId: userId, limit: 1000)
            .filter { !CustomCategory.isCustomNodeId($0.nodeId) }   // IP 的待確認在 IP 相簿裡
        let existingCandidates = DatabaseManager.shared.existingAssetIds(candidates.map(\.assetId))

        return PersonalBrowseData(
            enabledSections: enabledSections,
            otherSections: otherSections,
            candidateCount: candidates.filter { existingCandidates.contains($0.assetId) }.count,
            categorizedPhotoCount: tagMap.count,
            hasSelectedCategories: !enabledTop.isEmpty,
            enabledCategoryCount: enabled.filter { catalog.node($0)?.level == 3 }.count
        )
    }

    /// 跨分類搜尋：同時符合所有選取分類的照片（每個分類包含其子分類）。
    /// 我的 IP 的作品相簿也包含底下角色的照片。
    func assetIds(matchingAll nodeIds: [String]) throws -> [String] {
        let (store, userId) = try requireUser()
        var ids: [String]
        if nodeIds.count == 1, let only = nodeIds.first, CustomCategory.isCustomNodeId(only) {
            let order = try store.recencyOrder()
            var seen = Set<String>()
            ids = []
            for nodeId in try customFamilyNodeIds(only, store: store, userId: userId) {
                for assetId in try store.assetIds(userId: userId, matchingAll: [nodeId]) where seen.insert(assetId).inserted {
                    ids.append(assetId)
                }
            }
            ids.sort { (order[$0] ?? -1, $0) > (order[$1] ?? -1, $1) }
        } else if LiveEventCenter.shared.currentMembership.isEmpty {
            ids = try store.assetIds(userId: userId, matchingAll: nodeIds)
        } else {
            // 合併演唱會場次的照片後再篩選（與 store.assetIds 相同的規則與排序）
            let tagMap = tagMapIncludingLiveEvents(try store.acceptedTagMap(userId: userId))
            let order = try store.recencyOrder()
            ids = PersonalizationStore.filter(tagMap: tagMap, matchingAll: nodeIds, catalog: catalog)
                .sorted { (order[$0] ?? -1, $0) > (order[$1] ?? -1, $1) }
        }
        let existing = DatabaseManager.shared.existingAssetIds(ids)
        return ids.filter { existing.contains($0) }
    }

    /// 主搜尋列：依標籤名稱（中英文）找照片。
    func assetIds(matchingTagText text: String) -> [String] {
        guard let context = try? requireUser() else { return [] }
        let store = context.store, userId = context.userId
        let ids = (try? store.assetIds(userId: userId, matchingTagText: text)) ?? []
        let existing = DatabaseManager.shared.existingAssetIds(ids)
        return ids.filter { existing.contains($0) }
    }

    /// - Parameter onlyCustom: 只看「我的 IP」的待確認（IP 頁使用）。
    func candidateTags(onlyCustom: Bool = false) throws -> [CandidateTag] {
        let (store, userId) = try requireUser()
        // IP 的待確認改在各 IP 相簿裡回答，主題頁的待確認只放分類目錄的題目
        let candidates = try store.candidateTags(userId: userId, limit: 1000)
            .filter { CustomCategory.isCustomNodeId($0.nodeId) == onlyCustom }
        let existing = DatabaseManager.shared.existingAssetIds(candidates.map(\.assetId))
        return candidates.filter { existing.contains($0.assetId) }
    }

    // MARK: 移除 AI 分析資料 / 重新分析

    /// 只移除這張照片的 AI 分析資料。原始照片、相簿、主題相簿、手動標籤一律保留。
    /// 完成（transaction 已提交）後才回傳成功；失敗會丟出錯誤且資料維持原狀。
    func removeAIAnalysis(assetId: String) async throws -> AIAnalysisRemovalReport {
        let (store, userId) = try requireUser()
        try verifyPhotoAccess()
        let report = try await runInBackground {
            try store.removeAIAnalysis(userId: userId, assetId: assetId)
        }
        DatabaseManager.shared.refreshFeatureCache(assetIds: [assetId])
        // 抽象語意搜尋的場景圖與向量（獨立的 AbstractSearch.sqlite）也一併刪除；之後不會再自動建圖
        await AbstractSearchCoordinator.shared.removeAnalysis(assetId: assetId)
        // 讓下一次標記使用最新狀態
        postUpdate()
        return report
    }

    /// 重新分析：重新「讀取」原始照片產生新向量與標籤。不會修改、移動或刪除原始照片。
    func reanalyze(assetId: String) async throws {
        let (store, userId) = try requireUser()
        try verifyPhotoAccess()
        guard PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject != nil else {
            throw PersonalizationError.photoNotAccessible
        }

        try await runInBackground {
            try store.prepareReanalysis(userId: userId, assetId: assetId)
        }
        DatabaseManager.shared.refreshFeatureCache(assetIds: [assetId])

        let embedded = await runInBackgroundNonThrowing {
            BackgroundSyncCoordinator.shared.reanalyzeAsset(assetId: assetId)
        }
        guard embedded else {
            try? store.markAnalysisFailed(userId: userId, assetId: assetId, reason: "無法讀取照片或模型推論失敗")
            postUpdate()
            throw PersonalizationError.analysisFailed("無法讀取照片或模型推論失敗。原始照片沒有任何變更，下次同步時會自動重試。")
        }

        try await runInBackground {
            try self.workQueue.sync { try self.tagSingleAssetOnQueue(assetId: assetId) }
        }
        postUpdate()
        scheduleCustomMatching(delay: 0.5)
        // 重新替這張照片建立抽象語意搜尋的場景圖（已建好的其他照片會跳過）
        AbstractSearchCoordinator.shared.scheduleBuild()
    }

    private func verifyPhotoAccess() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PersonalizationError.photoNotAccessible
        }
    }

    // MARK: 工具

    private func postUpdate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .personalizationUpdated, object: nil)
            NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
        }
    }

    private func runInBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func runInBackgroundNonThrowing<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

// MARK: - 我的 IP（用範例照片比對）

extension PersonalizationService {

    func customCategories(kind: CustomCategoryKind = .ip) -> [CustomCategory] {
        guard let context = try? requireUser() else { return [] }
        let list = (try? context.store.customCategories(userId: context.userId, kind: kind)) ?? []
        customLock.lock()
        for category in list { customNameCache[category.nodeId] = category.name }
        customLock.unlock()
        return list
    }

    /// 分類目錄或「我的 IP」的顯示名稱。
    func displayName(for nodeId: String) -> String {
        if let node = catalog.node(nodeId) { return node.nameZh }
        customLock.lock()
        let cached = customNameCache[nodeId]
        customLock.unlock()
        if let cached { return cached }
        if let context = try? requireUser(),
           let category = try? context.store.customCategory(nodeId: nodeId, userId: context.userId) {
            customLock.lock()
            customNameCache[nodeId] = category.name
            customLock.unlock()
            return category.name
        }
        return "已刪除的分類"
    }

    /// 例：「收藏與手作 › 收藏品」；我的 IP 顯示「IP」或「IP › 咒術迴戰」。
    func displayPath(for nodeId: String) -> String {
        if CustomCategory.isCustomNodeId(nodeId) {
            guard let context = try? requireUser(),
                  let category = try? context.store.customCategory(nodeId: nodeId, userId: context.userId),
                  let parentId = category.parentId else { return "專屬相簿" }
            return "專屬相簿 › " + displayName(for: CustomCategory.nodeId(kind: category.kind, id: parentId))
        }
        return catalog.ancestors(of: nodeId).reversed().map(\.nameZh).joined(separator: " › ")
    }

    /// 這個角色與同作品的其他角色（新增範例後，兄弟角色的反例也跟著變，需要一起重新比對）。
    fileprivate func customSiblingFamily(of nodeId: String) -> [String] {
        guard let context = try? requireUser(),
              let category = try? context.store.customCategory(nodeId: nodeId, userId: context.userId),
              let all = try? context.store.customCategories(userId: context.userId, kind: category.kind) else { return [nodeId] }
        return [nodeId] + category.siblings(in: all).map(\.nodeId)
    }

    /// 這個 IP 本身 + 底下的角色（作品相簿顯示全部）。
    fileprivate func customFamilyNodeIds(_ nodeId: String, store: PersonalizationStore, userId: String) throws -> [String] {
        guard let parsed = CustomCategory.parse(nodeId: nodeId) else { return [nodeId] }
        let children = try store.customCategories(userId: userId, kind: parsed.kind).filter { $0.parentId == parsed.id }
        return [nodeId] + children.map(\.nodeId)
    }

    /// 「IP」頁資料：每個作品（或團體）一組，作品相簿包含角色的照片；封面優先用使用者自選的照片。
    func loadIPBrowseData() throws -> IPBrowseData {
        let (store, userId) = try requireUser()
        let categories = try store.customCategories(userId: userId, kind: .ip)
        customLock.lock()
        for category in categories { customNameCache[category.nodeId] = category.name }
        customLock.unlock()
        guard !categories.isEmpty else { return .empty }

        var tagMap = try store.acceptedTagMap(userId: userId)
        let existing = DatabaseManager.shared.existingAssetIds(Array(tagMap.keys))
        tagMap = tagMap.filter { existing.contains($0.key) }
        let order = try store.recencyOrder()

        var members: [String: Set<String>] = [:]   // nodeId → 照片
        for (assetId, nodes) in tagMap {
            for nodeId in nodes where CustomCategory.isCustomNodeId(nodeId) { members[nodeId, default: []].insert(assetId) }
        }
        func summary(_ category: CustomCategory, photos: Set<String>) -> CustomCategorySummary {
            let cover: String?
            if let chosen = category.coverAssetId, photos.contains(chosen) {
                cover = chosen
            } else {
                cover = photos.max { (order[$0] ?? Int64.min, $0) < (order[$1] ?? Int64.min, $1) }
            }
            return CustomCategorySummary(category: category, photoCount: photos.count, coverAssetId: cover)
        }

        let candidates = try store.candidateTags(userId: userId, limit: 1000).filter { CustomCategory.isCustomNodeId($0.nodeId) }
        let existingCandidates = DatabaseManager.shared.existingAssetIds(candidates.map(\.assetId))
        var pending: [String: Int] = [:]
        for candidate in candidates where existingCandidates.contains(candidate.assetId) { pending[candidate.nodeId, default: 0] += 1 }

        let topLevel = categories.filter { category in
            category.parentId == nil || !categories.contains { $0.id == category.parentId }
        }
        let groups: [IPGroup] = topLevel.map { work in
            let children = categories.filter { $0.parentId == work.id }
            var all = members[work.nodeId] ?? []
            for child in children { all.formUnion(members[child.nodeId] ?? []) }
            let characters = children.map { child -> CustomCategorySummary in
                var item = summary(child, photos: members[child.nodeId] ?? [])
                item.candidateCount = pending[child.nodeId] ?? 0
                return item
            }
            .sorted { ($0.photoCount, $1.category.name) > ($1.photoCount, $0.category.name) }
            var workSummary = summary(work, photos: all)
            workSummary.candidateCount = (pending[work.nodeId] ?? 0) + characters.reduce(0) { $0 + $1.candidateCount }
            return IPGroup(work: workSummary, characters: characters)
        }
        .sorted { ($0.work.photoCount, $1.work.category.name) > ($1.work.photoCount, $0.work.category.name) }

        return IPBrowseData(groups: groups, candidateCount: pending.values.reduce(0, +))
    }

    /// 從 IP 相簿移除照片：這個 IP（以及作品底下有這張照片的角色）都記為「不是」，之後不會再自動加回。
    func removeFromCustomCategory(assetId: String, nodeId: String) throws {
        let (store, userId) = try requireUser()
        let accepted = Set(try store.tags(userId: userId, assetId: assetId).filter { $0.status == .accepted }.map(\.nodeId))
        var touched: Set<String> = []
        for member in try customFamilyNodeIds(nodeId, store: store, userId: userId) where member == nodeId || accepted.contains(member) {
            try store.rejectTag(userId: userId, assetId: assetId, nodeId: member)
            touched.insert(member)
        }
        postUpdate()
        scheduleCustomMatching(nodeIds: touched, delay: 2)
    }

    /// 設定 IP 相簿封面（nil 代表改回自動：最新的一張）。
    func setCustomCover(nodeId: String, assetId: String?) throws {
        let (store, userId) = try requireUser()
        guard let parsed = CustomCategory.parse(nodeId: nodeId) else { throw PersonalizationError.unknownNode(nodeId) }
        try store.setCustomCategoryCover(userId: userId, categoryId: parsed.id, assetId: assetId)
        postUpdate()
    }

    /// 一次建立角色（必填）與所屬作品（選填）：
    /// - 只填角色 → 建立獨立的 IP（最上層）。
    /// - 角色 + 作品 → 作品已存在就在底下建立角色；不存在就先用同一組範例建立作品，再建立角色。
    /// 名稱先全部檢查完才開始寫入，避免只建立一半。
    func createIP(character: String, work: String?, exampleAssetIds: [String]) async throws -> CustomCategory {
        let (store, userId) = try requireUser()
        let characterName = character.trimmingCharacters(in: .whitespacesAndNewlines)
        let workName = work?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !characterName.isEmpty else { throw PersonalizationError.invalidCategoryName }

        func same(_ a: String, _ b: String) -> Bool {
            a.compare(b, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
        }
        let all = try store.customCategories(userId: userId, kind: .ip)
        if all.contains(where: { same($0.name, characterName) }) {
            throw PersonalizationError.duplicateCategoryName(characterName)
        }
        guard let workName else {
            return try await createIP(name: characterName, exampleAssetIds: exampleAssetIds, parentId: nil)
        }
        if same(characterName, workName) { throw PersonalizationError.duplicateCategoryName(characterName) }
        let existingWork = all.first { $0.parentId == nil && same($0.name, workName) }
        if existingWork == nil && all.contains(where: { same($0.name, workName) }) {
            throw PersonalizationError.duplicateCategoryName(workName)   // 同名的是某個角色，不能當作品
        }
        let parent: CustomCategory
        if let existingWork {
            parent = existingWork
        } else {
            parent = try await createIP(name: workName, exampleAssetIds: exampleAssetIds, parentId: nil)
        }
        return try await createIP(name: characterName, exampleAssetIds: exampleAssetIds, parentId: parent.id)
    }

    /// 這個 IP（作品頁含底下角色）的待確認照片，直接顯示在相簿裡。
    func customCandidates(forFamilyOf nodeId: String) throws -> [CandidateTag] {
        let (store, userId) = try requireUser()
        let family: Set<String> = CustomCategory.isCustomNodeId(nodeId)
            ? Set(try customFamilyNodeIds(nodeId, store: store, userId: userId))
            : Set([nodeId] + catalog.descendants(of: nodeId).map(\.id))   // 主題：大分類包含底下的小分類
        // 每張照片最多一個待確認；照片多的時候全部待確認會超過 1,000 筆，這裡不設上限，避免某些相簿的題目被截掉
        let candidates = try store.candidateTags(userId: userId, limit: 1_000_000).filter { family.contains($0.nodeId) }
        let existing = DatabaseManager.shared.existingAssetIds(candidates.map(\.assetId))
        return candidates.filter { existing.contains($0.assetId) }
    }

    /// 建立「我的 IP」：範例照片若還沒掃描，先以唯讀方式讀取照片產生向量（不修改原始照片）。
    func createIP(name: String, exampleAssetIds: [String], parentId: String? = nil) async throws -> CustomCategory {
        let (store, userId) = try requireUser()
        let ids = Array(Set(exampleAssetIds))
        let missing = try await runInBackground { try ids.filter { try store.embedding(forAssetId: $0) == nil } }
        if !missing.isEmpty {
            try verifyPhotoAccess()
            _ = await runInBackgroundNonThrowing {
                missing.map { BackgroundSyncCoordinator.shared.reanalyzeAsset(assetId: $0) }
            }
        }
        let category = try await runInBackground {
            try store.createCustomCategory(userId: userId, kind: .ip, name: name, exampleAssetIds: ids, parentId: parentId)
        }
        customLock.lock()
        customNameCache[category.nodeId] = category.name
        customLock.unlock()
        postUpdate()
        // 新角色：比對它自己；它的作品從此改由角色合集組成，順便清掉作品原本的待確認
        var affected: Set<String> = [category.nodeId]
        if let parentId { affected.insert(CustomCategory.nodeId(kind: .ip, id: parentId)) }
        scheduleCustomMatching(nodeIds: affected, delay: 0)
        return category
    }

    func renameCustomCategory(id: String, name: String) throws {
        let (store, userId) = try requireUser()
        try store.renameCustomCategory(userId: userId, categoryId: id, name: name)
        customLock.lock()
        customNameCache = customNameCache.filter { !$0.key.hasSuffix(":" + id) }
        customLock.unlock()
        postUpdate()
    }

    /// 刪除「我的 IP」：只刪除 App 的分類資料，照片與相簿都不受影響。
    func deleteCustomCategory(id: String) throws {
        let (store, userId) = try requireUser()
        try store.deleteCustomCategory(userId: userId, categoryId: id)
        customLock.lock()
        customNameCache = customNameCache.filter { !$0.key.hasSuffix(":" + id) }
        customLock.unlock()
        postUpdate()
        // 作品的最後一個角色被刪掉、或作品被刪掉讓角色變成獨立：重新決定誰要自己比對
        scheduleCustomMatching(delay: 0.5)
    }

    /// 排程重新比對（nodeIds 為 nil 代表全部）。多次呼叫會合併。
    func scheduleCustomMatching(nodeIds: Set<String>? = nil, delay: TimeInterval = 0.5) {
        customLock.lock()
        if let nodeIds { customPendingIds.formUnion(nodeIds) } else { customPendingAll = true }
        let needsSchedule = !customScheduled
        customScheduled = true
        customLock.unlock()
        guard needsSchedule else { return }

        customQueue.asyncAfter(deadline: .now() + delay) {
            self.customLock.lock()
            let all = self.customPendingAll
            let ids = self.customPendingIds
            self.customPendingAll = false
            self.customPendingIds = []
            self.customScheduled = false
            self.customLock.unlock()
            self.runCustomMatchingOnQueue(nodeIds: all ? nil : ids)
        }
    }

    private func runCustomMatchingOnQueue(nodeIds: Set<String>?) {
        guard let context = try? requireUser() else { return }
        let store = context.store, userId = context.userId
        do {
            let all = try store.customCategories(userId: userId)
            let categories = all.filter { nodeIds == nil || nodeIds!.contains($0.nodeId) }
            guard !categories.isEmpty else { return }

            // 有角色的作品不自己比對：作品相簿＝所有角色照片的合集，角色回答「是」就自動算進作品，
            // 不必在作品再判斷一次。清掉它先前的自動結果（含待確認），手動加入的照片保留。
            let worksWithCharacters = Set(all.compactMap(\.parentId))
            var total = 0
            for work in categories where worksWithCharacters.contains(work.id) {
                try store.replaceAutoMatches(userId: userId, nodeId: work.nodeId, matches: [])
            }
            let toMatch = categories.filter { !worksWithCharacters.contains($0.id) }
            guard !toMatch.isEmpty else { postUpdate(); return }

            let photos = DatabaseManager.shared.cachedActiveEmbeddings()
            let vectors = Dictionary(photos.map { ($0.assetId, $0.embedding) }, uniquingKeysWith: { first, _ in first })
            let screenshotIds = Self.fetchScreenshotIds()
            var examplesByNode: [String: (positives: [String], negatives: [String])] = [:]
            for category in all {
                examplesByNode[category.nodeId] = try store.customExamples(userId: userId, nodeId: category.nodeId)
            }
            for category in toMatch {
                let examples = examplesByNode[category.nodeId] ?? (positives: [], negatives: [])
                // 同作品其他角色的範例 = 額外反例（扣掉同時也是自己範例的照片，例如兩人合照）
                let own = Set(examples.positives)
                let siblingExamples = category.siblings(in: all)
                    .flatMap { examplesByNode[$0.nodeId]?.positives ?? [] }
                    .filter { !own.contains($0) }
                var matches = ReferenceMatcher.match(
                    positives: examples.positives.compactMap { vectors[$0] },
                    negatives: (examples.negatives + siblingExamples).compactMap { vectors[$0] },
                    photos: photos,
                    excluded: Set(examples.positives + examples.negatives)
                )
                // 照片中的文字出現 IP／角色名稱（例如周邊包裝、展覽看板）：
                // 向量也認為像 → 確認；只有文字 → 待確認。範例照片（含「不是」）不重複詢問。
                // 截圖（聊天、網頁提到名稱）只有文字時不列入待確認
                if PhotoTextHints.normalize(category.name).count >= 2,
                   let textHits = try? store.assetIds(matchingPhotoText: category.name, limit: 500) {
                    let excluded = Set(examples.positives + examples.negatives)
                    for assetId in textHits where !excluded.contains(assetId) {
                        if let index = matches.firstIndex(where: { $0.assetId == assetId }) {
                            if matches[index].status == .candidate {
                                matches[index] = ReferenceMatch(assetId: assetId, score: matches[index].score, status: .accepted)
                            }
                        } else if !screenshotIds.contains(assetId) {
                            matches.append(ReferenceMatch(assetId: assetId, score: 0.75, status: .candidate))
                        }
                    }
                }
                total += try store.replaceAutoMatches(userId: userId, nodeId: category.nodeId, matches: matches)
            }
            print("[我的 IP] 比對完成：\(toMatch.count) 個 IP、\(photos.count) 張照片、\(total) 筆結果")
            postUpdate()
        } catch {
            print("[我的 IP] 比對失敗: \(error)")
        }
    }
}


// MARK: - 演唱會場次（同一個晚上、同一個場館）

extension Notification.Name {
    /// 演唱會場次重新計算完成，或場館名稱查到了
    static let liveEventsUpdated = Notification.Name("LiveEventsUpdated")
}

/// 在背景偵測演唱會場次並快取結果。只讀取照片向量、拍攝時間與定位，不寫入照片或系統相簿；
/// 場次成員只放在記憶體中合併到「演唱會」相簿，不寫進 PhotoTags。
final class LiveEventCenter {
    static let shared = LiveEventCenter()

    fileprivate let queue = DispatchQueue(label: "com.photoai.personalization.liveevents", qos: .utility)
    private let lock = NSLock()
    private var events: [DetectedLiveEvent] = []
    private var membership: [String: String] = [:]     // assetId → 場次的分類（concert…）
    private var computedAt: Date?
    private var running = false
    private var rerunRequested = false
    private let minimumInterval: TimeInterval = 5 * 60

    /// 起點判斷的快取（只在 queue 上讀寫）：照片向量不會變，所以每張只算一次。依場次種類（live-、park-）分開。
    fileprivate var seedCache: [String: [String: (nodeId: String, score: Float)]] = [:]
    fileprivate var scoredIds = Set<String>()
    fileprivate var seedCacheVersion = ""
    /// 比較像展覽、周邊的照片（依場次種類分開）：自動標上的演唱會標籤不當起點
    fileprivate var rivalCache: [String: Set<String>] = [:]
    /// 拍攝時間、定位、是否為截圖、是否像存下來的照片（只在 queue 上讀寫）：這些資料幾乎不會變，
    /// 每次只補讀新照片；每 30 分鐘整批重讀一次，跟上被刪除或改過日期的照片。
    fileprivate var photoInfoCache: [String: (date: Date, lat: Double?, lon: Double?, isScreenshot: Bool, isSaved: Bool)] = [:]
    fileprivate var photoInfoLoadedAt: Date?

    private let venueDefaultsKey = "liveEventVenueNames"
    /// 場館所在的城市（第一級行政區，例如「臺北市」「東京都」），追星足跡用
    private let venueCityDefaultsKey = "liveEventVenueCities"
    private let geocoder = CLGeocoder()

    var currentEvents: [DetectedLiveEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// assetId → 分類；用來把場次照片合併進「演唱會」等相簿
    var currentMembership: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return membership
    }

    func refreshIfNeeded(force: Bool = false) {
        lock.lock()
        if running {
            if force { rerunRequested = true }
            lock.unlock(); return
        }
        let fresh = computedAt.map { Date().timeIntervalSince($0) < minimumInterval } ?? false
        if fresh && !force { lock.unlock(); return }
        running = true
        lock.unlock()

        queue.async { self.runOnQueue() }
    }

    private func runOnQueue() {
        let started = Date()
        let result = PersonalizationService.shared.computeLiveEvents(center: self)
        lock.lock()
        if let result {
            events = result
            var map: [String: String] = [:]
            for event in result { for id in event.assetIds { map[id] = event.kindNodeId } }
            membership = map
            computedAt = Date()
        }
        let again = rerunRequested
        rerunRequested = false
        running = again
        lock.unlock()

        if let result {
            print("[演唱會] \(result.count) 場，耗時 \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .liveEventsUpdated, object: nil)
                NotificationCenter.default.post(name: .personalizationUpdated, object: nil)
            }
            resolveVenueNames(for: result)
        }
        if again { queue.async { self.runOnQueue() } }
    }

    /// 使用者在相簿裡移除某張照片（按「不是演唱會」）：立刻從場次移除，下次重算也會排除。
    func exclude(assetId: String) {
        lock.lock()
        membership[assetId] = nil
        events = events.map { event in
            guard event.assetIds.contains(assetId) else { return event }
            return DetectedLiveEvent(id: event.id, startDate: event.startDate, endDate: event.endDate,
                                     assetIds: event.assetIds.filter { $0 != assetId },
                                     seedIds: event.seedIds.filter { $0 != assetId },
                                     kindNodeId: event.kindNodeId, latitude: event.latitude, longitude: event.longitude,
                                     coverAssetId: event.coverAssetId == assetId
                                        ? (event.assetIds.first { $0 != assetId } ?? event.coverAssetId) : event.coverAssetId)
        }
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .liveEventsUpdated, object: nil)
        }
        refreshIfNeeded(force: true)
    }

    func reset() {
        lock.lock()
        events = []
        membership = [:]
        computedAt = nil
        lock.unlock()
    }

    // MARK: 場館名稱

    private static func venueKey(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.3f,%.3f", lat, lon)   // 約 100 公尺
    }

    func venueName(for event: DetectedLiveEvent) -> String? {
        guard let lat = event.latitude, let lon = event.longitude else { return nil }
        let names = UserDefaults.standard.dictionary(forKey: venueDefaultsKey) as? [String: String]
        return names?[Self.venueKey(lat, lon)]
    }

    func venueCity(for event: DetectedLiveEvent) -> String? {
        guard let lat = event.latitude, let lon = event.longitude else { return nil }
        let cities = UserDefaults.standard.dictionary(forKey: venueCityDefaultsKey) as? [String: String]
        guard let city = cities?[Self.venueKey(lat, lon)], !city.isEmpty else { return nil }
        return city
    }

    /// 只對還沒有名稱或城市的場次查一次（場館名稱優先，例如「臺北小巨蛋」；查不到時用行政區）。在 queue 上執行。
    private func resolveVenueNames(for events: [DetectedLiveEvent]) {
        var names = UserDefaults.standard.dictionary(forKey: venueDefaultsKey) as? [String: String] ?? [:]
        var cities = UserDefaults.standard.dictionary(forKey: venueCityDefaultsKey) as? [String: String] ?? [:]
        var changed = false
        for event in events {
            guard let lat = event.latitude, let lon = event.longitude else { continue }
            let key = Self.venueKey(lat, lon)
            guard names[key] == nil || cities[key] == nil else { continue }
            Thread.sleep(forTimeInterval: 1.5)   // 和地區查詢共用系統的頻率限制，放慢一點
            let semaphore = DispatchSemaphore(value: 0)
            var resolved: String?
            var resolvedCity: String?
            geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon),
                                            preferredLocale: Locale(identifier: "zh_Hant_TW")) { placemarks, _ in
                defer { semaphore.signal() }
                guard let placemark = placemarks?.first else { return }
                // 查到地點但沒有城市時存空字串，之後不再重查
                resolvedCity = [placemark.administrativeArea, placemark.locality]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                if let venue = placemark.areasOfInterest?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !venue.isEmpty {
                    resolved = venue
                } else {
                    let area = [placemark.locality, placemark.subLocality]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined()
                    resolved = area.isEmpty ? nil : area
                }
            }
            _ = semaphore.wait(timeout: .now() + 15)
            if names[key] == nil, let resolved {
                names[key] = resolved
                changed = true
            }
            if let resolvedCity {
                cities[key] = resolvedCity
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(names, forKey: venueDefaultsKey)
            UserDefaults.standard.set(cities, forKey: venueCityDefaultsKey)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .liveEventsUpdated, object: nil)
            }
        }
    }
}

extension PersonalizationService {

    /// 偵測演唱會場次（在 LiveEventCenter.queue 上呼叫）。回傳 nil 代表無法計算。
    fileprivate func computeLiveEvents(center: LiveEventCenter) -> [DetectedLiveEvent]? {
        guard let context = try? requireUser() else { return nil }
        let store = context.store, userId = context.userId
        do {
            let tagged = try store.taggedAssetIds(userId: userId, taggerVersionPrefix: baseTaggerVersion)
            guard !tagged.isEmpty else { return [] }
            let embeddings = DatabaseManager.shared.cachedActiveEmbeddings().filter { !$0.embedding.isEmpty }
            let prompts = try store.loadPromptEmbeddings()
            guard !prompts.isEmpty else { return nil }

            // 已有的標記：確認或待確認 → 起點；使用者按過「不是」→ 不算起點，也不收進那一種場次
            let profiles = LiveEventProfile.all
            var tagSeeds: [String: [String: String]] = [:]      // 場次種類 → assetId → 分類
            var rejected: [String: Set<String>] = [:]           // 場次種類 → 按過「不是」的照片
            var autoTagged: [String: Set<String>] = [:]         // 場次種類 → 自動標上（不是使用者確認）的照片
            for row in try store.tagStatuses(userId: userId, nodeIds: LiveEventDetector.allNodeIds) {
                for profile in profiles where profile.nodeIds.contains(row.nodeId) {
                    switch row.status {
                    case .rejected where row.isManual:
                        rejected[profile.idPrefix, default: []].insert(row.assetId)
                    case .accepted, .candidate:
                        // 同一張有舞台類也有應援物時，用舞台類
                        if tagSeeds[profile.idPrefix]?[row.assetId] == nil || profile.stageNodeIds.contains(row.nodeId) {
                            tagSeeds[profile.idPrefix, default: [:]][row.assetId] = row.nodeId
                        }
                        if !row.isManual { autoTagged[profile.idPrefix, default: []].insert(row.assetId) }
                    default:
                        break
                    }
                }
            }

            // 用文字向量找起點（每張照片只算一次）
            if center.seedCacheVersion != baseTaggerVersion {
                center.seedCache = [:]
                center.rivalCache = [:]
                center.scoredIds = []
                center.seedCacheVersion = baseTaggerVersion
            }
            let unscored = embeddings.filter { tagged.contains($0.assetId) && !center.scoredIds.contains($0.assetId) }
            if !unscored.isEmpty {
                // 全部描述排成矩陣只建一次，每張照片一次矩陣運算（各種場次共用）
                let matrix = PromptMatrix(prompts)
                for item in unscored {
                    let embedding = MultiLabelTagger.normalized(item.embedding)
                    for profile in profiles {
                        if let seed = LiveEventDetector.seed(for: embedding, matrix: matrix, profile: profile) {
                            center.seedCache[profile.idPrefix, default: [:]][item.assetId] = seed
                        }
                        if LiveEventDetector.isRival(embedding, matrix: matrix, profile: profile) {
                            center.rivalCache[profile.idPrefix, default: []].insert(item.assetId)
                        }
                    }
                    center.scoredIds.insert(item.assetId)
                }
            }

            // 拍攝時間、定位與是否為螢幕截圖：只讀取 PhotoKit 的中繼資料（有快取，只補讀新照片）
            let ids = embeddings.map(\.assetId)
            let stale = center.photoInfoLoadedAt.map { Date().timeIntervalSince($0) > 30 * 60 } ?? true
            if stale {
                center.photoInfoCache = [:]
                center.photoInfoLoadedAt = Date()
            }
            let missing = ids.filter { center.photoInfoCache[$0] == nil }
            var start = 0
            while start < missing.count {
                let chunk = Array(missing[start..<min(start + 500, missing.count)])
                PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil).enumerateObjects { asset, _, _ in
                    guard let date = asset.creationDate else { return }
                    let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
                    let isSaved = PhotoOrigin.looksSaved(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                                                         hasLocation: asset.location != nil,
                                                         isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                                                         isScreenshot: isScreenshot)
                    center.photoInfoCache[asset.localIdentifier] = (date, asset.location?.coordinate.latitude,
                                                                    asset.location?.coordinate.longitude,
                                                                    isScreenshot, isSaved)
                }
                start += 500
            }
            let info = center.photoInfoCache

            var events: [DetectedLiveEvent] = []
            for profile in profiles {
                let seeds = center.seedCache[profile.idPrefix] ?? [:]
                let tags = tagSeeds[profile.idPrefix] ?? [:]
                let excluded = rejected[profile.idPrefix] ?? []
                // 自動標上、但比較像展覽或周邊的照片不當起點（例如動漫特展的角色看板）
                let blocked = (autoTagged[profile.idPrefix] ?? []).intersection(center.rivalCache[profile.idPrefix] ?? [])
                let photos: [EventPhoto] = ids.compactMap { id in
                    guard !excluded.contains(id), let meta = info[id] else { return nil }
                    var photo = EventPhoto(id: id, date: meta.date, latitude: meta.lat, longitude: meta.lon,
                                           isScreenshot: meta.isScreenshot, isSaved: meta.isSaved)
                    if let scored = seeds[id] {
                        photo.seedNodeId = tags[id].map { profile.stageNodeIds.contains($0) ? $0 : scored.nodeId } ?? scored.nodeId
                        photo.seedScore = scored.score
                    } else if let node = tags[id], !blocked.contains(id) {
                        photo.seedNodeId = node
                        photo.seedScore = 0
                    }
                    return photo
                }
                events += LiveEventDetector.detect(photos: photos, profile: profile)
            }
            return events.sorted { ($0.startDate, $0.id) > ($1.startDate, $1.id) }
        } catch {
            print("[演唱會] 偵測失敗: \(error)")
            return nil
        }
    }

    /// 屬於某個分類（例如「演唱會」或上層「音樂與表演」）的場次，新到舊；用和旅遊相簿相同的相簿畫面顯示。
    func liveEventAlbums(for nodeId: String) -> [MetadataAlbumSummary] {
        let events = LiveEventCenter.shared.currentEvents.filter { event in
            event.kindNodeId == nodeId || catalog.ancestors(of: event.kindNodeId).contains { $0.id == nodeId }
        }
        guard !events.isEmpty else { return [] }
        let existing = DatabaseManager.shared.existingAssetIds(events.flatMap(\.assetIds))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy/M/d（EEEEE）"

        return events.compactMap { event in
            let ids = event.assetIds.filter { existing.contains($0) }
            guard !ids.isEmpty else { return nil }
            let kind = catalog.node(event.kindNodeId)?.nameZh ?? "演唱會"
            let venue = LiveEventCenter.shared.venueName(for: event)
            let subtitle = [formatter.string(from: event.startDate), venue == nil ? nil : kind, "\(ids.count) 張"]
                .compactMap { $0 }
                .joined(separator: "・")
            return MetadataAlbumSummary(id: event.id,
                                        title: venue ?? kind,
                                        subtitle: subtitle,
                                        coverAssetId: ids.contains(event.coverAssetId) ? event.coverAssetId : ids.first,
                                        photoCount: ids.count,
                                        primaryAssetIds: ids,
                                        otherAssetIds: [])
        }
    }

    /// 場次目前的照片；場次已不存在時回傳 nil。
    func liveEventAssetIds(eventId: String) -> [String]? {
        LiveEventCenter.shared.currentEvents.first { $0.id == eventId }?.assetIds
    }

    /// 「不屬於這場」：記為使用者拒絕該演唱會分類（只寫 App 自己的標記資料），之後不會再被收進任何場次。
    func removeFromLiveEvent(assetId: String, eventId: String) {
        let kind = LiveEventCenter.shared.currentEvents.first { $0.id == eventId }?.kindNodeId ?? "concert"
        do {
            try rejectTag(assetId: assetId, nodeId: kind)
        } catch {
            print("[演唱會] 移除失敗: \(error)")
        }
    }

    // MARK: 興趣紀錄（健身日曆、觀影與看展…）

    /// 要顯示的興趣紀錄：選過的興趣；沒選時取照片最多的前三個。
    func interestTrackers() -> [InterestTracker] {
        guard let context = try? requireUser() else { return [] }
        let interests = (try? context.store.interestIds(userId: context.userId)) ?? []
        let counts = (try? context.store.photoCountsByNode(userId: context.userId)) ?? [:]
        return InterestTrackers.trackers(selectedInterestIds: interests, photoCounts: counts, catalog: catalog)
    }

    /// 每個興趣紀錄的照片與拍攝日期（只讀取照片資訊）；身體相關的照片另外列出，月報預設不放。
    /// 標籤與照片庫各只讀一次。會讀資料庫與照片庫，請在背景執行。
    func interestTrackerPhotos(_ trackers: [InterestTracker]) -> [String: (dates: [String: Date], sensitive: Set<String>)] {
        guard !trackers.isEmpty, let context = try? requireUser(),
              let raw = try? context.store.acceptedTagMap(userId: context.userId) else { return [:] }
        let tagMap = tagMapIncludingLiveEvents(raw)
        // 旅程與常去地點（住家、學校、公司）：旅行足跡用旅程、探店不算常去地點附近的照片
        let needsTrips = trackers.contains { $0.usesTrips || $0.skipsRoutinePlaces }
        let trips = needsTrips ? DatabaseManager.shared.recentTripDetection() : nil

        var idsByTracker: [String: Set<String>] = [:]
        var all = Set<String>()
        for tracker in trackers {
            let ids: Set<String>
            if tracker.usesTrips {
                ids = Set((trips?.trips ?? []).flatMap(\.allAssetIds))
            } else {
                ids = InterestTrackers.assetIds(tagMap: tagMap, tracker: tracker, catalog: catalog)
            }
            idsByTracker[tracker.id] = ids
            all.formUnion(ids)
        }
        var dates: [String: Date] = [:]
        var routine = Set<String>()   // 在常去地點附近拍的
        let anchors = trips?.anchors ?? []
        if !all.isEmpty {
            // 已刪除的照片抓不到，自然不會出現在日曆上
            PHAsset.fetchAssets(withLocalIdentifiers: Array(all), options: nil).enumerateObjects { asset, _, _ in
                // 螢幕截圖（IG 美食貼文、訂票頁面…）不是自己去做的事，不算進紀錄
                guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
                if let date = asset.creationDate { dates[asset.localIdentifier] = date }
                if !anchors.isEmpty, let location = asset.location,
                   RoutinePlaces.isNear(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                        anchors: anchors) {
                    routine.insert(asset.localIdentifier)
                }
            }
        }
        var result: [String: (dates: [String: Date], sensitive: Set<String>)] = [:]
        for tracker in trackers {
            let ids = idsByTracker[tracker.id] ?? []
            result[tracker.id] = (dates.filter { ids.contains($0.key) && !(tracker.skipsRoutinePlaces && routine.contains($0.key)) },
                                  InterestTrackers.sensitiveAssetIds(tagMap: tagMap, tracker: tracker, catalog: catalog))
        }
        return result
    }

    /// 有任一指定標籤（已確認）的照片。智慧搜尋用來把截圖、文件這類照片排到最後分析。
    func assetIds(withAnyAcceptedTag tags: Set<String>) -> Set<String> {
        guard let context = try? requireUser(),
              let map = try? context.store.acceptedTagMap(userId: context.userId) else { return [] }
        return Set(map.compactMap { !$0.value.isDisjoint(with: tags) ? $0.key : nil })
    }

    /// 這個分類頁面是否需要顯示「場次」（演唱會類及其上層）。
    func showsLiveEvents(for nodeId: String) -> Bool {
        let stages = LiveEventDetector.allStageNodeIds
        return stages.contains(nodeId)
            || stages.contains { stage in catalog.ancestors(of: stage).contains { $0.id == nodeId } }
    }

    /// 場次相簿（演唱會 live-…、主題樂園 park-…）
    static func isLiveEventAlbumId(_ id: String) -> Bool {
        LiveEventProfile.profile(forEventId: id) != nil
    }

    /// 已確認的標記，再加上演唱會場次的照片（只在記憶體中合併，不寫入資料庫）。
    fileprivate func tagMapIncludingLiveEvents(_ tagMap: [String: Set<String>]) -> [String: Set<String>] {
        let membership = LiveEventCenter.shared.currentMembership
        guard !membership.isEmpty else { return tagMap }
        var merged = tagMap
        let existing = DatabaseManager.shared.existingAssetIds(Array(membership.keys))
        for (assetId, nodeId) in membership where existing.contains(assetId) {
            merged[assetId, default: []].insert(nodeId)
        }
        return merged
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// searchBuildHints 的結果（在 workQueue 上寫、呼叫端讀）；等太久放棄後，排在後面的那次就不用再算
private final class SearchHintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: [String: (text: String, tags: [(name: String, score: Double)])] = [:]
    private var abandoned = false

    var isAbandoned: Bool { lock.lock(); defer { lock.unlock() }; return abandoned }
    var value: [String: (text: String, tags: [(name: String, score: Double)])] { lock.lock(); defer { lock.unlock() }; return result }
    func set(_ value: [String: (text: String, tags: [(name: String, score: Double)])]) { lock.lock(); result = value; lock.unlock() }
    func abandon() { lock.lock(); abandoned = true; lock.unlock() }
}

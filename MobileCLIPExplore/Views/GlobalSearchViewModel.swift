import SwiftUI
import CoreML

enum SemanticPhotoSearch {
    // 整個 App 生命週期只初始化一次文字模型，避免重複載入造成搜尋延遲。
    private static let textModel: mobileclip_s2_text? = {
        try? mobileclip_s2_text(configuration: MLModelConfiguration())
    }()

    static func search(query: String) async -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // 照片向量模型只看得懂英文：中文先翻成英文；翻不出來就不用照片向量比對
        // （直接比對中文，找到的會是「畫面裡有中文字」的照片）。日期、地點文字照常用原本的查詢比對。
        let textEmbedding = await textEmbedding(for: trimmed)
        return DatabaseManager.shared.searchPhotos(text: trimmed, textEmbedding: textEmbedding)
    }

    /// 智慧搜尋（場景描述）找到、但其他方法都沒找到的照片：用照片向量檢查「至少有點像」才留下，
    /// 相簿裡沒有的東西不會再塞進不相干的照片。沒辦法檢查（查詢翻不成英文）時回傳 nil，照原本的結果。
    static func plausibleIds(_ ids: [String], query: String) async -> Set<String>? {
        guard !ids.isEmpty else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let embedding = await textEmbedding(for: trimmed) else { return nil }
        return DatabaseManager.shared.plausibleMatches(Set(ids), textEmbedding: embedding)
    }

    /// 查詢的文字向量（中文先翻成英文）；同一句只算一次。翻不出來或模型不能用時回傳 nil。
    static func textEmbedding(for query: String) async -> [Float]? {
        guard let clipText = await englishQuery(query) else { return nil }
        if let cached = embeddingCache.value(for: clipText) { return cached }
        guard let textModel else { print("Text model unavailable"); return nil }
        do {
            let tokenizer = CLIPTokenizer()
            let tokenArray = tokenizer.encode_full(text: clipText)
            let tokenMultiArray = try MLMultiArray(shape: [1, 77], dataType: .int32)
            for (index, tokenID) in tokenArray.enumerated() {
                tokenMultiArray[index] = NSNumber(value: tokenID)
            }
            let input = mobileclip_s2_textInput(text: tokenMultiArray)
            let prediction = try await textModel.prediction(input: input)
            let embedding = prediction.final_emb_1.toFloatArray().normalized()
            embeddingCache.set(embedding, for: clipText)
            return embedding
        } catch {
            print("文字模型推論失敗：\(error)")
            return nil
        }
    }

    private static let embeddingCache = SmallCache<[Float]>()

    /// 給照片向量模型用的英文查詢。英文查詢原樣回傳；中日韓文先用手機上的 AI 翻，
    /// 不能用時改用分類名稱對照（「貓」→ a cat）；都翻不出來回傳 nil。
    ///
    /// 同一句話每次都要翻成一樣的英文，搜尋結果才會穩定：
    /// - 同時有好幾個地方要翻同一句（照片向量搜尋、智慧搜尋結果的檢查）：共用同一次翻譯
    /// - 翻好的結果記在這支手機上（關掉 App 再開也一樣），之後同一句直接用
    /// - AI 太慢（超過 3 秒，例如智慧搜尋正在用模型解析句子）：這次先用分類名稱對照，但不記下來；
    ///   翻譯在背景繼續，翻好就記下來，下次同一句就用 AI 的翻譯
    static func englishQuery(_ text: String) async -> String? {
        guard SearchQueryLanguage.needsTranslation(text) else { return text }
        if let cached = translationCache.value(for: text) { return cached.isEmpty ? nil : cached }
        let task = TranslationRequests.shared.task(for: text) {
            var english: String?
            if OnDeviceAI.isAvailable {
                english = try? await OnDeviceAI.translateSearchQuery(text)
                if let value = english, value.isEmpty || SearchQueryLanguage.needsTranslation(value) { english = nil }
            }
            if english == nil { english = SearchQueryLanguage.dictionaryEnglish(text, catalog: .builtIn) }
            // 翻不出來的不記（之後模型可以用了再試）
            if let english {
                translationCache.set(english, for: text)
                print("[搜尋] 「\(text)」→ \(english)")
            }
            return english
        }
        if let finished = await withTimeout(seconds: 3, { await task.value }) { return finished }
        let fallback = SearchQueryLanguage.dictionaryEnglish(text, catalog: .builtIn)
        print("[搜尋] 「\(text)」翻譯超過 3 秒，這次先用分類名稱：\(fallback ?? "（無）")")
        return fallback
    }

    private static let translationCache = PersistentTranslations()

    /// 等最多 seconds 秒；超過時回傳 nil（翻譯慢的時候不要讓搜尋一直等）
    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// 進行中的查詢翻譯：同一句話同時只翻一次，大家等同一個結果
private final class TranslationRequests: @unchecked Sendable {
    static let shared = TranslationRequests()
    private var tasks: [String: Task<String?, Never>] = [:]
    private let lock = NSLock()

    func task(for text: String, _ work: @escaping @Sendable () async -> String?) -> Task<String?, Never> {
        lock.lock(); defer { lock.unlock() }
        if let running = tasks[text] { return running }
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> String? in
            let result = await work()
            self?.finish(text)
            return result
        }
        tasks[text] = task
        return task
    }

    private func finish(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        tasks[text] = nil
    }
}

/// 翻譯過的查詢（存在這支手機的 App 設定，最多 300 句；關掉 App 再開，同一句還是同樣的翻譯）
private final class PersistentTranslations: @unchecked Sendable {
    private let key = "searchQueryTranslations"
    private let limit = 300
    private var values: [String: String]
    private let lock = NSLock()

    init() {
        values = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    func value(for text: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[text]
    }

    func set(_ value: String, for text: String) {
        lock.lock()
        values[text] = value
        if values.count > limit {
            for old in values.keys.sorted().prefix(values.count - limit) where old != text { values[old] = nil }
        }
        let snapshot = values
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: key)
    }
}

/// 翻譯過的查詢、算過的文字向量（App 開著時保留，最多 200 筆）
private final class SmallCache<Value>: @unchecked Sendable {
    private var values: [String: Value] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    func value(for key: String) -> Value? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: Value, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if values[key] == nil { order.append(key) }
        values[key] = value
        if order.count > 200 { values[order.removeFirst()] = nil }
    }
}

// MARK: - 全局搜尋狀態管理
// 集中管理 ML 語意搜尋，讓所有頁面共用同一個搜尋列
class GlobalSearchViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var searchResults: [String] = []
    @Published var isSearching: Bool = false

    private var searchTask: Task<Void, Never>? = nil

    // 防抖搜尋入口 (500ms 延遲後執行 ML 推論)
    func executeSearch(query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        searchTask = Task {
            await MainActor.run { self.isSearching = true }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }

            // CoreML 推論放背景執行緒，避免 UI 卡頓
            let results = await Task.detached(priority: .userInitiated) {
                await SemanticPhotoSearch.search(query: trimmed)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        searchText = ""
        searchResults = []
        isSearching = false
    }
}

import SwiftUI
import CoreML

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
                return GlobalSearchViewModel.performMLSearch(query: trimmed)
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

    // MARK: - ML 語意搜尋 (純函數，可安全在背景執行)
    private static func performMLSearch(query: String) -> [String] {
        var textEmbedding: [Float]? = nil
        do {
            let tokenizer = CLIPTokenizer()
            let tokenArray = tokenizer.encode_full(text: query)
            let tokenMultiArray = try MLMultiArray(shape: [1, 77], dataType: .int32)
            for (i, id) in tokenArray.enumerated() {
                tokenMultiArray[i] = NSNumber(value: id)
            }
            let config = MLModelConfiguration()
            let textModel = try mobileclip_s2_text(configuration: config)
            let input = mobileclip_s2_textInput(text: tokenMultiArray)
            let prediction = try textModel.prediction(input: input)
            textEmbedding = prediction.final_emb_1.toFloatArray().normalized()
        } catch {
            print("ML text inference failed: \(error)")
        }
        return DatabaseManager.shared.searchPhotos(text: query, textEmbedding: textEmbedding)
    }
}

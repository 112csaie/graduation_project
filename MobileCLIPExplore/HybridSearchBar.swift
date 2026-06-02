import SwiftUI
import Translation

@available(iOS 18.0, *)
struct HybridSearchBar: View {
    @Binding var outputEnglishKeyword: String
    
    @State private var searchInput: String = ""
    @State private var translatedText: String = ""

    @State private var translationConfig: TranslationSession.Configuration?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("翻譯").font(.headline)
            
            HStack {
                TextField("輸入", text: $searchInput)
                    .textFieldStyle(.roundedBorder)
                
                Button("搜尋") {
                    translationConfig?.invalidate() // 清除舊任務
                    translationConfig = TranslationSession.Configuration(
                        target: Locale.Language(identifier: "en-US")
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(searchInput.isEmpty)
            }
            
            if !translatedText.isEmpty {
                Text("英文：\(translatedText)")
                    .font(.subheadline)
                    .foregroundColor(.blue)

            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
        .translationTask(translationConfig) { session in
            do {
                // 執行背景翻譯
                let response = try await session.translate(searchInput)
                
                await MainActor.run {
                    self.translatedText = response.targetText
                    self.outputEnglishKeyword = response.targetText
                }
            } catch {
                print("翻譯失敗：\(error.localizedDescription)")
            }
        }
    }
}

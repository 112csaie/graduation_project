import SwiftUI
import AVFoundation

struct SearchBar: View {
    @Binding var text: String
    var onSearch: (() -> Void)? = nil
    /// 搜尋框取得／失去焦點（首頁用來顯示最近搜尋）
    var onFocusChange: ((Bool) -> Void)? = nil
    /// 沒輸入時的提示（照片頁會用你照片產生的例子：「試試『東京的美食』」）
    var placeholder: String = "搜尋"
    
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
                
                ZStack(alignment: .trailing) {
                    TextField("", text: $text)
                        .font(.system(size: 16))
                        .foregroundColor(Theme.text)
                        .tint(Theme.text)
                        .submitLabel(.search)
                        .focused($isFocused)
                        .placeholder(when: text.isEmpty) {
                            Text(speechRecognizer.isRecording ? "聆聽中…" : placeholder)
                                .font(.system(size: 15))
                                .foregroundColor(speechRecognizer.isRecording ? .red : Theme.secondaryText)
                                .lineLimit(1)
                        }
                        .padding(.trailing, text.isEmpty ? 0 : 30)
                        .onSubmit {
                            isFocused = false
                            onSearch?()
                        }

                    if !text.isEmpty && !speechRecognizer.isRecording {
                        Button(action: {
                            text = ""
                            onSearch?()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(Theme.text.opacity(0.4))
                                .padding(.trailing, 5)
                        }
                        .transition(.opacity)
                    }
                }
                
                Button(action: {
                    let impactMed = UIImpactFeedbackGenerator(style: .medium)
                    impactMed.impactOccurred()
                    if !speechRecognizer.isRecording { text = "" }
                    speechRecognizer.toggleRecording()
                }) {
                    Image(systemName: speechRecognizer.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(speechRecognizer.isRecording ? .white : Theme.onAccent)
                        .frame(width: 34, height: 34)
                        .background(speechRecognizer.isRecording ? Color.red : Theme.accent)
                        .clipShape(Circle())
                }
                .accessibilityLabel(speechRecognizer.isRecording ? "停止語音輸入" : "語音輸入")
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
            
            if isFocused || !text.isEmpty {
                Button("取消") {
                    withAnimation {
                        text = ""
                        isFocused = false
                        onSearch?()
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .onChange(of: isFocused) { _, focused in onFocusChange?(focused) }
        .onChange(of: speechRecognizer.transcript) { _, newValue in
            if speechRecognizer.isRecording {
                text = newValue
                onSearch?()
            }
        }
        .dismissKeyboardOnTap()
    }
}

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content) -> some View {
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

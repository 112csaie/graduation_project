import SwiftUI
import AVFoundation

struct SearchBar: View {
    @Binding var text: String
    var onSearch: (() -> Void)? = nil
    
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.6))
                
                ZStack(alignment: .trailing) {
                    TextField("", text: $text)
                        .font(.custom("SF Pro Text", size: 18))
                        .foregroundColor(.white)
                        .accentColor(.white)
                        .focused($isFocused)
                        .placeholder(when: text.isEmpty) {
                            Text(speechRecognizer.isRecording ? "Listening..." : "Search")
                                .foregroundColor(speechRecognizer.isRecording ? .red : .white.opacity(0.6))
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
                                .foregroundColor(.white.opacity(0.4))
                                .padding(.trailing, 5)
                        }
                        .transition(.opacity)
                    }
                }
                
                Divider().frame(height: 20).background(Color.white.opacity(0.2)).padding(.horizontal, 4)

                Button(action: {
                    let impactMed = UIImpactFeedbackGenerator(style: .medium)
                    impactMed.impactOccurred()
                    if !speechRecognizer.isRecording { text = "" }
                    speechRecognizer.toggleRecording()
                }) {
                    Image(systemName: speechRecognizer.isRecording ? "stop.circle.fill" : "mic.fill")
                        .foregroundColor(speechRecognizer.isRecording ? .red : .white.opacity(0.6))
                        .font(.system(size: 20))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.85, green: 0.85, blue: 0.85).opacity(0.25)))
            
            if isFocused || !text.isEmpty {
                Button("取消") {
                    withAnimation {
                        text = ""
                        isFocused = false
                        onSearch?()
                    }
                }
                .foregroundColor(.white)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .onChange(of: speechRecognizer.transcript) { _, newValue in
            if speechRecognizer.isRecording {
                text = newValue
                onSearch?()
            }
        }
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

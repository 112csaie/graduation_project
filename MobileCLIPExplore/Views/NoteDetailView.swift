import SwiftUI
import PDFKit 

// MARK: - PDFKit 視圖包裝器
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .clear
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

struct NoteContentRenderer: View {
    let content: String

    var body: some View {
        let blocks = parseBlocks(from: content)

        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(stripBold(text))
                        .font(.system(size: headingSize(level: level), weight: .bold))
                        .foregroundColor(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)

                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundColor(Theme.text.opacity(0.65))
                        Text(stripBold(text))
                            .foregroundColor(Theme.text)
                            .font(.system(size: 16))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }

                case .numbered(let index, let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index).")
                            .foregroundColor(Theme.text.opacity(0.65))
                        Text(stripBold(text))
                            .foregroundColor(Theme.text)
                            .font(.system(size: 16))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }

                case .paragraph(let text):
                    Text(stripBold(text))
                        .foregroundColor(Theme.text)
                        .font(.system(size: 16))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func headingSize(level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 20
        case 3: return 18
        default: return 16
        }
    }

    /// 移除行內粗體標記 **text** → text
    private func stripBold(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "**", with: "")
        return s
    }

    private enum Block {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case numbered(index: String, text: String)
        case paragraph(text: String)
    }

    private func parseBlocks(from rawContent: String) -> [Block] {
        let normalized = rawContent
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return [] }

        var blocks: [Block] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            let text = paragraphLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text: text))
            }
            paragraphLines.removeAll()
        }

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            // 「- ### 第 1 天」：Agent 偶爾把標題寫成清單項目，當成標題顯示（不要出現 ### 符號）
            if let bullet = line.range(of: #"^[-•*]\s+(?=#{1,3}\s)"#, options: .regularExpression) {
                line.removeSubrange(bullet)
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                blocks.append(.heading(level: 3, text: String(line.dropFirst(4))))
                continue
            }
            if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(level: 2, text: String(line.dropFirst(3))))
                continue
            }
            if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.heading(level: 1, text: String(line.dropFirst(2))))
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(text: String(line.dropFirst(2))))
                continue
            }

            if let regex = try? NSRegularExpression(pattern: #"^(\d+)\.\s+(.*)$"#),
               let match = regex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
               ),
               let indexRange = Range(match.range(at: 1), in: line),
               let textRange = Range(match.range(at: 2), in: line) {
                flushParagraph()
                blocks.append(.numbered(index: String(line[indexRange]), text: String(line[textRange])))
                continue
            }

            paragraphLines.append(line)
        }

        flushParagraph()
        return blocks
    }
}

// MARK: - 筆記詳情頁面
struct NoteDetailView: View {
    @Environment(\.dismiss) var dismiss
    
    let noteId: String
    let noteTitle: String
    
    @State private var content: String = ""
    @State private var isFavorite: Bool = false
    @State private var images: [UIImage] = []
    @State private var showDeleteAlert = false
    @State private var showShareSheet = false
    
    private var displayTitle: String {
        noteTitle.displayNoteTitle
    }

    // 🌟 判斷並解析 PDF
    private var pdfDocument: PDFDocument? {
        if content.hasPrefix("PDF_BASE64::") {
            let base64String = content.replacingOccurrences(of: "PDF_BASE64::", with: "")
            if let data = Data(base64Encoded: base64String), let document = PDFDocument(data: data) {
                return document
            }
        }
        return nil
    }

    private var pdfExtractedText: String {
        guard let document = pdfDocument else { return "" }
        let extracted = document.string ?? ""
        return extracted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // --- 1. 頂部導覽列 ---
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Theme.text)
                    }
                    Spacer()
                    
                    HStack(spacing: 8) {
                        Text(displayTitle)
                            .font(.system(size: 20, weight: .bold))
                        if isFavorite {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 14))
                        }
                    }
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    
                    Spacer()
                    
                    Menu {
                        Button(action: { showShareSheet = true }) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button(action: {
                            DatabaseManager.shared.toggleNoteFavorite(noteId: noteId)
                            isFavorite.toggle()
                            NotificationCenter.default.post(
                                name: NSNotification.Name("NoteFavoriteChanged"), object: nil
                            )
                        }) {
                            Label(isFavorite ? "Remove Favorite" : "Favorite",
                                  systemImage: isFavorite ? "heart.fill" : "heart")
                        }
                        Divider()
                        Button(role: .destructive, action: { showDeleteAlert = true }) {
                            Label("Delete Note", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.text)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 15)
                
                // --- 2. 內容展示區 ---
                if let document = pdfDocument {
                    // 📄 渲染 PDF 視圖
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if !images.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("附件照片", systemImage: "paperclip")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(Theme.secondaryText)
                                        .padding(.horizontal, 20)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(0..<images.count, id: \.self) { index in
                                                Image(uiImage: images[index])
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 180, height: 180)
                                                    .cornerRadius(12)
                                                    .clipped()
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                    }
                                }
                            }

                            if !pdfExtractedText.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("文字預覽", systemImage: "text.alignleft")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(Theme.secondaryText)
                                        .padding(.horizontal, 20)

                                    NoteContentRenderer(content: pdfExtractedText)
                                        .padding(20)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .themeCard(radius: 22)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16)
                                                .stroke(Theme.text.opacity(0.15), lineWidth: 1)
                                        )
                                        .padding(.horizontal, 20)
                                }
                            }

                            Label("PDF 原始內容", systemImage: "doc.richtext")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Theme.secondaryText)
                                .padding(.horizontal, 20)

                            PDFKitView(document: document)
                                .cornerRadius(12)
                                .frame(minHeight: 420)
                                .padding(.horizontal, 16)
                        }
                        .padding(.bottom, 20)
                    }
                } else {
                    // 📝 渲染一般圖文筆記
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if !images.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("附件照片", systemImage: "paperclip")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(Theme.secondaryText)
                                        .padding(.horizontal, 20)
                                    
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(0..<images.count, id: \.self) { index in
                                                Image(uiImage: images[index])
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 180, height: 180)
                                                    .cornerRadius(12)
                                                    .clipped()
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                    }
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 12) {
                                Label("筆記內容", systemImage: "text.alignleft")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Theme.secondaryText)
                                
                                NoteContentRenderer(content: content)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .themeCard(radius: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Theme.text.opacity(0.15), lineWidth: 1)
                            )
                            .padding(.horizontal, 20)
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 50)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear { loadNoteData() }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: ["\(displayTitle)\n\n\(content)"]) // 若為 PDF，可額外處理匯出邏輯
        }
        .confirmationDialog("確認刪除", isPresented: $showDeleteAlert, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                DatabaseManager.shared.deleteNote(noteId: noteId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    
    private func loadNoteData() {
        let noteData = DatabaseManager.shared.fetchNoteDetail(noteId: noteId)
        content = noteData.content
        images = noteData.images
        
        if let note = DatabaseManager.shared.fetchNotes().first(where: { $0.id == noteId }) {
            isFavorite = note.isFavorite
        }
    }
}

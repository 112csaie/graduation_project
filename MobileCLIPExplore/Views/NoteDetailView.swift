import SwiftUI

struct NoteDetailView: View {
    @Environment(\.dismiss) var dismiss
    
    let noteId: String
    let noteTitle: String
    
    @State private var content: String = ""
    @State private var isFavorite: Bool = false
    @State private var images: [UIImage] = [] // 🌟 新增：存放該筆記相關圖片
    @State private var showDeleteAlert = false
    @State private var showShareSheet = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // --- 1. 頂部導覽列 ---
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    
                    // 標題與最愛狀態顯示
                    HStack(spacing: 8) {
                        Text(noteTitle)
                            .font(.system(size: 20, weight: .bold))
                        if isFavorite {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 14))
                        }
                    }
                    .foregroundColor(.white)
                    .lineLimit(1)
                    
                    Spacer()
                    
                    // 選單：分享、最愛、刪除
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
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 15)
                
                // --- 2. 內容捲動區 ---
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        
                        // 🌟 圖片展示區：若有圖片則顯示橫向捲動
                        if !images.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(0..<images.count, id: \.self) { index in
                                        Image(uiImage: images[index])
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 280, height: 200)
                                            .cornerRadius(12)
                                            .clipped()
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                        
                        // 🌟 文字內容區
                        VStack(alignment: .leading, spacing: 10) {
                            Text(content)
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .lineSpacing(6)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal, 20)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 50)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            loadNoteData()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: ["\(noteTitle)\n\n\(content)"])
        }
        .confirmationDialog("確認刪除", isPresented: $showDeleteAlert, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                DatabaseManager.shared.deleteNote(noteId: noteId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    
    // 在 NoteDetailView.swift 中替換原有的 loadNoteData()
    private func loadNoteData() {
        // 🌟 修改這裡：接收 tuple (文字與圖片陣列)
        let noteData = DatabaseManager.shared.fetchNoteDetail(noteId: noteId)
        content = noteData.content
        images = noteData.images
        
        // 載入最愛狀態
        if let note = DatabaseManager.shared.fetchNotes().first(where: { $0.id == noteId }) {
            isFavorite = note.isFavorite
        }
    }
}

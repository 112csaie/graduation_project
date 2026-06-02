import SwiftUI
import PhotosUI
import Photos
import CoreLocation

// MARK: - 輔助包裝器 (供 Sheet 使用)
struct IdentifiableString: Identifiable {
    let id: String
}

// MARK: - 主視圖 AgentView
struct AgentView: View {
    @State private var topTab: Int = 0        // 0: 智慧助手, 1: LIBRARY
    @State private var libraryTab: Int = 0    // 0: All Notes, 1: Favorite
    @State private var notesFilter: String = "" // LIBRARY 本地筆記過濾

    // --- 對話輸入狀態 ---
    @State private var promptText: String = ""
    @State private var selectedChatPhotos: [PhotosPickerItem] = []
    @State private var selectedUIImages: [UIImage] = []
    @State private var showSinglePicker = false
    @State private var stagedTask: String? = nil

    // --- 資料與 UI 狀態 ---
    @State private var availableAlbums: [String] = []
    @State private var notes: [(id: String, title: String, isFavorite: Bool)] = []
    @State private var showShareSheet = false
    @State private var textToShare: String = ""

    @EnvironmentObject var syncVM: PhotoSyncViewModel

    // 依本地過濾文字篩選筆記
    var filteredNotes: [(id: String, title: String, isFavorite: Bool)] {
        let baseNotes = libraryTab == 1 ? notes.filter { $0.isFavorite } : notes
        guard !notesFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return baseNotes
        }
        return baseNotes.filter { $0.title.localizedCaseInsensitiveContains(notesFilter) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 20) {
                    // Header
                    Text("Agent")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 10)

                    // 頂部切換標籤
                    HStack(spacing: 0) {
                        TabButton(title: "智慧助手", isSelected: topTab == 0) { topTab = 0 }
                        TabButton(title: "LIBRARY", isSelected: topTab == 1) { topTab = 1 }
                    }
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(20)
                    .padding(.horizontal, 20)

                    // 分頁內容
                    if topTab == 0 {
                        chatView
                    } else {
                        libraryView
                    }
                }
            }
        }
        .photosPicker(
            isPresented: $showSinglePicker,
            selection: $selectedChatPhotos,
            maxSelectionCount: 5,
            matching: .images
        )
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [textToShare])
        }
        .onAppear { loadNotes() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NoteFavoriteChanged"))) { _ in
            loadNotes()
        }
        .onChange(of: selectedChatPhotos) { _, newItems in loadSelectedImages(from: newItems) }
    }

    // MARK: - 智慧助手對話區
    private var chatView: some View {
        VStack {
            Spacer()

            // 暫存圖片與任務預覽
            if !selectedUIImages.isEmpty || stagedTask != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 15) {
                        if let task = stagedTask {
                            HStack {
                                Image(systemName: "sparkles")
                                Text(task).font(.caption2).bold()
                                Button(action: { stagedTask = nil }) {
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                            .padding(8)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }

                        ForEach(0..<selectedUIImages.count, id: \.self) { index in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: selectedUIImages[index])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button(action: {
                                    selectedUIImages.remove(at: index)
                                    if index < selectedChatPhotos.count {
                                        selectedChatPhotos.remove(at: index)
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black))
                                        .offset(x: 8, y: -8)
                                }
                            }
                            .padding([.top, .trailing], 8)
                        }
                    }
                    .padding(.horizontal, 25)
                }
                .padding(.bottom, 5)
            }

            // 輸入控制列
            HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    Button(action: { showSinglePicker = true }) {
                        Label("Select Photos", systemImage: "photo.on.rectangle")
                    }
                    Menu {
                        ForEach(availableAlbums, id: \.self) { album in
                            Button(album.capitalized) { stagedTask = "Analyze: \(album)" }
                        }
                    } label: {
                        Label("Select Album", systemImage: "folder.badge.magnifyingglass")
                    }
                    Button(action: { stagedTask = "Full Library Scan" }) {
                        Label("Deep Scan", systemImage: "camera.badge.ellipsis")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.bottom, 10)
                }

                TextField("Ask anything...", text: $promptText, axis: .vertical)
                    .lineLimit(1...5)
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .cornerRadius(15)

                Button(action: { unifiedSubmit() }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 20))
                        .foregroundColor(canSubmit ? .white : .gray)
                        .padding(.bottom, 10)
                }
                .disabled(!canSubmit)
            }
            .padding()
            .background(Color(white: 0.15))
            .cornerRadius(30)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    // MARK: - LIBRARY 筆記列表
    private var libraryView: some View {
        VStack(spacing: 12) {
            // 子標籤 + 本地筆記過濾
            HStack(spacing: 20) {
                Button(action: { libraryTab = 0 }) {
                    Text("All Notes")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(libraryTab == 0 ? .white : .gray)
                }
                Button(action: { libraryTab = 1 }) {
                    Text("Favorite")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(libraryTab == 1 ? .white : .gray)
                }
                Spacer()
            }
            .padding(.horizontal, 20)

            // 輕量筆記過濾框
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(.white.opacity(0.5))
                    .font(.system(size: 15))
                TextField("Filter notes...", text: $notesFilter)
                    .foregroundColor(.white)
                    .font(.system(size: 15))
                if !notesFilter.isEmpty {
                    Button(action: { notesFilter = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal, 20)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 15) {
                    ForEach(filteredNotes, id: \.id) { note in
                        NavigationLink(
                            destination: NoteDetailView(noteId: note.id, noteTitle: note.title)
                        ) {
                            HStack(spacing: 0) {
                                VStack(alignment: .leading) {
                                    Text(note.title)
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 20)

                                Spacer()

                                Button(action: {
                                    DatabaseManager.shared.toggleNoteFavorite(noteId: note.id)
                                    loadNotes()
                                }) {
                                    ZStack {
                                        Rectangle().foregroundColor(.clear).frame(width: 37, height: 37)
                                        Image(systemName: note.isFavorite ? "heart.fill" : "heart")
                                            .resizable().aspectRatio(contentMode: .fit)
                                            .frame(width: 24, height: 24)
                                            .foregroundColor(note.isFavorite ? .red : .white)
                                    }
                                }
                                .padding(.trailing, 10)

                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                                    .padding(.trailing, 20)
                            }
                            .frame(maxWidth: .infinity).frame(height: 110)
                            .background(Color.white.opacity(0.25)).cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(action: {
                                let noteData = DatabaseManager.shared.fetchNoteDetail(noteId: note.id)
                                textToShare = "\(note.title)\n\n\(noteData.content)"
                                showShareSheet = true
                            }) { Label("Share", systemImage: "square.and.arrow.up") }

                            Button(action: {
                                DatabaseManager.shared.toggleNoteFavorite(noteId: note.id)
                                loadNotes()
                            }) {
                                Label(
                                    note.isFavorite ? "Remove Favorite" : "Favorite",
                                    systemImage: note.isFavorite ? "heart.fill" : "heart"
                                )
                            }

                            Button(role: .destructive, action: {
                                DatabaseManager.shared.deleteNote(noteId: note.id)
                                loadNotes()
                            }) { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedUIImages.isEmpty
            || stagedTask != nil
    }

    private func loadSelectedImages(from items: [PhotosPickerItem]) {
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    images.append(uiImage)
                }
            }
            await MainActor.run { self.selectedUIImages = images }
        }
    }

    private func unifiedSubmit() {
        let timestamp = Date().formatted(.dateTime.month().day().hour().minute())

        if let task = stagedTask {
            if task == "Full Library Scan" {
                // 觸發實際同步
                syncVM.startSync()
                let total = DatabaseManager.shared.countAllPhotos()
                let content = """
                Full library scan started at \(timestamp).
                Currently indexed: \(total) photos.

                New photos will be automatically categorised as scanning progresses.
                Check the Home tab to see updated albums.
                """
                DatabaseManager.shared.insertNote(
                    title: "Library Scan · \(timestamp)", content: content, images: [])

            } else if task.hasPrefix("Analyze: ") {
                let albumName = String(task.dropFirst("Analyze: ".count))
                let photoIds  = DatabaseManager.shared.fetchPhotos(for: albumName)
                var content   = "Album: \(albumName.capitalized)\nTotal photos: \(photoIds.count)\n"
                if !promptText.isEmpty { content += "\nNotes: \(promptText)" }
                content += "\n\nTip: Connect to generate detailed AI summaries."
                DatabaseManager.shared.insertNote(
                    title: "Analysis · \(albumName.capitalized)",
                    content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                    images: selectedUIImages)
            }

        } else if !promptText.isEmpty {
            let title = promptText.count > 20 ? String(promptText.prefix(20)) + "…" : promptText
            let content = "Q: \(promptText)\n\nA: Connect to enable AI responses."
            DatabaseManager.shared.insertNote(title: title, content: content, images: selectedUIImages)
        }

        promptText = ""
        stagedTask = nil
        selectedChatPhotos = []
        selectedUIImages = []
        loadNotes()
        topTab = 1   // 切換到 Library 讓使用者看到新筆記
    }

    private func loadNotes() {
        notes = DatabaseManager.shared.fetchNotes()
        availableAlbums = DatabaseManager.shared.fetchAllCategories()
    }
}

// MARK: - Helper Components

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.white : Color.clear)
                .foregroundColor(isSelected ? .black : .white)
                .cornerRadius(20)
        }
    }
}

// 非同步縮圖載入器
struct ThumbnailLoader: View {
    let assetId: String
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .onAppear {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
            if let asset = fetchResult.firstObject {
                let manager = PHImageManager.default()
                let options = PHImageRequestOptions()
                options.deliveryMode = .fastFormat
                options.isNetworkAccessAllowed = true
                manager.requestImage(
                    for: asset,
                    targetSize: CGSize(width: 200, height: 200),
                    contentMode: .aspectFill,
                    options: options
                ) { img, _ in
                    DispatchQueue.main.async { self.image = img }
                }
            }
        }
    }
}

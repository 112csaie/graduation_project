import SwiftUI
import PhotosUI
import Photos

// MARK: - 1. 原生分享介面 (ShareSheet) 保持不變
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 2. 更新主畫面
struct CategoryDetailView: View {
    @Environment(\.dismiss) var dismiss
    let categoryTitle: String
    private let customAlbum: CustomAlbumSummary?
    private let metadataAlbum: MetadataAlbumSummary?
    /// 個人化分類（大分類或小分類）的節點 ID；用同一套相簿 UI 顯示。
    private let personalNodeId: String?
    
    @ObservedObject var syncVM: PhotoSyncViewModel
    
    @State private var searchText: String = ""
    @State private var selectedTab: Int = 0
    @State private var photos: [PhotoListItem] = []          // 依拍攝時間由新到舊
    @AppStorage(PhotoSortPreference.storageKey) private var newestFirst = true
    @State private var availableAlbums: [String] = []
    @State private var selectedAssetItem: IdentifiableString? = nil
    
    // 狀態控制：刪除確認與分享
    @State private var showDeleteAlert = false
    @State private var photoToDelete: String? = nil
    @State private var deleteErrorMessage = ""
    @State private var isRemovingAIData = false
    
    @State private var singleSharePayload: SharePayload?
    
    // 控制選取照片的陣列
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    // 我的 IP：改名／刪除
    @State private var renamedTitle: String?
    @State private var showRenameIP = false
    @State private var renameText = ""
    @State private var showDeleteIP = false
    @State private var ipErrorMessage: String?
    /// 演唱會類分類：依場次分好的小相簿
    @State private var liveEvents: [MetadataAlbumSummary] = []
    @State private var lastSyncReload = Date.distantPast
    /// 回憶草稿（旅行、演唱會場次相簿）
    @State private var isDraftingMemory = false
    @State private var memoryMessage: String?
    @State private var memoryNote: WikiItem?
    @ObservedObject private var connection = AgentConnection.shared
    @State private var openedMemoryNote: WikiItem?
    /// 多選
    @State private var selection = PhotoSelectionState()
    @State private var showAddSelectionToAlbum = false
    @State private var sharePayload: SharePayload?
    @State private var selectionMessage: String?

    init(categoryTitle: String, syncVM: PhotoSyncViewModel) {
        self.categoryTitle = categoryTitle
        self.syncVM = syncVM
        self.customAlbum = nil
        self.metadataAlbum = nil
        self.personalNodeId = nil
    }

    init(customAlbum: CustomAlbumSummary, syncVM: PhotoSyncViewModel) {
        self.categoryTitle = customAlbum.title
        self.syncVM = syncVM
        self.customAlbum = customAlbum
        self.metadataAlbum = nil
        self.personalNodeId = nil
    }

    init(metadataAlbum: MetadataAlbumSummary, syncVM: PhotoSyncViewModel) {
        self.categoryTitle = metadataAlbum.title
        self.syncVM = syncVM
        self.customAlbum = nil
        self.metadataAlbum = metadataAlbum
        self.personalNodeId = nil
    }

    /// 個人化分類（例如「拉花」「偶像小卡」）：與其他相簿相同的 UI。
    init(personalNodeId: String, title: String, syncVM: PhotoSyncViewModel) {
        self.categoryTitle = title
        self.syncVM = syncVM
        self.customAlbum = nil
        self.metadataAlbum = nil
        self.personalNodeId = personalNodeId
    }

    private var isPersonalCategory: Bool {
        personalNodeId != nil
    }

    /// 只有小分類（L3）可以手動加入／移除照片；大分類頁面只瀏覽。
    private var canEditPersonalTags: Bool {
        guard let personalNodeId else { return false }
        if CustomCategory.isCustomNodeId(personalNodeId) { return true }   // 我的 IP
        return (PersonalizationService.shared.catalog.node(personalNodeId)?.level ?? 0) >= 2
    }

    /// 我的 IP（使用者自己建立的分類）。
    private var customCategoryId: String? {
        personalNodeId.flatMap { CustomCategory.parse(nodeId: $0)?.id }
    }

    private var displayTitle: String { renamedTitle ?? categoryTitle }

    private var isCustomAlbum: Bool {
        customAlbum != nil
    }

    private var isMetadataAlbum: Bool {
        metadataAlbum != nil
    }

    /// 主題樂園是「去了哪幾次」，不是「場次」：用不同的字
    private var isThemeParkEvents: Bool {
        if let liveEventId { return !liveEventId.hasPrefix(LiveEventProfile.concert.idPrefix) }
        return !liveEvents.isEmpty && liveEvents.allSatisfy { !$0.id.hasPrefix(LiveEventProfile.concert.idPrefix) }
    }
    private var liveEventSectionTitle: String { isThemeParkEvents ? "每次去玩" : "場次" }
    private var liveEventRemoveTitle: String { isThemeParkEvents ? "不是這次的" : "不屬於這場" }

    /// 場次相簿（演唱會 live-…、主題樂園 park-…）
    private var liveEventId: String? {
        metadataAlbum.flatMap { PersonalizationService.isLiveEventAlbumId($0.id) ? $0.id : nil }
    }

    private var showsLiveEvents: Bool {
        personalNodeId.map { PersonalizationService.shared.showsLiveEvents(for: $0) } ?? false
    }
    
    var displayPhotos: [PhotoListItem] {
        let ordered = newestFirst ? photos : Array(photos.reversed())
        let base = selectedTab == 1 ? ordered.filter { $0.isFavorite } : ordered
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter {
            $0.tag.lowercased().contains(q) || $0.date.lowercased().contains(q)
        }
    }
    
    let columns = [GridItem(.flexible(), spacing: 15), GridItem(.flexible(), spacing: 15)]
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()
            
            VStack(spacing: 20) {
                // --- 頂部導覽列 ---
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Theme.text)
                    }
                    Spacer()
                    
                    if !isMetadataAlbum && (!isPersonalCategory || canEditPersonalTags) {
                        HStack(spacing: 18) {
                            if customCategoryId != nil {
                                Menu {
                                    Button(action: {
                                        renameText = displayTitle
                                        showRenameIP = true
                                    }) { Label("重新命名", systemImage: "pencil") }
                                    Button(action: {
                                        if let personalNodeId { try? PersonalizationService.shared.setCustomCover(nodeId: personalNodeId, assetId: nil) }
                                    }) { Label("封面改回自動（最新一張）", systemImage: "arrow.uturn.backward") }
                                    Button(role: .destructive, action: { showDeleteIP = true }) {
                                        Label("刪除這個分類", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundColor(Theme.text)
                                }
                                .accessibilityLabel("管理這個分類")
                            }
                            PhotosPicker(selection: $selectedPhotoItems, matching: .images, photoLibrary: .shared()) {
                                Image(systemName: "plus")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundColor(Theme.text)
                            }
                        }
                    } else {
                        // 旅遊相簿與大分類頁：右上角不放按鈕，保留同寬空間讓標題置中
                        Color.clear.frame(width: 28, height: 28)
                    }
                }
                // 有副標題（旅遊相簿）時加高，避免副標題蓋到下面的搜尋列
                .frame(minHeight: (metadataAlbum?.subtitle.isEmpty == false) ? 72 : 34)
                // 標題以整個畫面置中（左右按鈕數量不同也不會偏移），左右各留空間給按鈕
                .overlay {
                    VStack(spacing: 4) {
                        Text(displayTitle)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        if let metadataAlbum, !metadataAlbum.subtitle.isEmpty {
                            Text(metadataAlbum.subtitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.text.opacity(0.6))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 76)
                    .allowsHitTesting(false)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                // --- 搜尋列 ---
                SearchBar(text: $searchText).padding(.horizontal, 20)

                // --- ALL / FAVORITE 切換標籤 ---
                VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 0) {
                    Button(action: { selectedTab = 0 }) {
                        Text("全部").font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(selectedTab == 0 ? Theme.accent : Color.clear)
                            .foregroundColor(selectedTab == 0 ? Theme.onAccent : Theme.text).cornerRadius(20)
                    }
                    Button(action: { selectedTab = 1 }) {
                        Text("最愛").font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(selectedTab == 1 ? Theme.accent : Color.clear)
                            .foregroundColor(selectedTab == 1 ? Theme.onAccent : Theme.text).cornerRadius(20)
                    }
                }
                .padding(4).background(Theme.text.opacity(0.2)).cornerRadius(24)
                // 排序放在分頁下方（靠右），不和全部／最愛並排；左邊是「選取」
                HStack(spacing: 8) {
                    Button(action: {
                        if selection.isSelecting { selection.end() } else { selection.isSelecting = true }
                    }) {
                        // 選取中：顯示已選幾張，點一下結束選取
                        Label(selection.isSelecting ? (selection.selected.isEmpty ? "完成" : "已選 \(selection.selected.count)") : "選取",
                              systemImage: selection.isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(selection.isSelecting ? Theme.onAccent : Theme.text.opacity(0.85))
                            .padding(.horizontal, selection.isSelecting ? 10 : 0)
                            .padding(.vertical, selection.isSelecting ? 7 : 0)
                            .background(selection.isSelecting ? Theme.accent : Color.clear)
                            .clipShape(Capsule())
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    if selection.isSelecting {
                        // 選取的動作放在這一列（「已選」和排序中間），不再浮在照片上面
                        Spacer(minLength: 0)
                        PhotoSelectionInlineActions(
                            count: selection.selected.count,
                            allSelected: !displayPhotos.isEmpty && selection.selected.count == displayPhotos.count,
                            onSelectAll: {
                                selection.selected = selection.selected.count == displayPhotos.count ? [] : Set(displayPhotos.map(\.id))
                            },
                            onAddToAlbum: { showAddSelectionToAlbum = true },
                            onShare: shareSelection,
                            onFavorite: {
                                selectionMessage = PhotoFavoriteBatch.toggle(selection.ordered(displayPhotos.map(\.id)))
                                selection.end()
                                loadPhotos()
                            },
                            removeTitle: batchRemoveTitle,
                            onRemove: batchRemoveTitle == nil ? nil : { removeSelection() })
                    } else if let selectionMessage {
                        Text(selectionMessage)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.highlight.opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer()
                    PhotoSortButton(newestFirst: $newestFirst)
                }
                }
                .padding(.horizontal, 20)
                
                // --- 照片網格 ---
                ScrollView {
                    // 待確認直接在這本相簿裡回答：專屬相簿（作品頁也包含底下角色），以及主題相簿（大分類包含底下的小分類）
                    if let personalNodeId {
                        IPCandidateSection(nodeId: personalNodeId, onAnswered: { loadPhotos() })
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }
                    // 旅行、演唱會場次：整理成回憶筆記
                    if metadataAlbum != nil && searchText.isEmpty {
                        if memoryNote == nil && connection.isOffline && !AIRouter.onDevice {
                            AgentOfflineNotice(feature: "整理成回憶筆記")
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                        }
                        memoryDraftCard
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }
                    // 演唱會：依場次（同一個晚上、同一個場館）分好的小相簿
                    if showsLiveEvents && !liveEvents.isEmpty && searchText.isEmpty {
                        liveEventSection
                    }
                    LazyVGrid(columns: columns, spacing: 15) {
                        ForEach(displayPhotos) { photo in
                            let assetId = photo.id
                            ZStack(alignment: .topTrailing) {
                                Button(action: {
                                    if selection.isSelecting {
                                        selection.toggle(assetId)
                                    } else {
                                        selectedAssetItem = IdentifiableString(id: assetId)
                                    }
                                }) {
                                    PhotoThumbnailView(assetId: assetId)
                                        .frame(height: 170)
                                        .cornerRadius(12)
                                        .clipped()
                                }
                                .buttonStyle(.plain)

                                if selection.isSelecting {
                                    SelectionCheckmark(selected: selection.selected.contains(assetId))
                                        .allowsHitTesting(false)
                                } else {
                                // 🌟 新增：最愛按鈕疊加在照片右上角
                                Button(action: {
                                    DatabaseManager.shared.toggleFavorite(assetId: assetId)
                                    loadPhotos() // 更新 UI
                                }) {
                                    Image(systemName: photo.isFavorite ? "heart.fill" : "heart")
                                        .font(.system(size: 20))
                                        .foregroundColor(photo.isFavorite ? .red : Theme.text)
                                        .padding(8)
                                        .clipShape(Circle())
                                        .padding(8)
                                }
                                }
                            }
                            .contextMenu {
                                Button(action: { prepareImageForSharing(assetId: assetId) }) {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                }
                                Button(action: { DatabaseManager.shared.toggleFavorite(assetId: assetId); loadPhotos() }) {
                                    Label(photo.isFavorite ? "取消最愛" : "加入最愛", systemImage: photo.isFavorite ? "heart.slash" : "heart")
                                }
                                if let personalNodeId, customCategoryId != nil {
                                    // 我的 IP：自選封面；移除時連同作品底下有這張照片的角色一起記為「不是」
                                    Button(action: {
                                        try? PersonalizationService.shared.setCustomCover(nodeId: personalNodeId, assetId: assetId)
                                    }) {
                                        Label("設為封面", systemImage: "photo.badge.checkmark")
                                    }
                                    Button(action: {
                                        try? PersonalizationService.shared.removeFromCustomCategory(assetId: assetId, nodeId: personalNodeId)
                                        loadPhotos()
                                    }) {
                                        Label("從此分類移除", systemImage: "tag.slash")
                                    }
                                } else if let personalNodeId, canEditPersonalTags {
                                    // 只移除這個分類標籤（記錄為使用者拒絕，之後不會自動加回），照片本身不受影響
                                    Button(action: {
                                        try? PersonalizationService.shared.rejectTag(assetId: assetId, nodeId: personalNodeId)
                                        loadPhotos()
                                    }) {
                                        Label("從此分類移除", systemImage: "tag.slash")
                                    }
                                } else if let liveEventId {
                                    // 演唱會場次：記為「不是演唱會」，之後不會再被收進任何場次，照片本身不受影響
                                    Button(action: {
                                        PersonalizationService.shared.removeFromLiveEvent(assetId: assetId, eventId: liveEventId)
                                        loadPhotos()
                                    }) {
                                        Label(liveEventRemoveTitle, systemImage: "tag.slash")
                                    }
                                } else if !isCustomAlbum && !isPersonalCategory && DatabaseManager.legacyClassificationEnabled {
                                    // 舊 45 類 Classification 的「移動到其他相簿」，舊分類停用時不顯示
                                    Menu {
                                        ForEach(availableAlbums.filter { $0.lowercased() != categoryTitle.lowercased() }, id: \.self) { album in
                                            Button(action: { DatabaseManager.shared.movePhoto(assetId: assetId, to: album); loadPhotos() }) {
                                                Text(album.capitalized)
                                            }
                                        }
                                    } label: {
                                        Label("移到其他相簿", systemImage: "folder")
                                    }
                                }

                                Button(role: .destructive, action: {
                                    photoToDelete = assetId
                                    showDeleteAlert = true
                                }) {
                                    // 非自訂相簿：只移除 AI 分析資料，不刪除原始照片
                                    Label(isCustomAlbum ? "從相簿移除" : "移除 AI 分析資料",
                                          systemImage: isCustomAlbum ? "rectangle.stack.badge.minus" : "eraser")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 100)
                }
            }
        }
        .sheet(isPresented: $showAddSelectionToAlbum) {
            AddPhotosToAlbumSheet(assetIds: selection.ordered(displayPhotos.map(\.id))) { text in
                selectionMessage = text
                selection.end()
            }
        }
        .sheet(item: $sharePayload) { payload in ShareSheet(items: payload.items) }
        .navigationBarHidden(true)
        .sheet(item: $openedMemoryNote) { note in
            WikiNoteDetailView(item: note)
        }
        .sheet(item: $selectedAssetItem) { item in
            PhotoDetailModal(assetId: item.id, browseAssetIds: displayPhotos.map(\.id))
        }
        .onAppear {
            if metadataAlbum != nil { connection.check() }
            loadPhotos()
            availableAlbums = DatabaseManager.shared.fetchAllCategories()
        }
        .onChange(of: syncVM.syncedCount) { _, _ in
            // 掃描期間最多每 3 秒重新讀一次（以前每張照片都重讀，畫面會卡）
            guard Date().timeIntervalSince(lastSyncReload) >= 3 else { return }
            lastSyncReload = Date()
            loadPhotos()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DatabaseUpdated"))) { _ in
            loadPhotos()
        }
        .onReceive(NotificationCenter.default.publisher(for: .personalizationUpdated)) { _ in
            loadPhotos()
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveEventsUpdated)) { _ in
            if showsLiveEvents || liveEventId != nil { loadPhotos() }
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            let assetIds = newItems.compactMap(\.itemIdentifier)

            if let customAlbum {
                DatabaseManager.shared.addPhotos(assetIds, toCustomAlbum: customAlbum.id)
            } else if let personalNodeId {
                // 手動加入此分類（手動標籤，之後的自動標記不會覆蓋）
                for assetId in assetIds {
                    try? PersonalizationService.shared.confirmTag(assetId: assetId, nodeId: personalNodeId)
                }
            } else {
                for assetId in assetIds {
                    DatabaseManager.shared.movePhoto(assetId: assetId, to: categoryTitle)
                }
            }

            selectedPhotoItems.removeAll()
            loadPhotos()
        }
        .alert("重新命名", isPresented: $showRenameIP) {
            TextField("名稱", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("儲存") {
                guard let customCategoryId else { return }
                do {
                    try PersonalizationService.shared.renameCustomCategory(id: customCategoryId, name: renameText)
                    renamedTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    ipErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
        .confirmationDialog("刪除「\(displayTitle)」？", isPresented: $showDeleteIP, titleVisibility: .visible) {
            Button("刪除這個分類", role: .destructive) {
                guard let customCategoryId else { return }
                do {
                    try PersonalizationService.shared.deleteCustomCategory(id: customCategoryId)
                    dismiss()
                } catch {
                    ipErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會刪除 App 裡的這個分類，照片本身、系統相簿與你/妳的「我的相簿」都不受影響。組內的專屬相簿會保留，變成獨立的專屬相簿。")
        }
        .alert("操作失敗", isPresented: Binding(get: { ipErrorMessage != nil }, set: { if !$0 { ipErrorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(ipErrorMessage ?? "") }
        .sheet(item: $singleSharePayload) { payload in ShareSheet(items: payload.items) }
        .confirmationDialog(isCustomAlbum ? "確認移除" : "移除 AI 分析資料？", isPresented: $showDeleteAlert, titleVisibility: .visible) {
            Button(isCustomAlbum ? "從相簿移除" : "移除 AI 分析資料", role: .destructive) {
                if let id = photoToDelete {
                    if let customAlbum {
                        // 只移除相簿中的參照，照片本身不受影響
                        DatabaseManager.shared.removePhotoFromCustomAlbum(assetId: id, albumId: customAlbum.id)
                        loadPhotos()
                    } else {
                        removeAIAnalysis(assetId: id)
                    }
                }
            }
            .disabled(isRemovingAIData)
            Button("取消", role: .cancel) {}
        } message: {
            Text(isCustomAlbum
                 ? "確定要把這張照片從相簿移除嗎？照片本身不會被刪除。"
                 : "只會移除這張照片的特徵向量、AI tag與分析快取。原始照片、系統相簿、我的相簿與你/妳手動加入的 tag都會保留。")
        }
        .alert(isCustomAlbum ? "無法移除照片" : "無法移除 AI 分析資料", isPresented: deleteErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
    }
    
    // MARK: 多選

    /// 這本相簿能不能「從這裡移除」：我的相簿、可以編輯的分類、演唱會場次（旅遊相簿與大分類只能瀏覽）
    private var batchRemoveTitle: String? {
        if isCustomAlbum { return "從相簿移除" }
        if customCategoryId != nil || canEditPersonalTags { return "從此分類移除" }
        if liveEventId != nil { return liveEventRemoveTitle }
        return nil
    }

    /// 只移除 App 裡的分類或相簿關係，照片本身不受影響
    private func removeSelection() {
        let ids = selection.ordered(displayPhotos.map(\.id))
        for assetId in ids {
            if let customAlbum {
                DatabaseManager.shared.removePhotoFromCustomAlbum(assetId: assetId, albumId: customAlbum.id)
            } else if let personalNodeId, customCategoryId != nil {
                try? PersonalizationService.shared.removeFromCustomCategory(assetId: assetId, nodeId: personalNodeId)
            } else if let personalNodeId, canEditPersonalTags {
                try? PersonalizationService.shared.rejectTag(assetId: assetId, nodeId: personalNodeId)
            } else if let liveEventId {
                PersonalizationService.shared.removeFromLiveEvent(assetId: assetId, eventId: liveEventId)
            }
        }
        selectionMessage = "已移除 \(ids.count) 張（照片本身沒有刪除）"
        selection.end()
        loadPhotos()
    }

    private func shareSelection() {
        let ids = selection.ordered(displayPhotos.map(\.id))
        Task {
            let images = await PhotoShareLoader.images(for: ids)
            await MainActor.run {
                if !images.isEmpty { sharePayload = SharePayload(items: images) }
            }
        }
    }

    private func loadPhotos() {
        loadPhotosUnsorted()
        photos = DatabaseManager.shared.sortedNewestFirst(photos)
        if showsLiveEvents, let personalNodeId {
            liveEvents = PersonalizationService.shared.liveEventAlbums(for: personalNodeId)
            LiveEventCenter.shared.refreshIfNeeded()
        }
    }

    /// 「場次」：橫向卡片，點進去是那一場的所有照片（排隊、場外、暗場都在）
    // MARK: 回憶草稿

    private var memoryDraftCard: some View {
        Button(action: {
            if let memoryNote { openedMemoryNote = memoryNote } else { draftMemory() }
        }) {
            HStack(spacing: 12) {
                Image(systemName: memoryNote == nil ? "book.pages" : "book.closed.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.text.opacity(0.85))
                    .frame(width: 38, height: 38)
                    .background(Theme.text.opacity(0.1))
                    .cornerRadius(10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(memoryNote.map { "《\($0.topic)》" } ?? (isDraftingMemory ? "整理中…" : "整理成回憶筆記"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text(memoryMessage ?? "用日期、地點、tag 與照片描述寫成筆記，照片不會上傳")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text.opacity(0.5))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if isDraftingMemory {
                    ProgressView().tint(Theme.text)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.3))
                }
            }
            .padding(12)
            .themeCard(radius: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDraftingMemory)
    }

    private func draftMemory() {
        guard let metadataAlbum, !isDraftingMemory else { return }
        isDraftingMemory = true
        memoryMessage = AIRouter.onDevice ? "正在手機上整理照片、一天一天寫成筆記…" : "正在整理照片資訊，請 Agent（開發者的後端）撰寫…"
        let isLiveEvent = PersonalizationService.shared.liveEventAssetIds(eventId: metadataAlbum.id) != nil
        let title = [metadataAlbum.title, metadataAlbum.subtitle].filter { !$0.isEmpty }.joined(separator: "，")
        Task {
            do {
                // 演唱會場次 concert；主題樂園等其他場次 event；旅行 trip
                let kind = !isLiveEvent ? "trip" : (metadataAlbum.id.hasPrefix(LiveEventProfile.concert.idPrefix) ? "concert" : "event")
                let result = try await PhotoMemoryService.draft(title: title, kind: kind,
                                                                assetIds: metadataAlbum.assetIds)
                let item = try? await WikiService.shared.item(topic: result.topic)
                await MainActor.run {
                    isDraftingMemory = false
                    memoryNote = item
                    memoryMessage = (result.action == "updated" ? "已更新筆記" : "已建立筆記") + "，點一下打開"
                }
            } catch {
                await MainActor.run {
                    isDraftingMemory = false
                    memoryMessage = error.localizedDescription
                }
            }
        }
    }

    private var liveEventSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(liveEventSectionTitle)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(liveEvents) { album in
                        NavigationLink(destination: CategoryDetailView(metadataAlbum: album, syncVM: syncVM)) {
                            VStack(alignment: .leading, spacing: 6) {
                                Color.clear
                                    .frame(width: 150, height: 150)
                                    .overlay {
                                        if let cover = album.coverAssetId { PhotoThumbnailView(assetId: cover) }
                                    }
                                    .background(Theme.text.opacity(0.08))
                                    .clipped()
                                    .cornerRadius(12)
                                Text(album.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(1)
                                Text(album.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.text.opacity(0.6))
                                    .lineLimit(2)
                            }
                            .frame(width: 150, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            Text("全部照片")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 20)
                .padding(.top, 6)
        }
        .padding(.bottom, 4)
    }

    private func loadPhotosUnsorted() {
        if let personalNodeId {
            let ids = (try? PersonalizationService.shared.assetIds(matchingAll: [personalNodeId])) ?? []
            // 搜尋列以分類名稱與日期篩選
            photos = DatabaseManager.shared.fetchPhotosWithDetails(forAssetIds: ids).map {
                PhotoListItem(id: $0.id, isFavorite: $0.isFavorite, tag: categoryTitle, date: $0.date)
            }
        } else if let customAlbum {
            photos = DatabaseManager.shared.fetchCustomAlbumPhotosWithDetails(albumId: customAlbum.id)
        } else if let metadataAlbum {
            // 演唱會場次：讀目前的場次內容（使用者移除照片後立即更新）
            let ids = liveEventId.flatMap { PersonalizationService.shared.liveEventAssetIds(eventId: $0) } ?? metadataAlbum.assetIds
            photos = DatabaseManager.shared.fetchPhotosWithDetails(forAssetIds: ids)
        } else {
            photos = DatabaseManager.shared.fetchPhotosWithDetails(for: categoryTitle)
        }
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { !deleteErrorMessage.isEmpty },
            set: { isPresented in
                if !isPresented {
                    deleteErrorMessage = ""
                }
            }
        )
    }
    
    private func prepareImageForSharing(assetId: String) {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else { return }
        
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        
        // 不載入原始解析度：4800 萬畫素的照片解開要將近 200 MB 記憶體，容易閃退。2400 像素足夠分享（和照片頁的分享相同）
        manager.requestImage(for: asset, targetSize: CGSize(width: 2400, height: 2400), contentMode: .aspectFit, options: options) { result, _ in
            if let image = result {
                DispatchQueue.main.async {
                    self.singleSharePayload = SharePayload(items: [image])
                }
            }
        }
    }

    /// 取代原本的「從系統相簿刪除照片」：App 不再刪除使用者的原始照片，
    /// 這裡只移除 App 自己產生的 AI 分析資料（向量、自動標籤、自動分類、場景圖）。
    private func removeAIAnalysis(assetId: String) {
        guard !isRemovingAIData else { return }   // 防止重複點擊
        isRemovingAIData = true
        Task {
            do {
                _ = try await PersonalizationService.shared.removeAIAnalysis(assetId: assetId)
                await MainActor.run {
                    isRemovingAIData = false
                    loadPhotos()
                }
            } catch {
                await MainActor.run {
                    isRemovingAIData = false
                    deleteErrorMessage = "資料沒有任何變更，可以再試一次。\n" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }
}

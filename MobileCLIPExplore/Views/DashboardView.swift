import SwiftUI
import Combine
import Photos
import UIKit

/// 底部分頁：「照片」（全部照片＋搜尋）與「相簿」（分類、旅行、專屬、我的相簿）共用這個畫面
enum DashboardRole {
    case photos
    case albums
}

struct DashboardView: View {
    let role: DashboardRole

    init(role: DashboardRole = .photos) {
        self.role = role
        _currentMode = State(initialValue: role == .albums ? .dictionary : .allPhotos)
    }

    @State private var searchText: String = ""
    @State private var searchResults: [String] = []
    @State private var noteResults: [WikiItem] = []          // 搜尋時一併找到的筆記（最多 3 篇）
    /// 每張搜尋結果是怎麼找到的（文字、tag、智慧搜尋），顯示在縮圖上
    @State private var searchReasons: [String: Set<SearchReason>] = [:]
    @State private var searchFilter: SearchFilter = .all
    @State private var searchFocused = false
    @State private var autoSearchTask: Task<Void, Never>? = nil
    @State private var recentSearches: [String] = RecentSearches.load()
    /// 回憶提醒：最近的旅行／演唱會還沒有筆記
    @State private var memorySuggestion: MemorySuggestion? = nil
    @State private var isDraftingSuggestion = false
    @State private var suggestionMessage: String? = nil
    @State private var openedNote: WikiItem? = nil
    @State private var allPhotoAssetIds: [String] = []
    @State private var groupedCategories: [(main: String, subs: [String])] = []
    @State private var metadataAlbumSections: [MetadataAlbumSection] = []
    @State private var isLoadingAllPhotos = false
    @State private var isLoadingMetadataAlbums = false
    @State private var customAlbums: [CustomAlbumSummary] = []
    @State private var hasAutoScanned = false
    @State private var isSearching: Bool = false
    /// 已顯示結果、智慧搜尋還在找（找到後補進來）
    @State private var isRefiningSearch: Bool = false
    /// 搜尋結果篩選（時間、地點、截圖）；句子裡拆出來的時間地點會自動套用
    @State private var refinement = SearchRefinement()
    /// 搜尋地名（例如「桃園市」）時預設只顯示在那裡拍的照片；按「顯示全部」改成不限地點
    @State private var showAllPlaces = false
    @State private var searchFacts: [String: PhotoSearchFacts] = [:]
    @State private var searchTrips: [DetectedTrip] = []
    @State private var factsTask: Task<Void, Never>?
    /// 多選（搜尋結果）
    @State private var selection = PhotoSelectionState()
    @State private var showAddSelectionToAlbum = false
    @State private var sharePayload: SharePayload?
    @State private var actionMessage: String?
    /// 「存成相簿」：建立相簿時直接用這些照片，不重新搜尋
    @State private var pendingAlbumAssetIds: [String]?
    @State private var hasSearched: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var allPhotosLoadTask: Task<Void, Never>? = nil
    /// 掃描期間的重新整理合併成每 2 秒最多一次（見 scheduleCoalescedRefresh）
    @State private var refreshScheduled = false
    /// 抽象語意搜尋（AbstractSearch 資料夾，iOS 27 + Apple Intelligence）
    @ObservedObject private var abstractSearch = AbstractSearchCoordinator.shared
    @State private var metadataLoadTask: Task<Void, Never>? = nil
    @State private var selectedResultAssetId: IdentifiableString? = nil
    /// 照片頁可以左右滑動瀏覽的清單（全部照片或搜尋結果）
    @State private var browseAssetIds: [String] = []
    @State private var showSyncBanner: Bool = false
    @State private var syncBannerCount: Int = 0
    @State private var showCreateCustomAlbumSheet = false
    @State private var pendingCustomAlbumName = ""
    @State private var isPreparingCustomAlbum = false
    @State private var customAlbumDraft: CustomAlbumDraft?
    @State private var customAlbumErrorMessage = ""
    
    @State private var showDeleteAlbumAlert = false
    @State private var targetAlbumId: String? = nil
    @State private var isCustomAlbumTarget = false

    @State private var currentMode: DashboardGalleryMode = .allPhotos
    /// 相簿分頁：按右上角放大鏡才顯示搜尋列（畫面比較乾淨）
    @State private var showAlbumSearch = false
    /// 依你的照片產生的搜尋建議（搜尋列提示、下面的小標籤）
    @State private var searchSuggestions: [String] = SearchSuggestionBuilder.fallback
    /// 「照片」依天分組（日期貼紙）
    @State private var photoDaySections: [PhotoDaySection] = []
    @State private var todayPhotoCount = 0
    /// 「我的相簿」裡的專屬相簿（AI 依範例照片自動找）
    @State private var ipData: IPBrowseData = .empty
    @State private var showNewAlbumChoice = false
    /// 選完「AI 找／自己挑」後，等選擇畫面關掉再打開對應的建立畫面（兩個畫面不能同時跳出來）
    @State private var pendingNewAlbumKind: NewAlbumKind?
    @State private var ipCreateRequest: IPCreateRequest?
    /// 分類頁的跨分類篩選（由搜尋列的分類建議加入）
    @State private var classificationFilters: [String] = []
    
    @State private var allPhotos: [PhotoListItem] = []          // 依拍攝時間由新到舊
    @AppStorage(PhotoSortPreference.storageKey) private var newestFirst = true
    /// 「照片」頁：全部照片，或只看截圖（iPhone 標成截圖的照片，和系統「截圖」相簿相同）
    @State private var showScreenshotsOnly = false
    @State private var screenshotIds: Set<String> = []
    @State private var screenshotCount = 0

    private var sortedAllPhotos: [PhotoListItem] {
        let photos = showScreenshotsOnly ? allPhotos.filter { screenshotIds.contains($0.id) } : allPhotos
        return newestFirst ? photos : Array(photos.reversed())
    }

    /// 「全部・截圖」切換（只在照片分頁、沒有搜尋時顯示）
    private var photoKindPicker: some View {
        HStack(spacing: 8) {
            photoKindChip("全部", count: allPhotos.count, selected: !showScreenshotsOnly) { showScreenshotsOnly = false }
            photoKindChip("截圖", count: screenshotCount, selected: showScreenshotsOnly) { showScreenshotsOnly = true }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func photoKindChip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { action() } }) {
            Text(count > 0 ? "\(title) \(OrganizingStatusBar.count(count))" : title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? Theme.onAccent : Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.text.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    /// 「照片」頁每行張數：雙指縮放調整（和系統「照片」App 一樣），會記住使用者的選擇
    @AppStorage("allPhotosColumnCount") private var allPhotosColumnCount = 5
    /// 縮放手勢目前累積到的倍率基準（每跨過一段就換一次張數）
    @State private var pinchBaseline: CGFloat = 1
    private static let columnSteps = [1, 2, 3, 4, 5, 7, 9]

    /// 依每行張數決定縮圖解析度（只分幾級，避免縮放時一直重新讀圖）
    private var allPhotosThumbnailPixels: CGFloat {
        switch allPhotosColumnCount {
        case ...2: return 800
        case 3...4: return 400
        default: return 250
        }
    }

    private var allPhotosGrid: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 3), count: allPhotosColumnCount)
    }

    /// 照片越大圓角越大（一行 1～2 張時像卡片，一行很多張時只有一點點圓角）
    private var photoCornerRadius: CGFloat {
        switch allPhotosColumnCount {
        case ...2: return 16
        case 3...4: return 9
        default: return 5
        }
    }

    /// 放大（手指張開）→ 每行變少、照片變大；縮小 → 每行變多
    private func stepColumns(_ direction: Int) {
        let steps = Self.columnSteps
        let current = steps.firstIndex(of: allPhotosColumnCount) ?? steps.firstIndex(of: 5)!
        let next = min(max(current + direction, 0), steps.count - 1)
        guard next != current else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            allPhotosColumnCount = steps[next]
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 不用 @EnvironmentObject：那樣掃描進度每更新一次，整個首頁都要重算。
    /// 改成直接取用同一個實例，需要的狀態用 onReceive 接收（見 isSyncingNow）。
    private var syncVM: PhotoSyncViewModel { BackgroundSyncCoordinator.shared.syncViewModel }
    @State private var isSyncingNow = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {

                    if showSyncBanner && role == .photos {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Theme.highlight)
                            Text("已同步 \(syncBannerCount) 張新照片")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Theme.text)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Theme.text.opacity(0.1))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(searchText.isEmpty ? (role == .photos ? "照片" : "相簿") : "搜尋結果")
                                    .font(.system(size: 30, weight: .heavy))
                                    .foregroundColor(Theme.text)
                                if searchText.isEmpty, let headerSubtitle {
                                    Text(headerSubtitle)
                                        .font(.system(size: 13))
                                        .foregroundColor(Theme.secondaryText)
                                        .lineLimit(1)
                                        .transition(.opacity)
                                }
                            }

                            Spacer()

                            if role == .photos {
                                if searchText.isEmpty && currentMode == .allPhotos {
                                    PhotoSortButton(newestFirst: $newestFirst)
                                }
                                // 掃描進度只讓這個小元件重畫，首頁其他部分不跟著重算
                                SyncStatusControl(syncVM: syncVM)
                            } else {
                                if currentMode == .dictionary {
                                    HeaderIconButton(systemName: showAlbumSearch || !searchText.isEmpty ? "xmark" : "magnifyingglass",
                                                     label: showAlbumSearch ? "關閉搜尋" : "搜尋分類") {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            if showAlbumSearch || !searchText.isEmpty {
                                                searchText = ""
                                                showAlbumSearch = false
                                            } else {
                                                showAlbumSearch = true
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)

                        if role == .photos {
                            // 整理進度（掃描、tag、智慧搜尋分析）：有工作在跑才顯示
                            OrganizingStatusBar(syncVM: syncVM)
                                .padding(.horizontal, 20)
                        } else {
                            // 相簿分頁：分類、旅行、我的相簿（專屬相簿合併在我的相簿）
                            AlbumModePicker(mode: $currentMode)
                                .padding(.horizontal, 20)
                        }

                        // 照片分頁一定有搜尋列；相簿分頁在「分類」按放大鏡才顯示（輸入分類名稱可以跨分類篩選）
                        if role == .photos || (currentMode == .dictionary && (showAlbumSearch || !searchText.isEmpty)) {
                            SearchBar(text: $searchText, onSearch: {
                                executeSearch(query: searchText)
                            }, onFocusChange: { focused in
                                withAnimation(.easeInOut(duration: 0.15)) { searchFocused = focused }
                            }, placeholder: role == .photos
                                ? "試試「\(searchSuggestions.first ?? "海邊的夕陽")」"
                                : "輸入分類名稱，例如：拉麵")
                            .padding(.horizontal, 20)
                            .padding(.bottom, role == .photos && searchText.isEmpty && !searchFocused ? 0 : 8)
                            if role == .photos && searchText.isEmpty && !searchFocused {
                                suggestionChips
                                    .padding(.bottom, 6)
                            }
                        } else {
                            Color.clear.frame(height: 4)
                        }
                    }
                    .background(Theme.background)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 20) {
                            if !searchText.isEmpty {
                                searchResultsSection
                            } else if searchFocused {
                                recentSearchPanel
                            } else {
                                // 包在 spacing 0 的 VStack 裡：卡片沒顯示時不會多出空白（卡片自己帶下方間距）
                                VStack(alignment: .leading, spacing: 0) {
                                    // 第一次使用：哪些功能已經可以用、哪些還在準備；累積了待確認 tag 時提醒回答
                                    if role == .photos {
                                        SetupProgressCard(syncVM: syncVM)
                                    } else if currentMode == .dictionary {
                                        // 待確認 tag 是「分類」的事：放在相簿分頁的分類最上方
                                        CandidateReminderCard()
                                    }
                                    if role == .photos, let memorySuggestion {
                                        memorySuggestionCard(memorySuggestion)
                                            .padding(.horizontal, 20)
                                            .padding(.bottom, 20)
                                    }
                                    albumSections
                                }
                            }

                            Color.clear.frame(height: 20)
                        }
                        .padding(.top, 10)
                    }
                    // 有結果時點空白處或照片、往下滑，都會收起鍵盤（下方原本的點空白收鍵盤被結果蓋住了）
                    .scrollDismissesKeyboard(.immediately)
                    .simultaneousGesture(TapGesture().onEnded {
                        // 只在有搜尋結果時（最近搜尋的清單照常點選）
                        if searchFocused && !searchText.isEmpty { UIApplication.shared.dismissKeyboard() }
                    })
                }

                // 多選搜尋結果：底部動作列
                if selection.isSelecting && !searchText.isEmpty {
                    VStack {
                        Spacer()
                        PhotoSelectionBar(
                            count: selection.selected.count,
                            allSelected: !filteredSearchResults.isEmpty && selection.selected.count == filteredSearchResults.count,
                            onSelectAll: {
                                selection.selected = selection.selected.count == filteredSearchResults.count ? [] : Set(filteredSearchResults)
                            },
                            onAddToAlbum: { showAddSelectionToAlbum = true },
                            onShare: shareSelection,
                            onFavorite: {
                                actionMessage = PhotoFavoriteBatch.toggle(selection.ordered(filteredSearchResults))
                                selection.end()
                            },
                            onDone: { selection.end() })
                        .padding(.bottom, 12)
                    }
                }

                if isPreparingCustomAlbum {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Theme.text))
                            .scaleEffect(1.2)
                        Text("正在為相簿尋找照片…")
                            .foregroundColor(Theme.text)
                            .font(.system(size: 15, weight: .medium))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(Theme.surface(0.15))
                    .cornerRadius(18)
                }
            }
            .dismissKeyboardOnTap()
            .navigationDestination(item: $customAlbumDraft) { draft in
                CustomAlbumDraftView(draft: draft) {
                    loadCategories()
                }
            }
        }
        .sheet(item: $selectedResultAssetId) { assetItem in
            PhotoDetailModal(assetId: assetItem.id, browseAssetIds: browseAssetIds)
        }
        .sheet(item: $openedNote) { note in
            WikiNoteDetailView(item: note)
        }
        .sheet(isPresented: $showAddSelectionToAlbum) {
            AddPhotosToAlbumSheet(assetIds: selection.ordered(filteredSearchResults)) { text in
                actionMessage = text
                selection.end()
                loadCategories()
            }
        }
        .sheet(item: $sharePayload) { payload in ShareSheet(items: payload.items) }
        .sheet(item: $ipCreateRequest, onDismiss: loadIPAlbums) { request in
            IPCreateSheet(initialParentId: request.parentId, initialParentName: request.parentName)
        }
        .sheet(isPresented: $showNewAlbumChoice, onDismiss: openPendingNewAlbum) {
            NewAlbumChoiceSheet { kind in
                pendingNewAlbumKind = kind
                showNewAlbumChoice = false
            }
            .presentationDetents([.height(380)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(32)
        }
        .sheet(isPresented: $showCreateCustomAlbumSheet) {
            CustomAlbumNamePromptView(
                albumName: $pendingCustomAlbumName,
                errorMessage: customAlbumErrorMessage,
                onCancel: {
                    pendingCustomAlbumName = ""
                    customAlbumErrorMessage = ""
                    pendingAlbumAssetIds = nil
                    showCreateCustomAlbumSheet = false
                },
                onSubmit: submitCustomAlbumName
            )
            .presentationDetents([.fraction(0.32)])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            print("[DASH] onAppear fired, isLoggedIn path reached")
            PerfLog.logLaunchOnce()       // PF-06（只在 Debug 版記錄）
            PerfLog.startThermalWatch()   // PF-10
            loadCategories()
            // 下面這些只做一次：由「照片」分頁負責（「相簿」分頁不重複啟動）
            guard role == .photos else { return }
            loadSearchSuggestions()
            // 升級後：用既有照片向量做多標籤標記（不重算向量）
            PersonalizationService.shared.scheduleTagging()
            if !hasAutoScanned && !syncVM.isSyncing {
                hasAutoScanned = true
                syncVM.startSync()
            }
            loadMemorySuggestion()
        }
        // 筆記變動後（例如剛整理成回憶）重新判斷提醒
        .onReceive(NotificationCenter.default.publisher(for: .wikiNotesUpdated)) { _ in loadMemorySuggestion() }
        .onReceive(syncVM.$syncedCount.removeDuplicates()) { _ in
            scheduleCoalescedRefresh()
        }
        .onReceive(syncVM.$isSyncing.removeDuplicates()) { isNowSyncing in
            let wasSyncing = isSyncingNow
            isSyncingNow = isNowSyncing
            guard wasSyncing != isNowSyncing else { return }
            if !isNowSyncing && syncVM.syncedCount > 0 {
                syncBannerCount = syncVM.syncedCount
                withAnimation { showSyncBanner = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { showSyncBanner = false }
                }
            }

            if !isNowSyncing {
                refreshMetadataAlbumsIfNeeded(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DatabaseUpdated"))) { _ in
            scheduleCoalescedRefresh(includeMetadata: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TripRegionsUpdated"))) { _ in
            refreshMetadataAlbumsIfNeeded(force: true)
        }
        .onChange(of: searchText) { _, newValue in
            autoSearchTask?.cancel()
            actionMessage = nil
            showAllPlaces = false
            selection.end()
            if newValue.isEmpty {
                refinement = SearchRefinement()
                searchResults = []
                noteResults = []
                hasSearched = false
                isSearching = false
                isRefiningSearch = false
                searchTask?.cancel()
            } else {
                hasSearched = false
                isRefiningSearch = false
                searchResults = []
                noteResults = []
                // 注音還在組字（「娃娃ㄩ」「ㄖㄣ ㄨ」）：不自動搜尋，等選好字。
                // 以前打一個注音就搜一次，手機上的 AI 一直被這些半成品佔用，真正的查詢翻譯、解析就會變慢或超時，結果時好時壞
                guard !Self.isComposingPhonetic(newValue) else { return }
                // 停止打字一下下就自動搜尋，不用按「搜尋」
                autoSearchTask = Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if searchText == newValue { executeSearch(query: newValue) }
                    }
                }
            }
        }
        .onChange(of: pendingCustomAlbumName) { _, _ in
            customAlbumErrorMessage = ""
        }
        .onChange(of: allPhotos) { _, _ in regroupPhotoDays() }
        .onChange(of: newestFirst) { _, _ in regroupPhotoDays() }
        .onChange(of: showScreenshotsOnly) { _, _ in regroupPhotoDays() }
        // PF-02 篩選反應時間：使用者改篩選（不是搜尋時自動帶入的）到畫面更新完
        .onChange(of: refinement) { _, _ in
            guard hasSearched, !isSearching else { return }
            let timingStart = PerfLog.now()
            DispatchQueue.main.async {
                PerfLog.log("篩選", since: timingStart, count: filteredSearchResults.count)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .personalizationUpdated)) { _ in
            if role == .albums { loadIPAlbums() }
        }
        .onChange(of: currentMode) { _, mode in
                    // 相簿分頁只有「分類」有搜尋列：換到其他頁時清掉搜尋
                    if role == .albums && mode != .dictionary {
                        if !searchText.isEmpty { searchText = "" }
                        showAlbumSearch = false
                    }
                    refreshAllPhotosIfNeeded()
                    refreshMetadataAlbumsIfNeeded()
                }
        // 🌟 正確放置的 Delete Album Alert
        .alert("刪除相簿", isPresented: $showDeleteAlbumAlert) {
            Button("刪除", role: .destructive) {
                if let id = targetAlbumId {
                    if isCustomAlbumTarget {
                        DatabaseManager.shared.deleteCustomAlbum(albumId: id)
                    }
                    loadCategories()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("確定要刪除這個相簿嗎？相簿裡的照片不會從裝置中刪除。")
        }
    }
    
    private var allPhotosSectionView: some View {
        VStack(spacing: 0) {
            if role == .photos && !allPhotos.isEmpty {
                photoKindPicker
            }
            if showScreenshotsOnly && !isLoadingAllPhotos && sortedAllPhotos.isEmpty {
                Text("沒有截圖")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
            if isLoadingAllPhotos && allPhotos.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Theme.text))
                        .scaleEffect(1.2)
                    Spacer()
                }
                Spacer()
            } else {
                // 依天分組，每天一張日期貼紙（今天・10/21）；照片是小圓角方格
                LazyVGrid(columns: allPhotosGrid, spacing: 3) {
                    ForEach(photoDaySections) { section in
                        Section {
                            ForEach(section.items) { photo in
                                Button(action: {
                                    browseAssetIds = sortedAllPhotos.map(\.id)
                                    selectedResultAssetId = IdentifiableString(id: photo.id)
                                }) {
                                    // 固定正方形格子，照片放在格子裡裁切：可點範圍就是看到的範圍
                                    Color.clear
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay(PhotoThumbnailView(assetId: photo.id, pixelSize: allPhotosThumbnailPixels))
                                        .clipShape(RoundedRectangle(cornerRadius: photoCornerRadius, style: .continuous))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            PhotoDaySticker(title: section.title, count: section.items.count)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                                .padding(.leading, 6)
                        }
                    }
                }
                .padding(.horizontal, 10)
                // 雙指縮放調整每行張數；每縮放約 25% 換一級，連續縮放可以一次跨好幾級
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let ratio = value.magnification / pinchBaseline
                            if ratio > 1.25 {
                                stepColumns(-1)
                                pinchBaseline = value.magnification
                            } else if ratio < 0.8 {
                                stepColumns(+1)
                                pinchBaseline = value.magnification
                            }
                        }
                        .onEnded { _ in pinchBaseline = 1 }
                )
            }
        }
    }

    /// 搜尋列在「分類」模式下同時建議分類：點選後成為分類頁的篩選條件（一個搜尋框搞定兩種搜尋）。
    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            let suggestions = currentMode == .dictionary
                ? Array(PersonalizationService.shared.catalog.searchNodes(matching: searchText)
                    .filter { $0.level >= 2 && !classificationFilters.contains($0.id) }
                    .prefix(12))
                : []
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("分類")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.6))
                        .padding(.horizontal, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions) { node in
                                Button(action: {
                                    classificationFilters.append(node.id)
                                    searchText = ""
                                    UIApplication.shared.dismissKeyboard()
                                }) {
                                    TagChip(text: node.nameZh, systemImage: "plus", style: .neutral)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            if hasSearched && !isSearching && (!searchResults.isEmpty || !noteResults.isEmpty) {
                searchFilterChips
            }
            if hasSearched && !isSearching && !searchResults.isEmpty && searchFilter != .notes {
                queryPlaceNotice
            }
            if hasSearched && !isSearching && (!searchResults.isEmpty || !refinement.isEmpty) && searchFilter != .notes {
                SearchRefinementBar(
                    refinement: $refinement,
                    resultIds: placeScopedResults,
                    facts: searchFacts,
                    trips: searchTrips,
                    shownCount: filteredSearchResults.count,
                    onSaveAsAlbum: {
                        pendingAlbumAssetIds = filteredSearchResults
                        pendingCustomAlbumName = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                        customAlbumErrorMessage = ""
                        showCreateCustomAlbumSheet = true
                    },
                    onSelect: { selection.isSelecting = true })
            }
            if let actionMessage {
                Text(actionMessage)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.highlight.opacity(0.85))
                    .padding(.horizontal, 20)
            }
            if hasSearched && !isSearching && !noteResults.isEmpty && (searchFilter == .all || searchFilter == .notes) {
                noteSearchResults
            }
            if searchFilter != .notes {
                photoSearchResults
            }
        }
    }

    /// 符合搜尋的個人 Wiki 筆記：放在照片結果上方
    private var noteSearchResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("筆記")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text.opacity(0.6))
                .padding(.horizontal, 20)
            VStack(spacing: 8) {
                ForEach(noteResults) { note in
                    Button(action: { openedNote = note }) {
                        HStack(spacing: 12) {
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 16))
                                .foregroundColor(Theme.text.opacity(0.8))
                                .frame(width: 36, height: 36)
                                .background(Theme.text.opacity(0.1))
                                .cornerRadius(9)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.topic)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(1)
                                if !note.summary.isEmpty {
                                    Text(note.summary)
                                        .font(.system(size: 13))
                                        .foregroundColor(Theme.text.opacity(0.5))
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.text.opacity(0.3))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .themeCard(radius: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var photoSearchResults: some View {
        Group {
            if !hasSearched {
                // 打字中：停 0.7 秒就會自動搜尋，這裡不顯示任何提示
                Color.clear.frame(height: 1)
            } else if isSearching {
                VStack(spacing: 15) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Theme.text))
                        .scaleEffect(1.2)
                    Text("分析中…")
                        .foregroundColor(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 50)
            } else if searchResults.isEmpty {
                VStack(spacing: 8) {
                    Text("找不到符合的照片")
                        .foregroundColor(Theme.secondaryText)
                    abstractSearchHint
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
            } else {
                abstractSearchHint
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 15
                ) {
                    ForEach(filteredSearchResults, id: \.self) { assetId in
                        Button(action: {
                            if selection.isSelecting {
                                selection.toggle(assetId)
                            } else {
                                browseAssetIds = filteredSearchResults
                                selectedResultAssetId = IdentifiableString(id: assetId)
                            }
                        }) {
                            PhotoThumbnailView(assetId: assetId)
                                .frame(height: 170)
                                .cornerRadius(12)
                                .clipped()
                                .overlay(alignment: .bottomLeading) { reasonBadges(for: assetId) }
                                .overlay(alignment: .topTrailing) {
                                    if selection.isSelecting { SelectionCheckmark(selected: selection.selected.contains(assetId)) }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: 搜尋：篩選、找到的原因、最近搜尋

    private var filteredSearchResults: [String] {
        let scoped = placeScopedResults
        let base: [String]
        switch searchFilter {
        case .all, .notes, .photos: base = scoped
        case .text: base = scoped.filter { searchReasons[$0]?.contains(.text) == true }
        }
        return refinement.apply(base, facts: searchFacts)
    }

    /// 搜尋字串是結果裡的某個地區或國家（「桃園市」「日本」）時的那個地點
    private var searchedPlace: SearchPlaceFilter? {
        SearchFacets.queryPlace(searchText, ids: searchResults, facts: searchFacts)
    }

    /// 搜尋地名時只留下在那裡拍的照片（照片文字裡有這個地名的也保留）；按了「顯示全部」就不限
    private var placeScopedResults: [String] {
        guard !showAllPlaces, let place = searchedPlace else { return searchResults }
        return scoped(searchResults, to: place)
    }

    private func scoped(_ ids: [String], to place: SearchPlaceFilter) -> [String] {
        ids.filter { id in
            searchReasons[id]?.contains(.text) == true || (searchFacts[id].map { place.matches($0) } ?? false)
        }
    }

    /// 「只顯示在桃園市拍的照片・顯示全部」
    @ViewBuilder
    private var queryPlaceNotice: some View {
        if let place = searchedPlace {
            let hidden = searchResults.count - scoped(searchResults, to: place).count
            if hidden > 0 || showAllPlaces {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.highlight)
                    Text(showAllPlaces ? "顯示所有地點的結果" : "只顯示在\(place.label)拍的照片")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Spacer(minLength: 4)
                    Button(action: { withAnimation { showAllPlaces.toggle(); refinement.place = nil } }) {
                        Text(showAllPlaces ? "只看\(place.label)" : "顯示全部")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.onAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .themeCard(radius: 14)
                .padding(.horizontal, 20)
            }
        }
    }

    private var searchFilterChips: some View {
        let textCount = placeScopedResults.filter { searchReasons[$0]?.contains(.text) == true }.count
        let options: [(SearchFilter, String)] = [
            (.all, "全部"),
            (.photos, "照片 \(searchResults.count)"),
        ] + (noteResults.isEmpty ? [] : [(.notes, "筆記 \(noteResults.count)")])
          + (textCount == 0 ? [] : [(.text, "文字符合 \(textCount)")])
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { option in
                    Button(action: { searchFilter = option.0 }) {
                        Text(option.1)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(searchFilter == option.0 ? Theme.onAccent : Theme.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(searchFilter == option.0 ? Theme.accent : Theme.text.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func reasonBadges(for assetId: String) -> some View {
        let reasons = SearchReason.allCases.filter { searchReasons[assetId]?.contains($0) == true }.prefix(2)
        if !reasons.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(reasons), id: \.self) { reason in
                    Label(reason.title, systemImage: reason.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                }
            }
            .padding(6)
        }
    }

    /// 點搜尋框但還沒輸入：最近搜尋與建議
    private var recentSearchPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !recentSearches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最近搜尋")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.text.opacity(0.6))
                        Spacer()
                        Button("清除") {
                            RecentSearches.clear()
                            recentSearches = []
                        }
                        .font(.system(size: 13))
                        .foregroundColor(Theme.text.opacity(0.6))
                    }
                    ForEach(recentSearches, id: \.self) { query in
                        Button(action: { searchText = query; executeSearch(query: query) }) {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundColor(Theme.text.opacity(0.45))
                                Text(query).foregroundColor(Theme.text)
                                Spacer()
                            }
                            .font(.system(size: 15))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("從你/妳的照片想到的")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text.opacity(0.6))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(searchSuggestions, id: \.self) { query in
                            Button(action: { searchText = query; executeSearch(query: query) }) {
                                Text(query)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Theme.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Theme.text.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    // MARK: 回憶提醒

    private func memorySuggestionCard(_ suggestion: MemorySuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                PhotoThumbnailView(assetId: suggestion.coverAssetId)
                    .frame(width: 56, height: 56)
                    .cornerRadius(10)
                    .clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(suggestion.kind == "concert" ? "整理這場演出的回憶？"
                         : suggestion.kind == "theme_park" ? "整理這次樂園的回憶？" : "整理這趟旅行的回憶？")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text(suggestionMessage ?? "\(suggestion.title)・\(suggestion.subtitle)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text.opacity(0.6))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: {
                    MemorySuggestionService.shared.dismiss(suggestion)
                    withAnimation { memorySuggestion = nil }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.5))
                        .padding(6)
                }
                .accessibilityLabel("略過這個提醒")
            }
            Button(action: { draftSuggestedMemory(suggestion) }) {
                HStack {
                    if isDraftingSuggestion { ProgressView().tint(Theme.onAccent) }
                    Text(isDraftingSuggestion ? "整理中…" : "整理成回憶筆記")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Theme.accent)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(isDraftingSuggestion)
        }
        .padding(14)
        .themeCard(radius: 22)
    }

    private func draftSuggestedMemory(_ suggestion: MemorySuggestion) {
        isDraftingSuggestion = true
        suggestionMessage = AIRouter.onDevice ? "正在手機上整理照片、一天一天寫成筆記…" : "正在整理照片資訊，請 Agent（開發者的後端）撰寫…"
        Task {
            do {
                let result = try await PhotoMemoryService.draft(title: suggestion.title + "，" + suggestion.subtitle,
                                                                kind: suggestion.kind == "theme_park" ? "event" : suggestion.kind,
                                                                assetIds: suggestion.assetIds)
                let item = try? await WikiService.shared.item(topic: result.topic)
                await MainActor.run {
                    isDraftingSuggestion = false
                    suggestionMessage = nil
                    MemorySuggestionService.shared.dismiss(suggestion)
                    withAnimation { memorySuggestion = nil }
                    openedNote = item
                }
            } catch {
                await MainActor.run {
                    isDraftingSuggestion = false
                    suggestionMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadMemorySuggestion() {
        Task {
            let suggestion = await MemorySuggestionService.shared.currentSuggestion()
            await MainActor.run { memorySuggestion = suggestion }
        }
    }

    /// 抽象語意搜尋還在建立索引時提醒：結果可能不完整
    @ViewBuilder
    private var abstractSearchHint: some View {
        if isRefiningSearch {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6).tint(Theme.text)
                Text("智慧搜尋找更多相關照片中…")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text.opacity(0.45))
            }
        } else if abstractSearch.isBuilding && abstractSearch.buildTotal > 0 {
            Text("智慧搜尋正在分析照片（\(abstractSearch.buildDone)/\(abstractSearch.buildTotal)），結果可能不完整")
                .font(.system(size: 12))
                .foregroundColor(Theme.text.opacity(0.45))
        }
    }

    private var albumSections: some View {
            VStack(alignment: .leading, spacing: 20) {
                if displayedAlbumSectionCount == 0 && !isSyncingNow {
                    Text("沒有相簿")
                        .foregroundColor(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    switch currentMode {
                    case .allPhotos:
                        allPhotosSectionView
                    case .dictionary:
                        if usesPersonalizedClassification {
                            // 個人化 Classification：依使用者選取的大分類組織，並加入族群細分類
                            PersonalCategoryBrowserView(syncVM: syncVM, selectedFilterNodes: $classificationFilters)
                        } else {
                            // 舊的 45 類 Classification 已停用；個人化資料庫尚未就緒（例如未登入）時顯示說明
                            Text("分類尚未就緒，請先登入並同步相簿。")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    case .metadata:
                        if isLoadingMetadataAlbums && metadataAlbumSections.isEmpty {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.text))
                                Text("正在整理旅遊相簿…")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(Theme.text.opacity(0.65))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                        } else {
                            metadataAlbumSectionsView
                        }
                    case .ip, .mine:
                        // 專屬相簿合併在「我的相簿」（舊的 .ip 也顯示這裡）
                        customAlbumsSectionView
                    }
                }
            }
        }

        private var displayedAlbumSectionCount: Int {
            switch currentMode {
            case .allPhotos:
                return allPhotos.isEmpty ? 0 : 1
            case .dictionary, .ip, .mine:
                return 1   // 個人化分類頁、IP 頁、我的相簿自行處理載入與空狀態
            case .metadata:
                let metadataCount = metadataAlbumSections.reduce(0) { $0 + ($1.albums.isEmpty ? 0 : 1) }
                return metadataCount + 1
            }
        }

    private var usesPersonalizedClassification: Bool {
        PersonalizationService.shared.isAvailable && LocalUserSession.currentUserId != nil
    }

    private var dictionaryAlbumSectionsView: some View {
        ForEach(groupedCategories, id: \.main) { group in
            let subAlbums = categorySummaries(for: group.subs)
            if !subAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 15) {
                    NavigationLink(
                        destination: GroupAlbumListView(
                            groupTitle: group.main,
                            subAlbums: subAlbums,
                            syncVM: syncVM
                        )
                    ) {
                        HStack {
                            Text(group.main.capitalized)
                                .font(.system(size: 21, weight: .heavy))
                                .foregroundColor(Theme.text)

                            Spacer()

                            HStack(spacing: 6) {
                                Text("查看全部")
                                    .font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(Theme.text.opacity(0.75))
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 15) {
                            ForEach(subAlbums) { album in
                                NavigationLink(
                                    destination: CategoryDetailView(
                                        categoryTitle: album.title,
                                        syncVM: syncVM
                                    )
                                ) {
                                    CategoryAlbumCard(album: album)
                                        .id(album.coverAssetId ?? album.id)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(action: {
                                        DatabaseManager.shared.togglePinCategory(keyword: album.id)
                                        loadCategories()
                                    }) {
                                        Label("釘選／取消釘選", systemImage: "pin")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
                .themeCard(radius: 22)
                .padding(.horizontal, 20)
            }
        }
    }

    private var metadataAlbumSectionsView: some View {
        Group {
            if metadataAlbumSections.isEmpty && !isLoadingMetadataAlbums {
                VStack(spacing: 8) {
                    Image(systemName: "airplane.circle")
                        .font(.system(size: 32))
                        .foregroundColor(Theme.text.opacity(0.35))
                    Text("還沒有旅遊相簿")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.75))
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
            }
            metadataAlbumSectionsList
        }
    }

    private var metadataAlbumSectionsList: some View {
        ForEach(metadataAlbumSections) { section in
            if !section.albums.isEmpty {
                VStack(alignment: .leading, spacing: 15) {
                    NavigationLink(
                        destination: MetadataAlbumListView(
                            title: section.title,
                            albums: section.albums,
                            syncVM: syncVM
                        )
                    ) {
                        HStack {
                            Text(section.title)
                                .font(.system(size: 21, weight: .heavy))
                                .foregroundColor(Theme.text)

                            Spacer()

                            HStack(spacing: 6) {
                                Text("查看全部")
                                    .font(.system(size: 13, weight: .semibold))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(Theme.text.opacity(0.75))
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 15) {
                            ForEach(section.albums) { album in
                                NavigationLink(
                                    destination: CategoryDetailView(
                                        metadataAlbum: album,
                                        syncVM: syncVM
                                    )
                                ) {
                                    MetadataAlbumCard(album: album)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
                .themeCard(radius: 22)
                .padding(.horizontal, 20)
            }
        }
    }

    /// 「我的相簿」：自己挑的相簿和專屬相簿（AI 依範例照片自動找）放在同一個兩欄方格。
    /// 第一格是「新相簿」（先問要 AI 找還是自己挑）；專屬相簿右上角有吊牌，有分組的看起來是一疊。長按可以釘選或刪除。
    private var customAlbumsSectionView: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                  alignment: .leading, spacing: 16) {
            ForEach(ipData.groups) { group in
                NavigationLink(destination: ipGroupDestination(group)) {
                    myAlbumTile(title: group.work.category.name,
                                subtitle: group.characters.isEmpty ? "\(group.work.photoCount) 張・AI 自動找"
                                                                   : "\(group.characters.count) 本・\(group.work.photoCount) 張",
                                assetId: group.work.coverAssetId,
                                isAI: true, isStack: !group.characters.isEmpty,
                                pending: group.work.candidateCount)
                }
                .buttonStyle(.plain)
            }

            ForEach(customAlbums) { album in
                NavigationLink(destination: CategoryDetailView(customAlbum: album, syncVM: syncVM)) {
                    myAlbumTile(title: album.title, subtitle: "\(album.photoCount) 張",
                                assetId: album.coverAssetId, isAI: false, isStack: false, pending: 0)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(action: {
                        DatabaseManager.shared.togglePinCustomAlbum(albumId: album.id)
                        loadCategories()
                    }) {
                        Label("釘選／取消釘選", systemImage: "pin")
                    }
                    Button(role: .destructive, action: {
                        targetAlbumId = album.id
                        isCustomAlbumTarget = true
                        showDeleteAlbumAlert = true
                    }) {
                        Label("刪除相簿", systemImage: "trash")
                    }
                }
            }
            // 「新相簿」放在最後一格（沒有相簿時就是唯一的一格）
            Button(action: startNewAlbum) {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.secondaryText.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(Theme.onAccent)
                                    .frame(width: 44, height: 44)
                                    .background(Theme.accent)
                                    .clipShape(Circle())
                                Text(customAlbums.isEmpty && ipData.groups.isEmpty ? "建立第一本相簿" : "新相簿")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.secondaryText)
                            }
                        )
                    Text("AI 幫你/妳找，或自己挑")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    /// 我的相簿的一格：圓角封面；專屬相簿右上角吊牌，有分組的後面多兩層卡片（看起來是一疊）
    private func myAlbumTile(title: String, subtitle: String, assetId: String?,
                             isAI: Bool, isStack: Bool, pending: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if isStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.surface(0.3))
                        .rotationEffect(.degrees(6))
                        .offset(x: 4, y: -3)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.tile)
                        .rotationEffect(.degrees(-4))
                        .offset(x: -3, y: -2)
                }
                Theme.tile
                    .overlay {
                        if let assetId {
                            PhotoThumbnailView(assetId: assetId, pixelSize: 500)
                        } else {
                            Image(systemName: isAI ? "tag" : "photo.on.rectangle")
                                .font(.system(size: 26))
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if isAI {
                            // AI 自動找的相簿：亮色吊牌（AI 幫照片貼上這本相簿的標籤）
                            Image(systemName: "tag.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Theme.onAccent)
                                .frame(width: 26, height: 26)
                                .background(Theme.accent)
                                .clipShape(Circle())
                                .padding(8)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if pending > 0 {
                            AccentPill(text: "待確認 \(pending)").padding(8)
                        }
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryText)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    /// 專屬相簿：沒有分組直接打開；有分組先看到組內的相簿
    @ViewBuilder
    private func ipGroupDestination(_ group: IPGroup) -> some View {
        if group.characters.isEmpty {
            CategoryDetailView(personalNodeId: group.work.category.nodeId, title: group.work.category.name, syncVM: syncVM)
        } else {
            IPGroupAlbumsView(group: group, syncVM: syncVM) { request in ipCreateRequest = request }
        }
    }

    private func startNewAlbum() {
        if usesPersonalizedClassification {
            showNewAlbumChoice = true
        } else {
            pendingCustomAlbumName = ""
            customAlbumErrorMessage = ""
            showCreateCustomAlbumSheet = true
        }
    }

    private func openPendingNewAlbum() {
        guard let kind = pendingNewAlbumKind else { return }
        pendingNewAlbumKind = nil
        switch kind {
        case .ai:
            ipCreateRequest = IPCreateRequest()
        case .manual:
            pendingCustomAlbumName = ""
            customAlbumErrorMessage = ""
            showCreateCustomAlbumSheet = true
        }
    }

    private func loadIPAlbums() {
        guard role == .albums, usesPersonalizedClassification else { return }
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> IPBrowseData in
                (try? PersonalizationService.shared.loadIPBrowseData()) ?? .empty
            }.value
            await MainActor.run { ipData = loaded }
        }
    }

    // MARK: 標題、搜尋建議、依天分組

    /// 大標題下面的一句話
    private var headerSubtitle: String? {
        if role == .photos {
            guard !allPhotos.isEmpty else { return nil }
            let total = "\(OrganizingStatusBar.count(allPhotos.count)) 張"
            return todayPhotoCount > 0 ? "\(total)・今天拍了 \(todayPhotoCount) 張" : total
        }
        switch currentMode {
        case .dictionary: return "依你/妳的興趣，AI 自動分好"
        case .metadata:
            let count = metadataAlbumSections.reduce(0) { $0 + $1.albums.count }
            return count > 0 ? "\(count) 趟旅行，自動整理" : "出門拍照，自動整理成旅行"
        case .ip, .mine:
            let count = customAlbums.count + ipData.groups.count
            return count > 0 ? "\(count) 本相簿・有吊牌的是 AI 自動找" : "自己建的相簿都在這裡"
        case .allPhotos: return nil
        }
    }

    /// 搜尋列下面的建議（依你的照片產生），點一下直接搜尋
    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(searchSuggestions, id: \.self) { query in
                    Button(action: { searchText = query; executeSearch(query: query) }) {
                        Text(query)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.card)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func loadSearchSuggestions() {
        Task {
            let items = await PhotoSearchSuggestions.load()
            await MainActor.run { withAnimation { searchSuggestions = items } }
        }
    }

    private func regroupPhotoDays() {
        guard role == .photos else { return }
        let photos = sortedAllPhotos
        Task {
            let result = await Task.detached(priority: .userInitiated) { PhotoDaySection.group(photos) }.value
            await MainActor.run {
                photoDaySections = result.sections
                todayPhotoCount = result.todayCount
            }
        }
    }

    private func loadCategories() {
        refreshAllPhotosIfNeeded()
        // 我的相簿、旅行相簿只在「相簿」分頁讀取（「照片」分頁用不到，不重複讀）
        guard role == .albums else { return }
        loadPrimaryAlbumSections()
        loadIPAlbums()
        refreshMetadataAlbumsIfNeeded(force: metadataAlbumSections.isEmpty)
    }

    /// 在背景讀資料庫，主執行緒只負責更新畫面（以前在主執行緒讀，掃描時會卡住點擊）。
    private func loadPrimaryAlbumSections() {
        Task {
            let (groups, albums) = await Task.detached(priority: .userInitiated) {
                (DatabaseManager.shared.fetchGroupedCategories(), DatabaseManager.shared.fetchCustomAlbums())
            }.value
            await MainActor.run {
                groupedCategories = groups
                customAlbums = albums
            }
        }
    }

    /// 掃描或資料更新時，2 秒內的多次通知合併成一次重新整理。
    private func scheduleCoalescedRefresh(includeMetadata: Bool = false) {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            refreshScheduled = false
            refreshAllPhotosIfNeeded()
            if role == .albums { loadPrimaryAlbumSections() }
            if includeMetadata {
                refreshMetadataAlbumsIfNeeded(force: metadataAlbumSections.isEmpty)
            }
        }
    }

    private func shouldLoadMetadataAlbums() -> Bool {
            role == .albums && currentMode == .metadata
        }
    
    private func refreshAllPhotosIfNeeded() {
        guard currentMode == .allPhotos else { return }
        // 已有照片時不顯示轉圈（避免畫面閃動）；前一次還沒讀完就取消，只留最新一次
        if allPhotos.isEmpty { isLoadingAllPhotos = true }
        allPhotosLoadTask?.cancel()
        allPhotosLoadTask = Task {
            let (photos, screenshots) = await Task.detached(priority: .userInitiated) {
                // 截圖：只查 PhotoKit 的照片類型（iPhone 的截圖標記），不讀圖
                (DatabaseManager.shared.fetchAllPhotosNewestFirst(), PersonalizationService.fetchScreenshotIds())
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.screenshotIds = screenshots
                self.screenshotCount = photos.filter { screenshots.contains($0.id) }.count
                self.allPhotos = photos
                self.isLoadingAllPhotos = false
            }
        }
    }

    private func refreshMetadataAlbumsIfNeeded(force: Bool = false) {
        guard role == .albums, shouldLoadMetadataAlbums() || force else { return }
        loadMetadataAlbumSections()
    }

    private func loadMetadataAlbumSections() {
        metadataLoadTask?.cancel()
        isLoadingMetadataAlbums = true
        metadataLoadTask = Task {
            let sections = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.fetchMetadataAlbumSections()
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                metadataAlbumSections = sections
                isLoadingMetadataAlbums = false
                metadataLoadTask = nil
            }
            // 還沒有地名的旅程：優先查詢第一級行政區，查到後會收到 TripRegionsUpdated 並更新標題
            let pending = sections.flatMap { $0.albums.flatMap(\.regionPendingAssetIds) }
            if !pending.isEmpty {
                BackgroundSyncCoordinator.shared.resolveTripRegions(assetIds: pending)
            }
        }
    }

    /// 智慧搜尋分數到這裡就直接顯示，不再用照片向量確認（低於的才確認）
    static let confidentAbstractScore: Float = 0.4

    /// 有注音符號（ㄅ～ㄩ、聲調）：還在組字，不是完整的查詢
    static func isComposingPhonetic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3100...0x312F).contains($0.value) || (0x31A0...0x31BF).contains($0.value)
            || [0x02C7, 0x02CA, 0x02CB, 0x02D9].contains($0.value) }
    }

    private func executeSearch(query: String) {
        searchTask?.cancel()
        // 按了「搜尋」：等著自動搜尋的那一次不用再搜（以前會在 0.7 秒後把這次搜尋取消、整個重來）
        autoSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            noteResults = []
            isSearching = false
            isRefiningSearch = false
            hasSearched = false
            refinement = SearchRefinement()
            return
        }

        hasSearched = true
        isSearching = true
        isRefiningSearch = false
        selection.end()
        let timingStart = PerfLog.now()   // PF-01 搜尋反應時間；PF-11 含智慧搜尋
        searchTask = Task {
            // 0. 拆出句子裡的時間、地點（例如「去年夏天在日本的拉麵」→ 去年夏天・日本・拉麵），變成篩選
            let parsed = await Task.detached(priority: .userInitiated) {
                SearchQueryParser.parse(trimmed, places: SearchPlaceCache.places())
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                refinement = SearchRefinement(dateRange: parsed.dateRange, place: parsed.place, excludeScreenshots: false)
            }
            let text = parsed.text

            // 只有時間或地點（例如「去年夏天」「日本」）：列出那段時間、那個地方的所有照片
            if text.isEmpty {
                let all = await Task.detached(priority: .userInitiated) {
                    DatabaseManager.shared.fetchAllPhotosNewestFirst().map(\.id)
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    searchResults = all
                    noteResults = []
                    searchReasons = [:]
                    searchFilter = .all
                    isSearching = false
                    RecentSearches.add(trimmed)
                    recentSearches = RecentSearches.load()
                    PerfLog.log("搜尋", since: timingStart, count: all.count, note: trimmed)
                }
                await loadSearchFacts(for: all)
                return
            }

            // 1. MobileCLIP 向量搜尋（與抽象語意搜尋並行）
            async let clipTask = Task.detached(priority: .userInitiated) {
                await SemanticPhotoSearch.search(query: text)
            }.value

            // 2. 抽象語意搜尋（iOS 27 + Apple Intelligence：解析查詢 → 場景圖混合式搜尋）；不支援時回傳空陣列
            async let abstractTask = AbstractSearchCoordinator.shared.searchScored(text)

            // 3. 個人化多標籤：標籤名稱（中英文）符合的照片
            async let tagTask = Task.detached(priority: .userInitiated) {
                PersonalizationService.shared.assetIds(matchingTagText: text)
            }.value

            // 4. 照片中的文字（OCR）：例如搜尋店名、票券上的演出名稱
            async let textTask = Task.detached(priority: .userInitiated) {
                PhotoTextCoordinator.shared.assetIds(matching: text)
            }.value

            // 5. 個人 Wiki 筆記（存在手機，不需要網路；未登入時沒有結果）
            async let noteTask = WikiService.shared.matchingNotes(query: trimmed, limit: 3)

            // 先顯示照片向量、標籤、照片文字、筆記的結果（通常不到 1 秒）；
            // 智慧搜尋要先請 Apple Intelligence 解析查詢（1～3 秒），找到後再補進來重新排序。
            let (clipResults, tagIds, textIds) = await (clipTask, tagTask, textTask)
            let notes = await noteTask
            let waitsForAbstract = abstractSearch.isAvailable
            guard !Task.isCancelled else { return }
            let first = Self.mergeSearchResults(clip: clipResults, abstract: [], tags: tagIds, text: textIds)
            await loadSearchFacts(for: first.ids)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                searchResults = first.ids
                noteResults = notes
                searchReasons = first.reasons
                searchFilter = .all
                isSearching = false
                isRefiningSearch = waitsForAbstract
                RecentSearches.add(trimmed)
                recentSearches = RecentSearches.load()
                PerfLog.log("搜尋", since: timingStart, count: first.ids.count, note: trimmed)
            }

            let scoredAbstract = await abstractTask
            let rawAbstract = scoredAbstract.map(\.id)
            guard !Task.isCancelled else { return }
            // 智慧搜尋一定會回傳照片，相簿裡沒有的東西也會塞進不相干的照片：
            // 其他方法都沒找到、智慧搜尋分數又不高（< confidentAbstractScore）的，要照片向量也覺得「至少有點像」才留下
            // （沒辦法檢查時照原本的結果）。分數高的直接顯示：照片向量看不懂情境描述，會把對的照片擋掉。
            let corroborating = Set(clipResults.prefix(300)).union(tagIds).union(textIds)
            let confident = Set(scoredAbstract.filter { $0.score >= Self.confidentAbstractScore }.map(\.id))
            let unverified = rawAbstract.filter { !corroborating.contains($0) && !confident.contains($0) }
            let plausible = await SemanticPhotoSearch.plausibleIds(unverified, query: text)
            let abstractResults = rawAbstract.filter {
                corroborating.contains($0) || confident.contains($0) || (plausible?.contains($0) ?? true)
            }
            print("[抽象搜尋] 智慧搜尋找到 \(rawAbstract.count) 張（分數 ≥ \(Self.confidentAbstractScore) 直接顯示 \(confident.count) 張），"
                  + "照片向量確認後留下 \(abstractResults.count) 張")
            guard !Task.isCancelled else { return }
            guard !abstractResults.isEmpty else {
                await MainActor.run { isRefiningSearch = false }
                if waitsForAbstract { PerfLog.log("搜尋（含智慧搜尋）", since: timingStart, count: first.ids.count, note: trimmed) }
                return
            }
            let merged = Self.mergeSearchResults(clip: clipResults, abstract: abstractResults, tags: tagIds, text: textIds)
            await loadSearchFacts(for: merged.ids)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                searchResults = merged.ids
                searchReasons = merged.reasons
                isRefiningSearch = false
                PerfLog.log("搜尋（含智慧搜尋）", since: timingStart, count: merged.ids.count, note: trimmed)
            }
        }
    }

    /// 分享選取的照片（一次最多 30 張）
    private func shareSelection() {
        let ids = selection.ordered(filteredSearchResults)
        Task {
            let images = await PhotoShareLoader.images(for: ids)
            await MainActor.run {
                if !images.isEmpty { sharePayload = SharePayload(items: images) }
            }
        }
    }

    /// 讀取搜尋結果的拍攝時間、地區、是否截圖（篩選用），以及最近偵測到的旅行
    private func loadSearchFacts(for ids: [String]) async {
        let known = await MainActor.run { searchFacts }
        let missing = ids.filter { known[$0] == nil }
        let needsTrips = await MainActor.run { searchTrips.isEmpty }
        let (facts, trips) = await Task.detached(priority: .userInitiated) { () -> ([String: PhotoSearchFacts], [DetectedTrip]?) in
            let facts = DatabaseManager.shared.searchFacts(for: missing)
            let trips = needsTrips ? DatabaseManager.shared.recentTripDetection(maxAge: 3600)?.trips : nil
            return (facts, trips)
        }.value
        await MainActor.run {
            if !facts.isEmpty { searchFacts.merge(facts) { _, new in new } }
            if let trips { searchTrips = trips }
        }
    }

    /// 合併各種搜尋方法的結果（排名融合）與「找到的原因」
    static func mergeSearchResults(clip clipResults: [String], abstract abstractResults: [String],
                                   tags tagIds: [String], text textIds: [String]) -> (ids: [String], reasons: [String: Set<SearchReason>]) {
        // 智慧搜尋只看「已分析過」的照片，分析的照片還少時容易把不相關的照片排到前面。
        // 有其他方法佐證的（照片向量前 300 名、tag 或文字也找到）照常計分；只有智慧搜尋找到的降低權重。
        let corroborating = Set(clipResults.prefix(300)).union(tagIds).union(textIds)
        let abstractConfirmed = abstractResults.filter { corroborating.contains($0) }
        let abstractOnly = abstractResults.filter { !corroborating.contains($0) }

        // 合併結果（排名融合）：被多種方法同時找到的照片排在前面。
        // 文字完全符合是很明確的證據，權重和向量搜尋相同。
        let merged = fuseRankings([
            (abstractConfirmed, 1.0),
            (abstractOnly, 0.3),
            (clipResults, 1.0),
            (textIds, 1.0),
            (tagIds, 0.8),
        ])

        // 找到的原因（顯示在縮圖上，讓使用者知道為什麼這張會出現）
        var reasons: [String: Set<SearchReason>] = [:]
        for id in textIds { reasons[id, default: []].insert(.text) }
        for id in tagIds { reasons[id, default: []].insert(.tag) }
        for id in abstractResults { reasons[id, default: []].insert(.scene) }
        return (merged, reasons)
    }

    /// Reciprocal Rank Fusion：每份結果依名次給分（權重 ÷ (60 + 名次)），加總後排序。
    /// 不需要把不同方法的分數換算到同一個尺度；同時出現在多份結果的照片自然排前面。
    static func fuseRankings(_ lists: [(ids: [String], weight: Double)], k: Double = 60) -> [String] {
        var scores: [String: Double] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0
        for list in lists {
            for (rank, id) in list.ids.enumerated() {
                scores[id, default: 0] += list.weight / (k + Double(rank + 1))
                if firstSeen[id] == nil {
                    firstSeen[id] = order
                    order += 1
                }
            }
        }
        return scores.keys.sorted {
            let a = scores[$0]!, b = scores[$1]!
            return a != b ? a > b : firstSeen[$0]! < firstSeen[$1]!
        }
    }

    private func submitCustomAlbumName() {
        let trimmed = pendingCustomAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            customAlbumErrorMessage = "請輸入相簿名稱。"
            return
        }

        guard !DatabaseManager.shared.customAlbumExists(named: trimmed) else {
            customAlbumErrorMessage = "已經有名為「\(trimmed)」的相簿。"
            return
        }

        showCreateCustomAlbumSheet = false
        pendingCustomAlbumName = ""
        isPreparingCustomAlbum = true
        // 搜尋結果「存成相簿」：直接用目前（篩選後）的結果，不重新搜尋
        let givenIds = pendingAlbumAssetIds
        pendingAlbumAssetIds = nil

        Task {
            let results = await Task.detached(priority: .userInitiated) { () -> [String] in
                if let givenIds { return givenIds }
                return await SemanticPhotoSearch.search(query: trimmed)
            }.value

            await MainActor.run {
                isPreparingCustomAlbum = false
                customAlbumDraft = CustomAlbumDraft(title: trimmed, initialAssetIds: results)
            }
        }
    }

    private func categorySummaries(for subCategories: [String]) -> [CategoryAlbumSummary] {
        subCategories.map { subCategory in
            let assetIds = DatabaseManager.shared.fetchPhotos(for: subCategory)
            return CategoryAlbumSummary(
                id: subCategory,
                title: subCategory,
                coverAssetId: assetIds.first,
                photoCount: assetIds.count
            )
        }
        .filter { $0.photoCount > 0 }
    }
}

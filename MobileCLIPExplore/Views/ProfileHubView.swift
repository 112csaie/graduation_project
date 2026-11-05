// ProfileHubView.swift
//
// 「我的」：底部的「我的」分頁。集中放跟自己有關的內容——本月摘要、我的紀錄（興趣日曆、想去、想買、筆記）、
// 最近的對話、興趣與分類偏好，最下面是「設定」。「最愛」移到底部自己的分頁（FavoritesTabView）。
// 配色跟著深色模式（Theme），右上角可以直接切換。只讀取 App 自己的資料與照片縮圖，不修改照片。

import Combine
import Photos
import SwiftUI

struct ProfileHubView: View {
    /// 當作底部分頁顯示（沒有「完成」按鈕）；false 是從其他地方用 sheet 打開
    var isTab = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncVM: PhotoSyncViewModel
    @AppStorage("userName") private var userName = ""
    @ObservedObject private var wishList = WishListService.shared
    @ObservedObject private var shopping = ShoppingListService.shared

    @State private var notes: [WikiItem] = []
    @State private var noteCovers: [String: String] = [:]      // 主題 → 封面照片
    @State private var conversations: [ConversationSummary] = []
    @State private var photoCount = 0
    @State private var monthPhotoCount = 0
    @State private var trackers: [TrackerSnapshot] = []
    @State private var trackersLoaded = false
    @State private var filter: RecordFilter = .all

    @State private var showWishList = false
    @State private var showShoppingList = false
    @State private var openedNote: WikiItem?
    @State private var openedTracker: TrackerSnapshot?
    @State private var showAvatarEditor = false
    /// 想去清單點一下：看當初加入的那張截圖
    @State private var viewingWishPhoto: IdentifiableString?
    @State private var showPreferences = false
    @State private var showConversations = false
    /// 追星足跡（見 FandomViews.swift）
    @State private var fandomShows: [FandomShow] = []
    @State private var showFandom = false

    /// 「我的紀錄」上方可以左右滑的分類
    enum RecordFilter: String, CaseIterable, Identifiable {
        case all = "全部", trackers = "打卡", wish = "想去", shopping = "想買", notes = "筆記"
        var id: String { rawValue }
    }

    private let today = Date()
    private var month: Int { Calendar.current.component(.month, from: today) }

    /// 這個月有紀錄的興趣排前面
    private var sortedTrackers: [TrackerSnapshot] {
        trackers.sorted { activeDays($0) > activeDays($1) }
    }
    private var activeTrackers: [TrackerSnapshot] { sortedTrackers.filter { activeDays($0) > 0 } }

    /// 有封面照片的筆記（旅行回憶、對話時附照片存的筆記）排在前面
    private var sortedNotes: [WikiItem] {
        notes.filter { noteCovers[$0.topic] != nil } + notes.filter { noteCovers[$0.topic] == nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    summaryCard
                    recordsHeader
                    recordsContent
                    conversationSection
                    linkRow(icon: "square.grid.2x2", title: "興趣與分類偏好", subtitle: "決定首頁優先整理哪些分類") {
                        showPreferences = true
                    }
                    NavigationLink(destination: PrivacyView().toolbar(.visible, for: .navigationBar)) {
                        linkRowLabel(icon: "lock", title: "隱私",
                                     subtitle: AIRouter.onDevice ? "照片和文字都留在這支手機" : "哪些在手機上、哪些會送到後端")
                    }
                    .buttonStyle(.plain)
                    settingsLink
                    // App 名稱與 Slogan
                    VStack(spacing: 4) {
                        SelfieWordmark(size: 24)
                        Text(AppBrand.slogan)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Theme.background.ignoresSafeArea())
            // 標題列改在頁面裡（頭像、深色模式按鈕；從 sheet 打開時多一個「完成」）
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Theme.text)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .wikiNotesUpdated)) { _ in Task { await load() } }
        // tag 改了（例如在照片頁移除 tag）：打卡紀錄重新計算
        .onReceive(NotificationCenter.default.publisher(for: .personalizationUpdated)) { _ in
            Task {
                let loaded = await InterestTrackerLoader.loadAll()
                await MainActor.run { trackers = loaded }
            }
        }
        // 分頁一直存在：切到「我的」時重新整理（清單、對話、紀錄可能在別的分頁改過）
        .onReceive(AppRouter.shared.$selectedTab) { tab in
            if isTab && tab == AppTab.me { Task { await load() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeOverlaysForAgent)) { _ in
            if !isTab { dismiss() }
        }
        // 演出場次、照片文字（票券）更新後：追星足跡重新整理
        .onReceive(NotificationCenter.default.publisher(for: .liveEventsUpdated)) { _ in Task { await loadFandom() } }
        .onReceive(NotificationCenter.default.publisher(for: .photoTextUpdated)) { _ in Task { await loadFandom() } }
        .sheet(isPresented: $showFandom) { FandomFootprintView(shows: fandomShows, syncVM: syncVM) }
        .sheet(isPresented: $showWishList) { WishListView() }
        .sheet(isPresented: $showShoppingList) { ShoppingListView() }
        .sheet(item: $openedNote) { note in WikiNoteDetailView(item: note) }
        .sheet(isPresented: $showAvatarEditor) { AvatarEditorSheet(name: userName) }
        .sheet(item: $viewingWishPhoto) { item in
            // 分享進來的截圖存在 App 裡（不在相簿）
            if SharedScreenshotStore.isShared(item.id) {
                SharedScreenshotView(ref: item.id)
            } else {
                PhotoDetailModal(assetId: item.id)
            }
        }
        .sheet(item: $openedTracker) { snapshot in
            InterestTrackerDetailView(tracker: snapshot.tracker, initial: snapshot)
        }
        .sheet(isPresented: $showPreferences) {
            PersonalizationSetupView(mode: .settings) { showPreferences = false }
        }
        .sheet(isPresented: $showConversations) {
            RecentConversationsView(currentConversationId: "") { id in
                AppRouter.shared.openConversation(id)
                if !isTab { dismiss() }
            }
        }
    }

    // MARK: 頭像與摘要

    private var displayName: String {
        let name = userName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "你/妳" : name
    }

    private var header: some View {
        HStack(spacing: 12) {
            // 頭貼：點了可以重新設計
            Button(action: { showAvatarEditor = true }) {
                UserAvatarView(name: userName, size: 52)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("設計頭貼")
            VStack(alignment: .leading, spacing: 2) {
                Text("嗨，\(displayName)")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
                Text(photoCount > 0 ? "已經幫你/妳整理 \(OrganizingStatusBar.count(photoCount)) 張照片" : "今天也幫你/妳整理照片")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(Theme.secondaryText)
            }
            Spacer()
            if !isTab {
                Button("完成") { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.text)
            }
            AppearanceToggleButton()
        }
        .padding(.top, 6)
    }

    /// 本月摘要：左邊筆記／想去／去過，右邊大數字是這個月拍的照片
    private var summaryCard: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(month) 月")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
                Text("筆記 \(notes.count)・想去 \(wishList.wantCount)・去過 \(wishList.places.count - wishList.wantCount)")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(Theme.secondaryText)
                if !activeTrackers.isEmpty {
                    Label("\(activeTrackers.count) 個紀錄有進度", systemImage: "calendar")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(Theme.secondaryText)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(monthPhotoCount)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
                    .contentTransition(.numericText())
                Text("這個月的照片")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(Theme.secondaryText)
            }
        }
        .padding(16)
        .themeCard()
    }

    // MARK: 我的紀錄

    private var recordsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("我的紀錄")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Theme.text)
                .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RecordFilter.allCases) { item in
                        ThemeChip(title: item.rawValue, isSelected: filter == item) {
                            withAnimation(.easeInOut(duration: 0.2)) { filter = item }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recordsContent: some View {
        switch filter {
        case .all:
            tileGrid(trackers: activeTrackers, includeLists: true)
            notesRow
        case .trackers:
            if trackersLoaded && trackers.isEmpty {
                hint("在「興趣與分類偏好」選擇興趣後，這裡會出現對應的紀錄，例如健身日曆、觀影與看展。")
            } else {
                tileGrid(trackers: sortedTrackers, includeLists: false)
            }
        case .wish:
            wishPreview
        case .shopping:
            shoppingPreview
        case .notes:
            notesGrid
        }
    }

    private func tileGrid(trackers: [TrackerSnapshot], includeLists: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(trackers) { snapshot in
                let days = activeDays(snapshot)
                let streak = snapshot.calendar.weekStreak(asOf: today)
                tile(icon: snapshot.tracker.icon,
                     pill: streak >= 2 ? "連續 \(streak) 週" : "\(days) 天",
                     title: snapshot.tracker.titleZh,
                     subtitle: "本月 \(days) 天") { openedTracker = snapshot }
            }
            if includeLists {
                tile(icon: "mappin.and.ellipse", pill: "\(wishList.wantCount)", title: "想去清單",
                     subtitle: wishSummary) { showWishList = true }
                tile(icon: "bag", pill: "\(shopping.wantCount)", title: "購物清單",
                     subtitle: shoppingSummary) { showShoppingList = true }
                tile(icon: "music.mic", pill: fandomShows.isEmpty ? nil : "\(fandomShows.count) 場", title: "追星足跡",
                     subtitle: FandomLoader.footprintSubtitle(fandomShows)) { showFandom = true }
            }
        }
    }

    private func tile(icon: String, pill: String?, title: String, subtitle: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ThemeIcon(systemName: icon)
                    Spacer(minLength: 4)
                    if let pill { AccentPill(text: pill) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .themeCard(Theme.tile)
        }
        .buttonStyle(.plain)
    }

    private var wishSummary: String {
        let groups = WishRegion.group(wishList.places.filter { !$0.isVisited }, hints: wishList.regionHints)
        guard !groups.isEmpty else { return "還沒有想去的地方" }
        return groups.prefix(2).map { "\($0.region) \($0.places.count)" }.joined(separator: "・")
    }

    private var shoppingSummary: String {
        let groups = shopping.pendingByCountry
        guard !groups.isEmpty else { return "還沒有想買的東西" }
        return groups.prefix(2).map { "\(ShoppingCountry.name(for: $0.code)) \($0.items.count) 樣" }.joined(separator: "・")
    }

    /// 「全部」最下面的筆記列：點了切到「筆記」
    private var notesRow: some View {
        Button(action: { withAnimation { filter = .notes } }) {
            HStack(spacing: 10) {
                ThemeIcon(systemName: "book.pages")
                Text("回憶與筆記")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
                Spacer()
                Text("\(notes.count) 篇")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(Theme.secondaryText)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
            }
            .padding(12)
            .themeCard()
        }
        .buttonStyle(.plain)
    }

    // 「想去」：依縣市分組，右邊「出發」直接開地圖
    private var wishPreview: some View {
        let want = wishList.places.filter { !$0.isVisited }
        return VStack(alignment: .leading, spacing: 0) {
            if want.isEmpty {
                hint("在店家或景點截圖的照片頁按「清單」→「想去」，就會出現在這裡；之後在附近拍照會自動打勾。")
            } else {
                ForEach(WishRegion.group(want, hints: wishList.regionHints).prefix(4), id: \.region) { group in
                    Text("\(group.region)（\(group.places.count)）")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.secondaryText)
                        .padding(.top, 8)
                    ForEach(group.places.prefix(4)) { place in
                        HStack(spacing: 10) {
                            ThemeIcon(systemName: "mappin")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundColor(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                if place.category != "其他" || !place.area.isEmpty {
                                    Text([place.category == "其他" ? nil : place.category, place.area.isEmpty ? nil : place.area]
                                            .compactMap { $0 }.joined(separator: "・"))
                                        .font(.system(size: 12, design: .rounded))
                                        .foregroundColor(Theme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            Button(action: { MapOpener.open(place) }) { GoButtonLabel() }
                            .buttonStyle(.plain)
                            .accessibilityLabel("用地圖打開 \(place.name)")
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let source = place.sourceAssetId {
                                viewingWishPhoto = IdentifiableString(id: source)
                            } else {
                                MapOpener.open(place)
                            }
                        }
                    }
                }
            }
            seeAllButton("查看全部想去的地方") { showWishList = true }
        }
        .padding(14)
        .themeCard()
    }

    private var shoppingPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            let groups = shopping.pendingByCountry
            if groups.isEmpty {
                hint("在商品截圖的照片頁按「清單」→「想買」，就會出現在這裡，依國家分好。")
            } else {
                ForEach(groups.prefix(5), id: \.code) { group in
                    Button(action: { showShoppingList = true }) {
                        HStack(spacing: 10) {
                            ThemeIcon(systemName: "bag")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ShoppingCountry.name(for: group.code))
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundColor(Theme.text)
                                Text(group.items.prefix(3).map(\.name).joined(separator: "、"))
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundColor(Theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            AccentPill(text: "\(group.items.count)")
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            seeAllButton("查看全部想買的東西") { showShoppingList = true }
        }
        .padding(14)
        .themeCard()
    }

    // 「筆記」：有封面的兩欄大卡，其他列在下面
    @ViewBuilder
    private var notesGrid: some View {
        if notes.isEmpty {
            hint("打開旅行或演唱會相簿，按「整理成回憶筆記」，或在 Agent 對話裡存筆記，就會出現在這裡。")
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(sortedNotes) { note in
                    Button(action: { openedNote = note }) {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                Theme.tile
                                if let cover = noteCovers[note.topic] {
                                    PhotoThumbnailView(assetId: cover)
                                } else {
                                    Image(systemName: "book.pages")
                                        .font(.system(size: 26))
                                        .foregroundColor(Theme.secondaryText)
                                }
                            }
                            .frame(height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Text(note.topic)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(Theme.text)
                                .lineLimit(2)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                        .padding(6)
                        .themeCard(radius: 18)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 最近的對話

    @ViewBuilder
    private var conversationSection: some View {
        if !conversations.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("最近的對話")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.text)
                    Spacer()
                    Button("全部") { showConversations = true }
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.secondaryText)
                }
                .padding(.bottom, 4)
                ForEach(conversations.prefix(3)) { conversation in
                    Button(action: {
                        AppRouter.shared.openConversation(conversation.id)
                        if !isTab { dismiss() }
                    }) {
                        HStack(spacing: 10) {
                            ThemeIcon(systemName: "bubble.left", size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.title)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(2)
                                if !conversation.preview.isEmpty {
                                    Text(conversation.preview)
                                        .font(.system(size: 12, design: .rounded))
                                        .foregroundColor(Theme.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(RecentConversationsView.formatDate(conversation.updatedAt))
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(Theme.secondaryText)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .themeCard()
            .padding(.top, 6)
        }
    }

    // MARK: 偏好與設定

    /// 設定（以前是底部的「設定」分頁）
    private var settingsLink: some View {
        NavigationLink(destination: SettingView().environmentObject(syncVM)
                        .toolbar(.visible, for: .navigationBar)
                        .navigationTitle("設定")
                        .navigationBarTitleDisplayMode(.inline)) {
            linkRowLabel(icon: "gearshape", title: "設定", subtitle: "深色模式、同步照片、智慧搜尋、Agent 伺服器")
        }
        .buttonStyle(.plain)
    }

    private func linkRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { linkRowLabel(icon: icon, title: title, subtitle: subtitle) }
            .buttonStyle(.plain)
    }

    private func linkRowLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            ThemeIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
                Text(subtitle)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
        }
        .padding(12)
        .themeCard()
        .contentShape(Rectangle())
    }

    // MARK: 元件

    private func seeAllButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right")
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, design: .rounded))
            .foregroundColor(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func activeDays(_ snapshot: TrackerSnapshot) -> Int {
        snapshot.calendar.activeDays(inMonthOf: today).count
    }

    // MARK: 讀取

    private func load() async {
        wishList.reload()
        shopping.reload()
        let list = (try? await WikiService.shared.list(limit: 500)) ?? []
        var covers: [String: String] = [:]
        for note in list.prefix(30) {
            if let cover = await WikiService.shared.cover(topic: note.topic) { covers[note.topic] = cover.assetId }
        }
        let recent = await ConversationService.shared.list()
        let counts = await Task.detached(priority: .utility) { () -> (Int, Int) in
            let total = PHAsset.fetchAssets(with: .image, options: nil).count
            let options = PHFetchOptions()
            let start = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
            options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
            return (total, PHAsset.fetchAssets(with: .image, options: options).count)
        }.value
        let loadedTrackers = await InterestTrackerLoader.loadAll()
        await MainActor.run {
            // 想去、購物清單的筆記由 App 自動整理，不在筆記列表顯示，也不算進筆記數
            notes = list.filter { !ListNotes.isListNote($0.topic) }
            noteCovers = covers
            conversations = recent
            photoCount = counts.0
            withAnimation { monthPhotoCount = counts.1 }
            trackers = loadedTrackers
            trackersLoaded = true
        }
        // 場次還沒算過（剛開 App）時先請它算；算好會收到 liveEventsUpdated 再更新
        LiveEventCenter.shared.refreshIfNeeded()
        await loadFandom()
    }

    private func loadFandom() async {
        let shows = await Task.detached(priority: .utility) { FandomLoader.loadShows() }.value
        await MainActor.run { fandomShows = shows }
    }
}

// MARK: - 最愛（底部分頁）

/// 在照片頁按「最愛」的照片：最新收藏的一張是大卡片，其他依照片原本的比例排成兩欄瀑布流（直的長、橫的短），
/// 點開可以左右滑。只讀取 App 自己記的最愛清單與照片縮圖。
struct FavoritesTabView: View {
    @State private var favoriteIds: [String] = []
    @State private var info: [String: FavoriteInfo] = [:]
    @State private var isLoaded = false
    @State private var viewing: IdentifiableString?

    struct FavoriteInfo {
        /// 高 ÷ 寬（限制在 0.75～1.5，太長太扁的照片不會撐爆版面）
        let ratio: CGFloat
        let date: Date?
    }

    private var rest: [String] { Array(favoriteIds.dropFirst()) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if isLoaded && favoriteIds.isEmpty {
                    emptyState
                } else if let first = favoriteIds.first {
                    heroCard(first)
                    if !rest.isEmpty {
                        masonry
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .task { await load() }
        .onReceive(AppRouter.shared.$selectedTab) { tab in
            if tab == AppTab.favorites { Task { await load() } }
        }
        // 「照片」App 的喜好項目同步進來（或其他地方改了最愛）時，停在這頁也會馬上更新
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DatabaseUpdated"))
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in
            Task { await load() }
        }
        // 關掉時重新整理（可能取消了最愛）
        .sheet(item: $viewing, onDismiss: { Task { await load() } }) { item in
            PhotoDetailModal(assetId: item.id, browseAssetIds: favoriteIds)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("最愛")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(Theme.text)
                Text(favoriteIds.isEmpty ? "喜歡的照片收在這裡" : "收藏了 \(favoriteIds.count) 張喜歡的照片")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryText)
            }
            Spacer()
        }
        .padding(.top, 14)
        .padding(.horizontal, 4)
    }

    /// 最新收藏：整張寬的大卡片，下方淡淡漸層寫上日期
    private func heroCard(_ id: String) -> some View {
        Button(action: { viewing = IdentifiableString(id: id) }) {
            Theme.tile
                .frame(height: 280)
                .overlay(PhotoThumbnailView(assetId: id, pixelSize: 1000))
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("最新收藏")
                            .font(.system(size: 18, weight: .heavy))
                        if let date = info[id]?.date {
                            Text(PhotoDaySection.title(for: date))
                                .font(.system(size: 13, weight: .semibold))
                                .opacity(0.85)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(16)
                }
                .overlay(alignment: .topTrailing) { heartBadge(size: 34).padding(12) }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 兩欄瀑布流：每張放到目前比較短的那一欄
    private var masonry: some View {
        let columns = Self.split(rest, ratios: info.mapValues(\.ratio))
        return HStack(alignment: .top, spacing: 10) {
            ForEach(0..<2, id: \.self) { column in
                LazyVStack(spacing: 10) {
                    ForEach(columns[column], id: \.self) { id in
                        Button(action: { viewing = IdentifiableString(id: id) }) {
                            Theme.tile
                                .aspectRatio(1 / (info[id]?.ratio ?? 1), contentMode: .fit)
                                .overlay(PhotoThumbnailView(assetId: id, pixelSize: 500))
                                .overlay(alignment: .topTrailing) { heartBadge(size: 24).padding(8) }
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func heartBadge(size: CGFloat) -> some View {
        Image(systemName: "heart.fill")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundColor(Theme.onAccent)
            .frame(width: size, height: size)
            .background(Theme.accent)
            .clipShape(Circle())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart")
                .font(.system(size: 34, weight: .medium))
                .foregroundColor(Theme.onAccent)
                .frame(width: 76, height: 76)
                .background(Theme.accent)
                .clipShape(Circle())
            Text("還沒有最愛的照片")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Theme.text)
            Text("在照片頁按愛心，喜歡的照片就會收在這裡。")
                .font(.system(size: 13))
                .foregroundColor(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    /// 依高度分兩欄（順序大致保持由新到舊）
    static func split(_ ids: [String], ratios: [String: CGFloat]) -> [[String]] {
        var columns: [[String]] = [[], []]
        var heights: [CGFloat] = [0, 0]
        for id in ids {
            let column = heights[0] <= heights[1] ? 0 : 1
            columns[column].append(id)
            heights[column] += ratios[id] ?? 1
        }
        return columns
    }

    private func load() async {
        let (ids, loaded) = await Task.detached(priority: .userInitiated) { () -> ([String], [String: FavoriteInfo]) in
            let ids = DatabaseManager.shared.favoriteAssetIds(limit: 5000)
            var map: [String: FavoriteInfo] = [:]
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
                let ratio = asset.pixelWidth > 0 ? CGFloat(asset.pixelHeight) / CGFloat(asset.pixelWidth) : 1
                map[asset.localIdentifier] = FavoriteInfo(ratio: min(max(ratio, 0.75), 1.5), date: asset.creationDate)
            }
            return (ids, map)
        }.value
        await MainActor.run {
            favoriteIds = ids
            info = loaded
            isLoaded = true
        }
    }
}

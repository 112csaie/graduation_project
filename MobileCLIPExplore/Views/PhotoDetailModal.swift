import SwiftUI
import Photos
import CoreLocation
import VisionKit

/// 照片頁：可以左右滑到同一個清單裡的上一張／下一張。
/// 上方是關閉、第幾張、分享；照片是圓角大卡；下面是日期地點貼紙、一排圓形動作（問 Agent 是亮色），
/// 再來是照片中的文字、所屬筆記與 tag。配色跟著深色模式（Theme）。
/// 只讀取照片；最愛、tag、筆記等都是 App 自己的資料，不會修改或刪除原始照片。
struct PhotoDetailModal: View {
    let assetId: String
    /// 從筆記頁的照片瀏覽打開時設 false：那裡疊了好幾層畫面，不適合直接跳到 Agent 分頁
    var showsAgentActions: Bool = true
    /// 可以左右滑動瀏覽的照片清單（例如整本相簿、搜尋結果）；空的時候只看這一張
    var browseAssetIds: [String] = []

    @Environment(\.dismiss) var dismiss
    @State private var scrolledId: String?
    @State private var currentId: String
    @State private var isZoomed = false
    /// 按「文字」：在照片上標出讀到的文字，可以直接選取、複製（原況文字，手機上辨識）
    @State private var liveTextOn = false
    /// 目前前後各幾張的「視窗」：整本相簿有幾千張時，一次只放這幾十張進滑動列，打開就能馬上滑
    @State private var window: [String]
    @State private var currentIndex: Int
    /// 下方資訊（動作、日期地點、文字、tag）目前顯示哪一張：停下來一下才換，
    /// 連續快速滑動時不會每經過一張就重建整個資訊區（那會卡住下一次滑動）
    @State private var infoId: String
    @State private var infoTask: Task<Void, Never>?

    /// 視窗大小：目前這張前後各 windowRadius 張；滑到離邊緣 refillMargin 張以內就往前／往後補
    private static let windowRadius = 15
    private static let refillMargin = 4

    init(assetId: String, showsAgentActions: Bool = true, browseAssetIds: [String] = []) {
        self.assetId = assetId
        self.showsAgentActions = showsAgentActions
        self.browseAssetIds = browseAssetIds
        let index = browseAssetIds.firstIndex(of: assetId)
        _currentId = State(initialValue: assetId)
        _infoId = State(initialValue: assetId)
        _scrolledId = State(initialValue: assetId)
        _currentIndex = State(initialValue: index ?? 0)
        _window = State(initialValue: index.map { Self.window(around: $0, in: browseAssetIds) } ?? [assetId])
    }

    private var isBrowsing: Bool { browseAssetIds.count > 1 && browseAssetIds.contains(currentId) }

    private var positionText: String? {
        guard isBrowsing else { return nil }
        return "\(currentIndex + 1) / \(browseAssetIds.count)"
    }

    private static func window(around index: Int, in ids: [String]) -> [String] {
        guard !ids.isEmpty else { return [] }
        let lower = max(0, index - windowRadius)
        let upper = min(ids.count - 1, index + windowRadius)
        return Array(ids[lower...upper])
    }

    /// 換到另一張：更新位置；接近視窗邊緣時重新以目前這張為中心取一段（捲動位置以照片 ID 固定，不會跳）
    private func didScroll(to id: String) {
        currentId = id
        infoTask?.cancel()
        infoTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            infoId = id
        }
        guard browseAssetIds.count > 1 else { return }
        defer { PhotoPageImageCache.prefetch(around: currentIndex, in: browseAssetIds) }
        // 先在視窗附近找，找不到才整份清單找
        if let local = window.firstIndex(of: id), let first = window.first,
           let base = browseAssetIds.firstIndex(of: first) {
            currentIndex = base + local
            let nearStart = local < Self.refillMargin && base > 0
            let nearEnd = local >= window.count - Self.refillMargin && base + window.count < browseAssetIds.count
            if nearStart || nearEnd { window = Self.window(around: currentIndex, in: browseAssetIds) }
        } else if let index = browseAssetIds.firstIndex(of: id) {
            currentIndex = index
            window = Self.window(around: index, in: browseAssetIds)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 10)

                    // 照片：左右滑動（LazyHStack 只載入看得到的幾張，整本相簿也不會卡）；整塊是圓角大卡
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(window, id: \.self) { id in
                                PhotoPageImage(assetId: id, isZoomed: $isZoomed, liveText: liveTextOn && id == currentId)
                                    .containerRelativeFrame(.horizontal)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $scrolledId)
                    .scrollDisabled(isZoomed || liveTextOn)   // 放大或選文字時拖曳照片，不換頁
                    .scrollIndicators(.hidden)
                    .frame(height: UIScreen.main.bounds.height * 0.44)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                    .padding(.horizontal, 12)
                    .onChange(of: scrolledId) { _, newValue in
                        if let newValue { didScroll(to: newValue) }
                        isZoomed = false
                        liveTextOn = false
                    }

                    ScrollView(showsIndicators: false) {
                        PhotoDetailInfo(assetId: infoId, showsAgentActions: showsAgentActions,
                                        onAskAgent: {
                                            // 會關掉這一頁和疊在下面的筆記頁、照片瀏覽，切到 Agent 對話
                                            AppRouter.shared.askAgent(aboutPhoto: currentId)
                                        },
                                        liveTextOn: $liveTextOn)
                            .id(infoId)   // 換照片（停下來之後）時，下方資訊全部重新讀取
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeOverlaysForAgent)) { _ in dismiss() }
            .onAppear { PhotoPageImageCache.prefetch(around: currentIndex, in: browseAssetIds) }
            .sheet(item: $sharePayload) { payload in ShareSheet(items: payload.items) }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// 上方：關閉、第幾張（亮色小標籤）、分享
    private var topBar: some View {
        HStack {
            HeaderIconButton(systemName: "chevron.down", label: "關閉") { dismiss() }
            Spacer()
            if let positionText {
                Text(positionText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.info)
                    .clipShape(Capsule())
                    .contentTransition(.numericText())
            } else {
                Text("照片")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Theme.text)
            }
            Spacer()
            HeaderIconButton(systemName: "square.and.arrow.up", label: "分享") { shareCurrent() }
        }
    }

    @State private var sharePayload: SharePayload?

    private func shareCurrent() {
        let id = currentId
        Task {
            if let image = await PhotoDetailInfo.loadImage(assetId: id, side: 2400) {
                await MainActor.run { sharePayload = SharePayload(items: [image]) }
            }
        }
    }
}

/// 一張照片（滑動頁面用）
/// 平常用螢幕大小的版本（已在背景解碼好，滑到時不會卡住滑動）；放大時才換成高解析度。
private struct PhotoPageImage: View {
    let assetId: String
    @Binding var isZoomed: Bool
    /// 在照片上標出文字、可以選取複製
    var liveText = false
    @State private var image: UIImage?
    @State private var isHighRes = false
    @State private var textStatus: String?

    var body: some View {
        ZStack {
            Theme.card
            if let image {
                if liveText {
                    LiveTextImageView(image: image) { found in
                        withAnimation { textStatus = found ? "拖曳選取文字，或按右下角全部複製" : "這張照片沒有偵測到文字" }
                    }
                    .overlay(alignment: .top) {
                        Text(textStatus ?? "正在讀取照片上的文字…")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.onAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                            .padding(.top, 12)
                            .transition(.opacity)
                    }
                    .onDisappear { textStatus = nil }
                } else {
                    ZoomableImage(image: image, isZoomed: $isZoomed)
                }
            } else {
                ProgressView().tint(Theme.text)
            }
        }
        .task(id: assetId) {
            isHighRes = false
            if let cached = PhotoPageImageCache.cached(assetId) { image = cached; return }
            image = await PhotoPageImageCache.image(for: assetId)
        }
        .task(id: isZoomed) {
            // 放大：換成高解析度（只有目前這張會放大）
            guard isZoomed, !isHighRes, image != nil else { return }
            if let sharp = await PhotoPageImageCache.highResolution(for: assetId) {
                image = sharp
                isHighRes = true
            }
        }
    }
}

/// 滑動頁面的照片快取：讀取螢幕大小的版本並在背景先解碼，前後幾張先準備好。只讀取照片。
enum PhotoPageImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        return cache
    }()
    private static let lock = NSLock()
    private static var loading = Set<String>()

    /// 螢幕上的照片區塊大約 1300 × 1200 像素（最大的 iPhone），長邊 1600 就夠清楚；放大時才讀高解析度
    private static let displaySide: CGFloat = 1600

    static func cached(_ assetId: String) -> UIImage? { cache.object(forKey: assetId as NSString) }

    static func image(for assetId: String) async -> UIImage? {
        if let cached = cached(assetId) { return cached }
        guard let raw = await PhotoDetailInfo.loadImage(assetId: assetId, side: displaySide) else { return nil }
        // 在背景解碼，顯示時不用在主執行緒解碼（大張 HEIC 解碼會讓滑動卡一下）
        let prepared = await raw.byPreparingForDisplay() ?? raw
        cache.setObject(prepared, forKey: assetId as NSString)
        return prepared
    }

    static func highResolution(for assetId: String) async -> UIImage? {
        guard let raw = await PhotoDetailInfo.loadImage(assetId: assetId, side: 3000) else { return nil }
        return await raw.byPreparingForDisplay() ?? raw
    }

    /// 先準備好前後各一張
    static func prefetch(around index: Int, in ids: [String]) {
        guard ids.count > 1 else { return }
        for offset in [1, -1, 2] {
            let i = index + offset
            guard ids.indices.contains(i) else { continue }
            let id = ids[i]
            lock.lock()
            let skip = cached(id) != nil || loading.contains(id)
            if !skip { loading.insert(id) }
            lock.unlock()
            guard !skip else { continue }
            Task.detached(priority: .utility) {
                _ = await image(for: id)
                lock.lock(); loading.remove(id); lock.unlock()
            }
        }
    }
}

/// 目前這張照片的動作與資訊
private struct PhotoDetailInfo: View {
    let assetId: String
    let showsAgentActions: Bool
    let onAskAgent: () -> Void
    /// 照片上的原況文字開關（支援的手機用這個；不支援時退回下方的文字卡片）
    @Binding var liveTextOn: Bool

    @State private var dateString: String?
    @State private var locationString: String?
    @State private var isFavorite = false

    @State private var noteTopics: [String] = []
    @State private var openNote: WikiItem?

    @State private var photoText: String?          // nil = 還沒辨識；"" = 沒有文字
    @State private var showsFullText = false
    /// 「照片中的文字」平常收起來（字太多會蓋過重點），按「文字」才展開
    @State private var showsText = false
    @State private var messageCanAddManually = false
    @State private var showManualAdd = false
    @State private var isRecognizingText = false

    @State private var isAddingWish = false
    @State private var showWishList = false
    @State private var isAddingShopping = false
    @State private var showShoppingList = false
    @State private var showSimilar = false
    @State private var messageCanOpenShoppingList = false
    @State private var sharePayload: SharePayload?
    @State private var message: String?            // 動作結果（想去清單、辨識失敗…）
    @State private var messageCanOpenWishList = false
    /// 剛才在手機上整理：結果不準時可以「用後端再整理一次」（shopping / wish）
    @State private var messageRedoKind: String?
    @ObservedObject private var connection = AgentConnection.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            metaLine
            actionBar
            if connection.isOffline {
                // 支援手機上 AI 的手機：清單整理在手機上做，只有「問 Agent」需要電腦
                AgentOfflineNotice(feature: AIRouter.onDevice ? "問 Agent" : "問 Agent、加入想去／購物清單",
                                   stillWorks: AIRouter.onDevice ? "加入清單、文字、最愛、分享" : "文字辨識、最愛、分享")
            }

            if let message { messageToast(message) }

            if showsText { photoTextCard }
            notesCard

            // 個人化分類：tag、主題相簿、重新分析、移除 AI 分析資料（不影響原始照片）
            PhotoAIPanel(assetId: assetId)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .task { await load() }
        .onAppear { connection.check() }
        .sheet(item: $openNote) { note in WikiNoteDetailView(item: note) }
        .sheet(isPresented: $showWishList) { WishListView() }
        .sheet(isPresented: $showShoppingList) { ShoppingListView() }
        .sheet(isPresented: $showSimilar) { SimilarPhotosView(assetId: assetId) }
        .sheet(item: $sharePayload) { payload in ShareSheet(items: payload.items) }
        .sheet(isPresented: $showManualAdd) {
            ShoppingManualAddView(sourceAssetId: assetId,
                                  suggestedCountry: ShoppingCountry.guess(text: photoText ?? "") ?? "") { name in
                showMessage("已加入購物清單：\(name)", shopping: true)
            }
        }
        // 動作結果幾秒後自動收起（有「查看清單」按鈕的留久一點）
        .task(id: message) {
            guard message != nil else { return }
            let hasAction = messageCanOpenWishList || messageCanOpenShoppingList || messageCanAddManually
            try? await Task.sleep(nanoseconds: (messageRedoKind != nil ? 15 : hasAction ? 10 : 4) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { message = nil }
        }
    }

    // MARK: 日期與地點（一行）

    /// 日期、地點和上方的「第幾張」同一個資訊色（和 Agent 的亮色、背景都不同）
    @ViewBuilder
    private var metaLine: some View {
        if dateString != nil || locationString != nil {
            HStack(spacing: 8) {
                if let dateString {
                    Label(dateString, systemImage: "calendar")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.onAccent)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.info)
                        .clipShape(Capsule())
                }
                if let locationString {
                    Label(locationString, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.onAccent)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.info)
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: 動作結果

    private func showMessage(_ text: String, wish: Bool = false, shopping: Bool = false, manual: Bool = false,
                             redo: String? = nil) {
        messageCanOpenWishList = wish
        messageCanOpenShoppingList = shopping
        messageCanAddManually = manual
        messageRedoKind = redo
        withAnimation { message = text }
    }

    private func messageToast(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: messageCanAddManually ? "questionmark" : "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.onAccent)
                .frame(width: 26, height: 26)
                .background(messageCanAddManually ? Color.orange : Theme.accent)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(Theme.text.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if messageCanOpenWishList {
                Button("查看") { showWishList = true }.font(.system(size: 13, weight: .semibold))
            }
            if messageCanOpenShoppingList {
                Button("查看") { showShoppingList = true }.font(.system(size: 13, weight: .semibold))
            }
            if messageCanAddManually {
                Button("手動加入") { showManualAdd = true }.font(.system(size: 13, weight: .semibold))
            }
        }
            // 在手機上整理的結果不準：使用者自己決定要不要送到開發者的後端
            if let kind = messageRedoKind {
                HStack(spacing: 8) {
                    Text("結果不準？")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                    Button(action: { redoWithBackend(kind) }) {
                        Label("用後端再整理一次", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.onAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 36)
            }
        }
        .foregroundColor(Theme.text)
        .tint(Theme.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .themeCard(radius: 18)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: 動作列

    /// 一排圓形動作：問 Agent 是亮色（和 Agent 分頁同一個 selfIE 圖示），其他是卡片色，開啟中的變亮色
    private var actionBar: some View {
        HStack(alignment: .top, spacing: 0) {
            if showsAgentActions {
                actionButton("問 Agent", icon: "selfie", primary: true, action: onAskAgent)
            }
            actionButton(isRecognizingText ? "辨識中" : "文字", icon: "text.viewfinder",
                         active: LiveTextSupport.isAvailable ? liveTextOn : showsText, busy: isRecognizingText) {
                if LiveTextSupport.isAvailable {
                    // 直接在照片上標出文字，可以選取、複製
                    withAnimation(.easeInOut(duration: 0.2)) { liveTextOn.toggle() }
                } else if photoText == nil {
                    recognizeText()
                } else {
                    withAnimation { showsText.toggle() }
                }
            }
            // 「清單」：想去的地方（店家、景點截圖）或想買的東西（商品截圖）
            Menu {
                Button(action: addToWishList) { Label("想去（店家、景點）", systemImage: "mappin.and.ellipse") }
                Button(action: addToShoppingList) { Label("想買（商品）", systemImage: "bag") }
            } label: {
                actionLabel(isAddingWish || isAddingShopping ? "整理中" : "清單", icon: "list.bullet.rectangle",
                            busy: isAddingWish || isAddingShopping)
            }
            .buttonStyle(.plain)
            .disabled(isAddingWish || isAddingShopping)
            // 相似照片：和這張最像的照片（照片向量比對，手機上就能做）
            actionButton("相似", icon: "square.on.square") { showSimilar = true }
            actionButton("最愛", icon: isFavorite ? "heart.fill" : "heart", active: isFavorite) {
                DatabaseManager.shared.toggleFavorite(assetId: assetId)
                isFavorite = DatabaseManager.shared.isFavorite(assetId: assetId)
            }
        }
        .padding(.vertical, 4)
    }

    private func actionButton(_ title: String, icon: String, active: Bool = false, busy: Bool = false,
                              primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(title, icon: icon, active: active, busy: busy, primary: primary)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func actionLabel(_ title: String, icon: String, active: Bool = false, busy: Bool = false,
                             primary: Bool = false) -> some View {
        let filled = primary || active
        return VStack(spacing: 6) {
            ZStack {
                if busy {
                    ProgressView().tint(filled ? Theme.onAccent : Theme.text)
                } else {
                    if icon == "selfie" {
                        SelfieGlyph(size: 28, color: filled ? Theme.onAccent : Theme.text)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(filled ? Theme.onAccent : Theme.text)
                    }
                }
            }
            .frame(width: 50, height: 50)
            .background(filled ? Theme.accent : Theme.card)
            .clipShape(Circle())
            .overlay(Circle().stroke(filled ? Color.clear : Theme.border, lineWidth: 0.5))
            .scaleEffect(active ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: active)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(filled ? Theme.text : Theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: 照片中的文字

    @ViewBuilder
    private var photoTextCard: some View {
        if let photoText {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 8) {
                        ThemeIcon(systemName: "text.viewfinder", size: 28)
                        Text("照片中的文字")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Theme.text)
                    }
                    Spacer()
                    if !photoText.isEmpty {
                        Button(action: {
                            UIPasteboard.general.string = photoText
                            showMessage("已複製照片中的文字")
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.text.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if photoText.isEmpty {
                    Text("沒有偵測到文字")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text.opacity(0.45))
                } else {
                    Text(photoText)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text.opacity(0.85))
                        .lineLimit(showsFullText ? nil : 6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if photoText.components(separatedBy: "\n").count > 6 || photoText.count > 160 {
                        Button(showsFullText ? "收合" : "顯示全部") { showsFullText.toggle() }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.text.opacity(0.6))
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeCard(radius: 22)
        }
    }

    // MARK: 所屬筆記

    @ViewBuilder
    private var notesCard: some View {
        if !noteTopics.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ThemeIcon(systemName: "book.pages", size: 28)
                    Text("出現在筆記")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.text)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 2)
                ForEach(noteTopics, id: \.self) { topic in
                    Button(action: { openNoteDetail(topic) }) {
                        HStack(spacing: 10) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 15))
                                .foregroundColor(Theme.text.opacity(0.7))
                            Text("《\(topic)》")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(Theme.text)
                                .lineLimit(2)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.text.opacity(0.3))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .themeCard(radius: 22)
        }
    }

    // MARK: 動作

    private func recognizeText() {
        isRecognizingText = true
        Task {
            let result = await PhotoTextCoordinator.shared.recognizeNow(assetId: assetId)
            await MainActor.run {
                isRecognizingText = false
                if let result {
                    photoText = result
                    withAnimation { showsText = true }
                } else {
                    showMessage("讀不到這張照片（可能還在 iCloud 下載），請稍後再試")
                }
            }
        }
    }

    /// 截圖 → 文字 → Agent 整理店名 → Apple 地圖查座標 → 存進想去清單
    private func addToWishList() {
        isAddingWish = true
        message = nil
        Task {
            var text: String
            var canOpen = false
            var redo: String?
            do {
                redo = AIRouter.onDevice ? "wish" : nil
                let result = try await WishListService.shared.addPlaces(fromPhoto: assetId)
                text = result.added.isEmpty
                    ? "已經在想去清單裡：" + result.alreadyInList.joined(separator: "、")
                    : "已加入想去清單：" + result.added.joined(separator: "、")
                canOpen = true
            } catch {
                text = error.localizedDescription
            }
            let id = assetId
            let recognized = await Task.detached { PhotoTextCoordinator.shared.recognizedText(for: id) }.value
            await MainActor.run {
                isAddingWish = false
                showMessage(text, wish: canOpen, redo: redo)
                if photoText == nil { photoText = recognized }
            }
        }
    }

    /// 商品截圖 → 文字 → Agent 整理商品與國家 → 存進購物清單（依國家分組）
    private func addToShoppingList() {
        isAddingShopping = true
        message = nil
        Task {
            var text: String
            var canOpen = false
            var canManual = false
            let redo: String? = AIRouter.onDevice ? "shopping" : nil
            do {
                let result = try await ShoppingListService.shared.addItems(fromPhoto: assetId)
                if result.added.isEmpty {
                    text = "已經在購物清單裡：" + result.alreadyInList.joined(separator: "、")
                } else {
                    let place = result.countryCode.isEmpty ? "" : "（\(ShoppingCountry.name(for: result.countryCode))）"
                    text = "已加入購物清單\(place)：" + result.added.joined(separator: "、")
                }
                canOpen = true
            } catch {
                text = error.localizedDescription
                if let shoppingError = error as? ShoppingListError, case .noProducts = shoppingError { canManual = true }
            }
            let id = assetId
            let recognized = await Task.detached { PhotoTextCoordinator.shared.recognizedText(for: id) }.value
            await MainActor.run {
                isAddingShopping = false
                showMessage(text, shopping: canOpen, manual: canManual, redo: redo)
                if photoText == nil { photoText = recognized }
            }
        }
    }

    /// 使用者按了「用後端再整理一次」：這一次改用開發者的後端，取代剛才在手機上整理的結果
    private func redoWithBackend(_ kind: String) {
        withAnimation { message = nil }
        if kind == "wish" { isAddingWish = true } else { isAddingShopping = true }
        Task {
            var text: String
            do {
                if kind == "wish" {
                    let result = try await WishListService.shared.redoPlaces(fromPhoto: assetId)
                    text = "已用後端重新整理：" + (result.added + result.alreadyInList).joined(separator: "、")
                } else {
                    let result = try await ShoppingListService.shared.redoItems(fromPhoto: assetId)
                    let place = result.countryCode.isEmpty ? "" : "（\(ShoppingCountry.name(for: result.countryCode))）"
                    text = "已用後端重新整理\(place)：" + (result.added + result.alreadyInList).joined(separator: "、")
                }
            } catch {
                text = "後端沒有整理成功，清單維持原樣。（\(error.localizedDescription)）"
            }
            await MainActor.run {
                isAddingWish = false
                isAddingShopping = false
                showMessage(text, wish: kind == "wish", shopping: kind != "wish")
            }
        }
    }

    private func share() {
        Task {
            if let image = await Self.loadImage(assetId: assetId, side: 2400) {
                await MainActor.run {
                    sharePayload = SharePayload(items: [image])
                }
            }
        }
    }

    private func openNoteDetail(_ topic: String) {
        Task {
            if let item = try? await WikiService.shared.item(topic: topic) {
                await MainActor.run { openNote = item }
            }
        }
    }

    // MARK: 讀取

    private func load() async {
        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject {
            if let date = asset.creationDate { dateString = Self.formatDate(date) }
            if let location = asset.location { locationString = await Self.placeName(for: location) }
        }
        isFavorite = DatabaseManager.shared.isFavorite(assetId: assetId)
        noteTopics = (try? await WikiService.shared.topics(containing: assetId)) ?? []
        let id = assetId
        photoText = await Task.detached(priority: .userInitiated) { PhotoTextCoordinator.shared.recognizedText(for: id) }.value
    }

    static func formatDate(_ date: Date) -> String {
        AppDateFormatters.dateTimeWeekday.string(from: date)
    }

    private static func placeName(for location: CLLocation) async -> String {
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        let parts = [placemark?.locality ?? placemark?.administrativeArea, placemark?.country].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty
            ? String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
            : parts.joined(separator: ", ")
    }

    static func loadImage(assetId: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).foregroundColor(iconColor).font(.system(size: 20)).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).foregroundColor(Theme.secondaryText)
                Text(value).font(.system(size: 16)).foregroundColor(Theme.text)
            }
            Spacer()
        }
    }
}


// MARK: - 照片上的原況文字

enum LiveTextSupport {
    /// 這支手機能不能在照片上直接選文字（iPhone XS 以後、iOS 16 以上）
    static var isAvailable: Bool { ImageAnalyzer.isSupported }
}

/// 照片上的原況文字：讀到的文字會標亮，可以拖曳選取、複製、查詢、翻譯（系統功能，全部在手機上完成）。
/// 右下角有系統的「全部複製」按鈕。只讀取照片，不會修改照片。
struct LiveTextImageView: UIViewRepresentable {
    let image: UIImage
    /// 讀完時通知有沒有找到文字
    var onResult: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.frame = container.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(imageView)

        let interaction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = .textSelection
        interaction.isSupplementaryInterfaceHidden = false
        imageView.addInteraction(interaction)
        context.coordinator.imageView = imageView
        context.coordinator.interaction = interaction
        context.coordinator.analyze(image, onResult: onResult)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard context.coordinator.imageView?.image !== image else { return }
        context.coordinator.imageView?.image = image
        context.coordinator.analyze(image, onResult: onResult)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var imageView: UIImageView?
        var interaction: ImageAnalysisInteraction?
        private var task: Task<Void, Never>?
        private static let analyzer = ImageAnalyzer()

        func analyze(_ image: UIImage, onResult: @escaping (Bool) -> Void) {
            task?.cancel()
            interaction?.analysis = nil
            task = Task { @MainActor in
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try? await Self.analyzer.analyze(image, configuration: configuration)
                guard !Task.isCancelled else { return }
                interaction?.analysis = analysis
                // 一打開就把所有文字標亮，看得出哪裡可以選
                interaction?.selectableItemsHighlighted = true
                onResult(analysis?.hasResults(for: .text) ?? false)
            }
        }
    }
}

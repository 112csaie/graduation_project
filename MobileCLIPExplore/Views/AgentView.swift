import SwiftUI
import PhotosUI
import Photos
import CoreLocation
import UIKit

// MARK: - 輔助結構
struct IdentifiableString: Identifiable {
    let id: String
}

// 1. 定義單筆對話訊息
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String           // 實際送給後端的訊息
    let isUser: Bool
    var images: [UIImage] = []
    var canSaveNote: Bool = false
    var bubbleText: String? = nil       // 若有值，泡泡顯示此文字而非 text
    var quotedTopic: String? = nil      // 引用的 Wiki 主題，顯示於泡泡
    var assetIds: [String] = []         // 這則訊息附的相簿照片識別碼（存進最近的對話）
}

private enum ChatAuthor {
    case user
    case assistant

    /// 不顯示名字：Agent 的泡泡旁邊有 selfIE 頭像，自己的是亮色泡泡
    var title: String { "" }

    var bubbleColor: Color {
        switch self {
        case .user: return Theme.accent   // 自己說的話：亮色
        case .assistant: return Theme.card // Agent：卡片色
        }
    }

    var textColor: Color {
        switch self {
        case .user: return Theme.onAccent
        case .assistant: return Theme.text
        }
    }
}

// 2. 對話泡泡 UI 元件
struct MessageBubble: View {
    let message: ChatMessage
    var onGenerateNote: (() -> Void)? = nil
    var onContinueNote: (() -> Void)? = nil

    @State private var lightboxImage: UIImage? = nil

    var body: some View {
        let author = message.isUser ? ChatAuthor.user : ChatAuthor.assistant
        let maxBubbleWidth = UIScreen.main.bounds.width * 0.75

        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {

            if !author.title.isEmpty {
                Text(author.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.text.opacity(0.45))
                    .padding(.horizontal, 4)
            }

            // 引用筆記 chip（跟著泡泡）
            if let topic = message.quotedTopic {
                HStack(spacing: 5) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.text.opacity(0.5))
                    Text(topic)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text.opacity(0.65))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.text.opacity(0.1))
                .cornerRadius(8)
                .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
            }

            if !message.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(0..<message.images.count, id: \.self) { idx in
                            Image(uiImage: message.images[idx])
                                .resizable()
                                .scaledToFill()
                                .frame(width: message.images.count == 1 ? 220 : 140,
                                       height: message.images.count == 1 ? 160 : 140)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { lightboxImage = message.images[idx] }
                        }
                    }
                }
                .frame(maxWidth: message.images.count == 1 ? 220 : 300)
            }

            let displayText = message.bubbleText ?? message.text
            if !displayText.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
                    if !message.isUser { AgentAvatar() }
                    bubbleContainer(author: author) {
                        Text(createAttributedString(from: displayText))
                            .font(.system(size: 17))
                            .foregroundColor(author.textColor)
                            .tint(author.textColor)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: maxBubbleWidth, alignment: message.isUser ? .trailing : .leading)
                }
            }

            if !message.isUser && message.canSaveNote {
                HStack(spacing: 8) {
                    Button(action: { onGenerateNote?() }) {
                        Label("存成筆記", systemImage: "doc.text.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.card)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
                    }
                    if onContinueNote != nil {
                        Button(action: { onContinueNote?() }) {
                            Label("延續筆記", systemImage: "arrow.triangle.merge")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(Theme.text)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Theme.card)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
                        }
                    }
                }
                .padding(.leading, 42)   // 對齊泡泡（頭像右邊）
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        .fullScreenCover(item: Binding(
            get: { lightboxImage.map { IdentifiableUIImage(image: $0) } },
            set: { lightboxImage = $0?.image }
        )) { item in
            ChatImageLightbox(image: item.image)
        }
    }

    private func bubbleContainer<Content: View>(
        author: ChatAuthor,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // 靠近說話者的那個角是尖的，看得出是誰說的
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: author == .assistant ? 6 : 20,
            bottomTrailingRadius: author == .user ? 6 : 20,
            topTrailingRadius: 20,
            style: .continuous)
        return content()
            .padding(.vertical, 11)
            .padding(.horizontal, 15)
            .background(author.bubbleColor)
            .clipShape(shape)
            .overlay(shape.stroke(author == .assistant ? Theme.border : Color.clear, lineWidth: 0.5))
    }

    private func createAttributedString(from text: String) -> AttributedString {
        // 每則訊息的 Markdown 只解析一次（畫面每次更新都會呼叫這裡）
        if let cached = MarkdownCache.shared.object(forKey: text as NSString) { return cached.value }
        let parsed = parseAttributedString(from: text)
        MarkdownCache.shared.setObject(MarkdownBox(parsed), forKey: text as NSString)
        return parsed
    }

    private func parseAttributedString(from text: String) -> AttributedString {
        // 移除 markdown 粗體標記：先處理成對 **text**，再清除剩餘單個 **
        var stripped = text.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "$1", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: "**", with: "")
        let textToParse = stripped.replacingOccurrences(of: "\n", with: "  \n")
        if let attr = try? AttributedString(markdown: textToParse, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(stripped)
    }
}

// MARK: - Markdown 快取

private final class MarkdownBox {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

private enum MarkdownCache {
    static let shared: NSCache<NSString, MarkdownBox> = {
        let cache = NSCache<NSString, MarkdownBox>()
        cache.countLimit = 300
        return cache
    }()
}

// MARK: - WikiFavorites

struct WikiFavorites {
    static let key = "wiki_favorites"

    static func isFavorite(_ topic: String) -> Bool {
        let list = UserDefaults.standard.stringArray(forKey: key) ?? []
        return list.contains(topic)
    }

    static func toggle(_ topic: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        if let idx = list.firstIndex(of: topic) {
            list.remove(at: idx)
        } else {
            list.append(topic)
        }
        UserDefaults.standard.set(list, forKey: key)
    }

    /// 筆記改名時，最愛跟著改名
    static func rename(from oldTopic: String, to newTopic: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard let idx = list.firstIndex(of: oldTopic) else { return }
        list[idx] = newTopic
        UserDefaults.standard.set(list, forKey: key)
    }
}

// MARK: - WikiImageStorage

struct WikiImageStorage {
    static var baseDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("WikiImages", isDirectory: true)
    }

    static func sanitize(_ topic: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return topic.components(separatedBy: invalid).joined(separator: "_")
    }

    static func save(image: UIImage, topic: String) {
        saveAll(images: [image], topic: topic)
    }

    static func saveAll(images: [UIImage], topic: String) {
        let dir = baseDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = sanitize(topic)
        // Remove previous images for this topic
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for file in existing where file.hasPrefix(base) && file.hasSuffix(".jpg") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
        }
        for (idx, image) in images.enumerated() {
            let filename = idx == 0 ? base + ".jpg" : base + "_\(idx).jpg"
            let url = dir.appendingPathComponent(filename)
            if let data = image.jpegData(compressionQuality: 0.8) {
                try? data.write(to: url)
            }
        }
    }

    static func load(topic: String) -> UIImage? {
        loadAll(topic: topic).first
    }

    /// 筆記改名時，App 存的對話圖片跟著改名（只動 App 自己的檔案）
    static func rename(from oldTopic: String, to newTopic: String) {
        let images = loadAll(topic: oldTopic)
        guard !images.isEmpty else { return }
        saveAll(images: images, topic: newTopic)
        let dir = baseDirectory
        let base = sanitize(oldTopic)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for file in files where file == base + ".jpg" || (file.hasPrefix(base + "_") && file.hasSuffix(".jpg")) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
        }
    }

    static func loadAll(topic: String) -> [UIImage] {
        let dir = baseDirectory
        let base = sanitize(topic)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let relevant = files.filter { $0 == base + ".jpg" || ($0.hasPrefix(base + "_") && $0.hasSuffix(".jpg")) }
        let sorted = relevant.sorted { a, b in
            indexFrom(filename: a, base: base) < indexFrom(filename: b, base: base)
        }
        return sorted.compactMap { filename -> UIImage? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(filename)) else { return nil }
            return UIImage(data: data)
        }
    }

    private static func indexFrom(filename: String, base: String) -> Int {
        if filename == base + ".jpg" { return 0 }
        let middle = filename.dropFirst((base + "_").count).dropLast(".jpg".count)
        return Int(middle) ?? 0
    }
}

// MARK: - 時間格式轉換

private func formatWikiDate(_ raw: String?) -> String {
    guard let raw = raw, !raw.isEmpty else { return "" }
    // SQLite 存的是 UTC，顯示裝置本地時間
    return AppDateFormatters.localDateTime(fromSQLite: raw)
}

// MARK: - Wiki 卡片元件

private struct WikiCard: View {
    let wiki: WikiItem
    @State private var isFavorite: Bool
    @State private var thumbnail: UIImage? = nil
    @State private var photoCount = 0

    init(wiki: WikiItem) {
        self.wiki = wiki
        _isFavorite = State(initialValue: WikiFavorites.isFavorite(wiki.topic))
    }

    /// 筆記本卡片（兩欄）：上面是封面照片（沒有照片時是有圖示的彩色紙），下面標題、摘要、日期；右上角收藏書籤
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Theme.tile
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: Self.icon(for: wiki.topic))
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.6))
                }
            }
            .frame(height: 112)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if photoCount > 1 {
                    Label("\(photoCount)", systemImage: "photo.on.rectangle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.onAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.info)
                        .clipShape(Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: {
                    WikiFavorites.toggle(wiki.topic)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        isFavorite = WikiFavorites.isFavorite(wiki.topic)
                    }
                }) {
                    Image(systemName: isFavorite ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(isFavorite ? Theme.onAccent : Theme.text)
                        .frame(width: 30, height: 30)
                        .background(isFavorite ? Theme.accent : Theme.card.opacity(0.9))
                        .clipShape(Circle())
                        .scaleEffect(isFavorite ? 1.08 : 1)
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0,
                                              bottomTrailingRadius: 0, topTrailingRadius: 20, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(wiki.topic)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !wiki.summary.isEmpty {
                    Text(wiki.summary)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(formatWikiDate(wiki.updated_at))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        }
        .themeCard(radius: 20)
        // 縮圖：筆記連結的相簿照片（旅行筆記挑照片最多那天的一張）；沒有時用對話時存的圖片
        .task(id: wiki.topic + "|" + (wiki.updated_at ?? "")) {
            if let cover = await WikiService.shared.cover(topic: wiki.topic) {
                photoCount = cover.count
                thumbnail = await Self.loadThumbnail(assetId: cover.assetId) ?? WikiImageStorage.load(topic: wiki.topic)
            } else {
                photoCount = 0
                thumbnail = WikiImageStorage.load(topic: wiki.topic)
            }
        }
    }

    /// 沒有照片的筆記：依主題猜一個圖示
    static func icon(for topic: String) -> String {
        let rules: [(String, String)] = [("遊", "airplane"), ("旅", "airplane"), ("演唱會", "music.mic"), ("展", "paintpalette"),
                                         ("吃", "fork.knife"), ("美食", "fork.knife"), ("咖啡", "cup.and.saucer"),
                                         ("月報", "calendar"), ("健身", "dumbbell"), ("想去", "mappin.and.ellipse"),
                                         ("搜尋", "magnifyingglass"), ("圖", "photo")]
        return rules.first { topic.contains($0.0) }?.1 ?? "book.closed"
    }

    private static func loadThumbnail(assetId: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 260, height: 260),
                                                  contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - 主視圖 AgentView
struct AgentView: View {
    @State private var topTab: Int = 0        // 0: 聊天, 1: 個人 Wiki
    @AppStorage("userName") private var userName = ""
    @State private var libraryTab: Int = 0    // 0: All Notes, 1: Favorite
    @State private var notesFilter: String = ""

    @State private var isLoading = false

    // --- 對話輸入狀態 ---
    @State private var promptText: String = ""
    @State private var selectedChatPhotos: [PhotosPickerItem] = []
    @State private var selectedUIImages: [UIImage] = []
    @State private var showSinglePicker = false
    @FocusState private var promptFieldFocused: Bool
    @FocusState private var notesFilterFocused: Bool
    @State private var chatHistory: [ChatMessage] = []

    // --- 資料與 UI 狀態 ---
    @State private var wikiNotes: [WikiItem] = []
    @State private var sharePayload: SharePayload?
    @State private var conversationImages: [UIImage] = []  // 累積整段對話中送出的所有圖片
    @State private var conversationAssetIds: [String] = []  // 整段對話用到的照片識別碼（存成筆記時建立連結）
    @State private var pendingTargetTopic: String? = nil    // 「延續筆記」選的那一篇
    @State private var quotedWiki: WikiItem? = nil          // 被引用的 Wiki 筆記（輸入列 chip）
    @State private var lastQuotedTopic: String? = nil      // 最後引用過的主題，供延續筆記選擇器高亮
    @State private var showContinuePicker = false           // 延續筆記選擇器
    @State private var bubbleTextOverride: String? = nil   // 泡泡顯示用的替代文字
    @State private var currentAgentTask: Task<Void, Never>? = nil
    @State private var pendingDeleteWiki: WikiItem? = nil        // 等使用者確認要刪除的筆記
    @State private var conversationId = UUID().uuidString        // 目前這段對話（存進「最近的對話」）
    @State private var showRecentConversations = false
    @State private var attachedLibraryPhotos: [AttachedLibraryPhoto] = []  // 從照片頁「問 Agent」帶進來的照片
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var connection = AgentConnection.shared

    @EnvironmentObject var syncVM: PhotoSyncViewModel

    // 依本地過濾文字及 libraryTab 篩選 Wiki 筆記
    var filteredNotes: [WikiItem] {
        var base = wikiNotes
        // Favorite tab 過濾
        if libraryTab == 1 {
            base = base.filter { WikiFavorites.isFavorite($0.topic) }
        }
        // 依更新時間由新到舊排序（updated_at 格式 "yyyy-MM-dd HH:mm:ss" 可直接字串比較）
        base.sort { ($0.updated_at ?? "") > ($1.updated_at ?? "") }
        // 搜尋文字過濾
        let q = notesFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.topic.localizedCaseInsensitiveContains(q)
            || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 14) {
                    // 標題列：左邊大標題，右邊「最近的對話」「新對話」
                    HStack(spacing: 10) {
                        Text("Agent")
                            .font(.system(size: 30, weight: .heavy))
                            .foregroundColor(Theme.text)
                        Spacer()
                        HeaderIconButton(systemName: "clock.arrow.circlepath", label: "最近的對話") {
                            showRecentConversations = true
                        }
                        // 新對話（目前的對話會留在「最近的對話」）；在個人 Wiki 分頁按也會切回對話
                        HeaderIconButton(systemName: "square.and.pencil", label: "新對話") {
                            startNewChat()
                            topTab = 0
                        }
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 20)

                    // 切換：聊天／個人 Wiki（和其他頁一樣的圓角小標籤）
                    HStack(spacing: 8) {
                        ThemeChip(title: "聊天", isSelected: topTab == 0) { switchTab(0) }
                        ThemeChip(title: "個人 Wiki", isSelected: topTab == 1) { switchTab(1) }
                        Spacer()
                    }
                    .padding(.horizontal, 20)

                    // 分頁內容
                    if topTab == 0 {
                        chatView
                    } else {
                        libraryView
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.dismissKeyboard()
                    promptFieldFocused = false
                    notesFilterFocused = false
                }
            )
            .dismissKeyboardOnTap()
        }
        .photosPicker(
            isPresented: $showSinglePicker,
            selection: $selectedChatPhotos,
            maxSelectionCount: 1,
            matching: .images,
            preferredItemEncoding: .automatic,
            photoLibrary: .shared()   // 取得照片識別碼：存成筆記時記錄「這篇筆記對應哪張照片」
        )
        .sheet(item: $sharePayload) { payload in ShareSheet(items: payload.items) }
        // 刪除筆記前再確認一次（只刪筆記與它記錄的照片關聯，不會刪除照片）
        .confirmationDialog(
            "刪除「\(pendingDeleteWiki?.topic ?? "")」？",
            isPresented: Binding(get: { pendingDeleteWiki != nil },
                                 set: { if !$0 { pendingDeleteWiki = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeleteWiki
        ) { wiki in
            Button("刪除筆記", role: .destructive) { deleteWikiNote(wiki) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("刪除後無法復原。相簿中的照片不會受影響。")
        }
        .sheet(isPresented: $showContinuePicker) {
            ContinueNotePickerSheet(notes: wikiNotes, highlightedTopic: quotedWiki?.topic ?? lastQuotedTopic) { selected in
                showContinuePicker = false
                lastQuotedTopic = selected.topic
                pendingTargetTopic = selected.topic
                bubbleTextOverride = "請幫我將上述對話補充到《\(selected.topic)》筆記"

                // 先抓現有全文，確保 AI 拿到完整舊內容後再整合
                Task {
                    let existing: String
                    if let result = try? await APIService.shared.searchWiki(query: selected.topic, topK: 1) {
                        existing = result.exact?.content ?? result.candidates?.first?.content ?? ""
                    } else {
                        existing = ""
                    }

                    await MainActor.run {
                        if existing.isEmpty {
                            promptText = "請根據以上對話提取出重要的知識、事實與結論，整合補充到《\(selected.topic)》這篇筆記。必須保留所有原有內容，只追加新資訊，不要描述對話過程。完成後重新撰寫整篇摘要，需涵蓋更新後的完整內容。"
                        } else {
                            promptText = "以下是《\(selected.topic)》目前的完整筆記內容：\n\n\(existing)\n\n請根據以上對話，提取出重要的知識、事實與結論，整合補充到上述筆記中。必須保留所有原有內容，只追加新資訊，不要描述對話過程。完成後重新撰寫整篇摘要，需涵蓋更新後的完整內容。"
                        }
                        unifiedSubmit()
                    }
                }
            }
        }
        .onAppear {
            connection.check()
            loadNotes()
            consumePendingPhoto()
        }
        // 切到 Agent 分頁時確認一次有沒有連上電腦（30 秒內檢查過就不重複）
        .onChange(of: router.selectedTab) { _, tab in
            if tab == AppTab.agent { connection.check() }
        }
        .onChange(of: selectedChatPhotos) { _, newItems in loadSelectedImages(from: newItems) }
        .onChange(of: router.pendingAgentPhotoId) { _, _ in consumePendingPhoto() }
        .onChange(of: router.pendingConversationId) { _, id in
            guard let id else { return }
            router.pendingConversationId = nil
            openConversation(id)
            topTab = 0
        }
        // 在其他頁面新增／更新／刪除了筆記（例如相簿頁的回憶筆記、想去清單）：重新讀取列表
        .onReceive(NotificationCenter.default.publisher(for: .wikiNotesUpdated)) { _ in loadNotes() }
        .sheet(isPresented: $showRecentConversations) {
            RecentConversationsView(currentConversationId: conversationId) { id in openConversation(id) }
        }
    }

    private func switchTab(_ tab: Int) {
        UIApplication.shared.dismissKeyboard()
        promptFieldFocused = false
        notesFilterFocused = false
        withAnimation(.easeInOut(duration: 0.2)) { topTab = tab }
    }

    /// 還沒開始聊：Agent 先打招呼，說明可以拿一張照片來問；下面是「問照片」的範例問題
    private var greetingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                AgentAvatar()
                Text("嗨\(userName.isEmpty ? "" : "，\(userName)")！我是 selfIE。選一張照片問我照片裡的事，像是這是哪裡、上面寫了什麼、這是什麼東西。")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.text)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 15)
                    .background(Theme.card)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                                                      bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 主要動作：挑一張照片
            Button(action: { showSinglePicker = true }) {
                HStack(spacing: 12) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .frame(width: 44, height: 44)
                        .background(Theme.onAccent)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("選一張照片")
                            .font(.system(size: 16, weight: .bold))
                        Text("也可以在照片頁按「問 Agent」")
                            .font(.system(size: 12))
                            .opacity(0.75)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(Theme.onAccent)
                .padding(12)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.leading, 40)

            Text("可以這樣問")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
                .padding(.leading, 44)
                .padding(.top, 4)
            FlowChips(items: Self.photoQuestions) { question in
                promptText = question
                if selectedUIImages.isEmpty && attachedLibraryPhotos.isEmpty {
                    showSinglePicker = true   // 先選照片，問題已經填好，選完按送出
                } else {
                    unifiedSubmit()
                }
            }
            .padding(.leading, 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 問單張照片的範例（Agent 看得懂的問法）
    static let photoQuestions = ["這是哪裡？", "照片上寫了什麼？", "這是什麼東西？", "這家店叫什麼？", "幫我把這張存成筆記"]

    // MARK: - 聊天對話區
    private var chatView: some View {
        VStack {
            if connection.isOffline {
                AgentOfflineNotice(feature: "Agent 回覆", stillWorks: "看過去的對話和筆記")
                    .padding(.horizontal, 16)
            }
            // 1. 對話紀錄顯示區
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 15) {
                        if chatHistory.isEmpty && !isLoading {
                            greetingView
                        }
                        ForEach(chatHistory) { msg in
                            MessageBubble(message: msg,
                                onGenerateNote: {
                                    bubbleTextOverride = "請幫我將上述對話整理成筆記"
                                    promptText = "請幫我將上述對話整理成筆記，提取出重要的知識、事實與結論。只保留核心資訊，不要描述對話過程或誰說了什麼。"
                                    unifiedSubmit()
                                },
                                onContinueNote: (quotedWiki != nil || lastQuotedTopic != nil) ? {
                                    showContinuePicker = true
                                } : nil
                            )
                        }
                        if isLoading {
                            HStack(spacing: 8) {
                                AgentAvatar()
                                ProgressView().tint(Theme.text)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(Theme.card)
                                    .clipShape(Capsule())
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    .id("Bottom")
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chatHistory.count) { _ in
                    withAnimation { proxy.scrollTo("Bottom", anchor: .bottom) }
                }
            }

            // 2. 暫存圖片預覽區
            if !selectedUIImages.isEmpty || !attachedLibraryPhotos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 15) {
                        ForEach(attachedLibraryPhotos) { photo in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: photo.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Button(action: {
                                    attachedLibraryPhotos.removeAll { $0.id == photo.id }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(Theme.text)
                                        .background(Circle().fill(Theme.background))
                                        .offset(x: 8, y: -8)
                                }
                            }
                            .padding([.top, .trailing], 8)
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
                                        .foregroundColor(Theme.text)
                                        .background(Circle().fill(Theme.background))
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

            // 引用筆記 chip
            if let quoted = quotedWiki {
                HStack(spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.text.opacity(0.6))
                    Text(quoted.topic)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.text.opacity(0.8))
                        .lineLimit(1)
                    Spacer()
                    Button(action: { quotedWiki = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Theme.text.opacity(0.4))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.text.opacity(0.1))
                .cornerRadius(10)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }

            // 3. 輸入控制列：圓膠囊，右邊亮色圓形送出
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: { showSinglePicker = true }) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(Theme.secondaryText)
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel("附上照片")

                TextField(selectedUIImages.isEmpty && attachedLibraryPhotos.isEmpty ? "附上照片，問我照片裡的事…" : "想問這張照片什麼？", text: $promptText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.text)
                    .focused($promptFieldFocused)
                    .submitLabel(.send)
                    .padding(.vertical, 9)
                    .onSubmit {
                        unifiedSubmit()
                    }

                Button(action: { unifiedSubmit() }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(Theme.onAccent)
                        .frame(width: 38, height: 38)
                        .background(Theme.accent.opacity(canSubmit && !isLoading ? 1 : 0.4))
                        .clipShape(Circle())
                }
                .disabled(!canSubmit || isLoading)
                .accessibilityLabel("送出")
            }
            .padding(.leading, 8)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    // MARK: - 個人Wiki 列表
    private var libraryView: some View {
        VStack(spacing: 0) {
            // 搜尋列
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.text.opacity(0.5))
                    .font(.system(size: 15))

                TextField("搜尋筆記...", text: $notesFilter)
                    .foregroundColor(Theme.text)
                    .font(.system(size: 15))
                    .focused($notesFilterFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        notesFilterFocused = false
                        UIApplication.shared.dismissKeyboard()
                    }

                if !notesFilter.isEmpty {
                    Button(action: { notesFilter = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.text.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // 全部／收藏（和其他頁一樣的小標籤），右邊是篇數
            HStack(spacing: 8) {
                ThemeChip(title: "全部 \(wikiNotes.count)", isSelected: libraryTab == 0) { libraryTab = 0 }
                ThemeChip(title: "收藏 \(wikiNotes.filter { WikiFavorites.isFavorite($0.topic) }.count)",
                          isSelected: libraryTab == 1) { libraryTab = 1 }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if wikiNotes.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(Theme.onAccent)
                        .frame(width: 76, height: 76)
                        .background(Theme.accent)
                        .clipShape(Circle())
                    Text("筆記本還是空的")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(Theme.text)
                    Text("問完照片按「存成筆記」，或把旅行相簿整理成回憶，筆記就會收在這裡。")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                Spacer()
            } else if filteredNotes.isEmpty && libraryTab == 1 {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(Theme.onAccent)
                        .frame(width: 64, height: 64)
                        .background(Theme.accent)
                        .clipShape(Circle())
                    Text("還沒有收藏的筆記")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.text)
                    Text("點筆記右上角的書籤就會收進來。")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.secondaryText)
                }
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(filteredNotes) { wiki in
                            NavigationLink(destination: WikiNoteDetailView(item: wiki, onQuote: { quoted in
                                topTab = 0
                                quotedWiki = quoted
                            })) {
                                WikiCard(wiki: wiki)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(action: {
                                    topTab = 0
                                    quotedWiki = wiki
                                }) { Label("引用此筆記", systemImage: "text.quote") }
                                Button(action: {
                                    sharePayload = SharePayload(items: ["\(wiki.topic)\n\n\(wiki.summary)\n\n\(wiki.preview ?? "")"])
                                }) { Label("分享", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive, action: { pendingDeleteWiki = wiki }) {
                                    Label("刪除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedUIImages.isEmpty || !attachedLibraryPhotos.isEmpty
    }

    /// 照片頁按了「問 Agent 這張照片」：切到對話、把照片放進輸入列（只讀取照片）
    private func consumePendingPhoto() {
        guard let assetId = router.pendingAgentPhotoId else { return }
        router.pendingAgentPhotoId = nil
        topTab = 0
        guard !attachedLibraryPhotos.contains(where: { $0.id == assetId }),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600),
                                              contentMode: .aspectFit, options: options) { image, _ in
            guard let image else { return }
            DispatchQueue.main.async {
                attachedLibraryPhotos.append(AttachedLibraryPhoto(id: assetId, image: image))
                promptFieldFocused = true
            }
        }
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
        let userMessage = promptText
        promptFieldFocused = false
        UIApplication.shared.dismissKeyboard()
        let trimmedMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty || !selectedUIImages.isEmpty || !attachedLibraryPhotos.isEmpty else { return }

        // 1. 將使用者訊息加入泡泡（支援多張）
        chatHistory.append(ChatMessage(
            text: trimmedMessage,
            isUser: true,
            images: attachedLibraryPhotos.map(\.image) + selectedUIImages,
            bubbleText: bubbleTextOverride,
            quotedTopic: quotedWiki?.topic,
            assetIds: attachedLibraryPhotos.map(\.id) + selectedChatPhotos.compactMap(\.itemIdentifier)
        ))
        bubbleTextOverride = nil
        persistConversation()

        // 打包歷史對話紀錄傳給後端
        var contextString = ""
        if chatHistory.count > 1 {
            contextString = "【系統提示：以下是我們稍早的對話紀錄】\n"
            for msg in chatHistory.dropLast() {
                let role = msg.isUser ? "使用者" : "你(AI)"
                if !msg.text.isEmpty { contextString += "[\(role)]: \(msg.text)\n" }
                if !msg.images.isEmpty {
                    contextString += "[\(role)]: （已附上 \(msg.images.count) 張圖片）\n"
                }
            }
            contextString += "【系統提示：對話紀錄結束】\n"
        }

        // 若有引用筆記，把摘要放進對話脈絡（不混進這次的訊息，後端「要不要存」只看這次的訊息）
        if let quoted = quotedWiki {
            contextString += "【引用筆記：《\(quoted.topic)》】\n摘要：\(quoted.summary)\n"
        }
        let messageToSend = trimmedMessage
        let contextToSend: String? = contextString.isEmpty ? nil : contextString
        let targetTopic = pendingTargetTopic ?? quotedWiki?.topic
        pendingTargetTopic = nil
        let currentAssetIds = attachedLibraryPhotos.map(\.id) + selectedChatPhotos.compactMap(\.itemIdentifier)
        conversationAssetIds.append(contentsOf: currentAssetIds)
        let assetIdsForNote = currentAssetIds.isEmpty ? conversationAssetIds : currentAssetIds

        isLoading = true
        let allImages  = attachedLibraryPhotos.map(\.image) + selectedUIImages
        let firstImage = allImages.first

        // 累積本次圖片到整段對話的圖庫
        conversationImages.append(contentsOf: allImages)

        // 2. 清除輸入列狀態
        promptText = ""
        selectedChatPhotos = []
        selectedUIImages = []
        attachedLibraryPhotos = []
        if let topic = quotedWiki?.topic { lastQuotedTopic = topic }
        quotedWiki = nil

        currentAgentTask = Task {
            do {
                let response = try await APIService.shared.askAgent(message: messageToSend, context: contextToSend,
                                                                    image: firstImage, targetTopic: targetTopic,
                                                                    assetIds: assetIdsForNote)

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    var replyText = response.reply

                    // 若 Agent 儲存了 Wiki 筆記
                    if let wikiAction = response.wiki_action, !wikiAction.hasPrefix("skipped") {
                        let topicName = response.topic ?? ""
                        let actionLabel = wikiAction == "updated" ? "更新" : "新建"
                        replyText += "\n\n(系統提示：已\(actionLabel) Wiki 筆記『\(topicName)』，可在個人Wiki中查閱。)"

                        // 儲存本輪圖片，若無則退回整段對話累積的所有圖片
                        let imagesToSave = allImages.isEmpty ? self.conversationImages : allImages
                        if !imagesToSave.isEmpty, !topicName.isEmpty {
                            WikiImageStorage.saveAll(images: imagesToSave, topic: topicName)
                        }

                        self.loadNotes()
                    }

                    chatHistory.append(ChatMessage(
                        text: replyText,
                        isUser: false,
                        canSaveNote: response.wiki_action == nil
                    ))
                    self.isLoading = false
                    persistConversation()
                }

            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    chatHistory.append(ChatMessage(
                        text: "連線失敗：請確認伺服器已啟動且網路正常 (\(error.localizedDescription))",
                        isUser: false
                    ))
                    self.isLoading = false
                }
            }
        }
    }

    private func loadNotes() {
        Task {
            if let items = try? await APIService.shared.listWiki() {
                // 想去、購物清單的筆記由 App 自動整理，不列在這裡（Agent 仍可讀取）
                await MainActor.run { wikiNotes = items.filter { !ListNotes.isListNote($0.topic) } }
            }
        }
    }

    private func deleteWikiNote(_ wiki: WikiItem) {
        // 先從畫面移除；刪除失敗時重新讀取，避免畫面和資料庫不一致
        wikiNotes.removeAll { $0.topic == wiki.topic }
        if quotedWiki?.topic == wiki.topic { quotedWiki = nil }
        if pendingTargetTopic == wiki.topic { pendingTargetTopic = nil }
        if lastQuotedTopic == wiki.topic { lastQuotedTopic = nil }
        pendingDeleteWiki = nil
        Task {
            do {
                try await APIService.shared.deleteWiki(topic: wiki.topic)
            } catch {
                loadNotes()
            }
        }
    }

    /// 把目前這段對話存進「最近的對話」（只存文字與照片識別碼）
    private func persistConversation() {
        let messages = chatHistory.map { message in
            StoredChatMessage(isUser: message.isUser, text: message.text, bubbleText: message.bubbleText,
                              quotedTopic: message.quotedTopic, assetIds: message.assetIds,
                              imageCount: message.images.count)
        }
        ConversationService.shared.save(conversationId: conversationId, messages: messages)
    }

    /// 打開一段之前的對話，接著聊
    private func openConversation(_ id: String) {
        guard id != conversationId else { return }
        startNewChat()
        conversationId = id
        topTab = 0
        Task {
            let stored = await ConversationService.shared.messages(conversationId: id)
            var restored: [ChatMessage] = []
            var allIds: [String] = []
            var allImages: [UIImage] = []
            for message in stored {
                let images = await ConversationService.loadImages(assetIds: message.assetIds)
                allIds += message.assetIds
                allImages += images
                restored.append(ChatMessage(text: message.text, isUser: message.isUser, images: images,
                                            canSaveNote: !message.isUser && !message.text.contains("(系統提示：已"),
                                            bubbleText: message.bubbleText, quotedTopic: message.quotedTopic,
                                            assetIds: message.assetIds))
            }
            await MainActor.run {
                guard conversationId == id else { return }
                chatHistory = restored
                conversationAssetIds = allIds
                conversationImages = allImages
                lastQuotedTopic = stored.last(where: { $0.quotedTopic != nil })?.quotedTopic
            }
        }
    }

    private func startNewChat() {
        conversationId = UUID().uuidString
        currentAgentTask?.cancel()
        currentAgentTask = nil
        isLoading = false
        withAnimation {
            chatHistory.removeAll()
        }
        promptText = ""
        selectedUIImages.removeAll()
        selectedChatPhotos.removeAll()
        attachedLibraryPhotos.removeAll()
        conversationImages.removeAll()
        conversationAssetIds.removeAll()
        pendingTargetTopic = nil
        quotedWiki = nil
        lastQuotedTopic = nil
    }
}

// MARK: - Helper Components

/// 從相簿帶進對話的照片（記錄照片識別碼，存成筆記時建立連結）
struct AttachedLibraryPhoto: Identifiable {
    let id: String      // PHAsset localIdentifier
    let image: UIImage
}

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
                .background(isSelected ? Theme.accent : Color.clear)
                .foregroundColor(isSelected ? Theme.onAccent : Theme.text)
                .cornerRadius(20)
        }
    }
}

struct PlainTextComponent: UIViewRepresentable {
    var text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textColor = Theme.uiText
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.text = text
    }
}

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

// MARK: - 延續筆記選擇器 Sheet

private struct ContinueNotePickerSheet: View {
    let notes: [WikiItem]
    let highlightedTopic: String?   // 目前引用中的筆記，優先置頂並亮眼顯示
    let onSelect: (WikiItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [WikiItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var sorted = notes.sorted { ($0.updated_at ?? "") > ($1.updated_at ?? "") }
        // 若有引用中的筆記，置頂
        if let h = highlightedTopic {
            sorted = sorted.filter { $0.topic == h } + sorted.filter { $0.topic != h }
        }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.topic.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    // 搜尋列
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(Theme.text.opacity(0.45))
                        TextField("搜尋筆記...", text: $searchText)
                            .foregroundColor(Theme.text)
                            .font(.system(size: 15))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .themeCard(radius: 22)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                    if filtered.isEmpty {
                        Spacer()
                        Text("找不到符合的筆記")
                            .foregroundColor(Theme.text.opacity(0.4))
                            .font(.system(size: 15))
                        Spacer()
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 10) {
                                ForEach(filtered) { wiki in
                                    let isHighlighted = wiki.topic == highlightedTopic
                                    Button(action: { onSelect(wiki) }) {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 6) {
                                                    if isHighlighted {
                                                        Image(systemName: "text.quote")
                                                            .font(.system(size: 11))
                                                            .foregroundColor(.yellow.opacity(0.9))
                                                    }
                                                    Text(wiki.topic)
                                                        .font(.system(size: 15, weight: isHighlighted ? .bold : .semibold))
                                                        .foregroundColor(isHighlighted ? .yellow : Theme.text)
                                                        .lineLimit(1)
                                                }
                                                Text(wiki.summary)
                                                    .font(.system(size: 12))
                                                    .foregroundColor(isHighlighted ? .yellow.opacity(0.6) : Theme.text.opacity(0.5))
                                                    .lineLimit(2)
                                            }
                                            Spacer()
                                            Image(systemName: "arrow.triangle.merge")
                                                .font(.system(size: 14))
                                                .foregroundColor(isHighlighted ? .yellow.opacity(0.7) : Theme.text.opacity(0.4))
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .background(isHighlighted ? Color.yellow.opacity(0.12) : Theme.surface(0.13))
                                        .cornerRadius(14)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14)
                                                .stroke(isHighlighted ? Color.yellow.opacity(0.4) : Color.clear, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                        }
                    }
                }
            }
            .navigationTitle("選擇要延續的筆記")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.text)
                }
            }
        }
    }
}

// MARK: - Chat Image Lightbox

private struct IdentifiableUIImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ChatImageLightbox: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onTapGesture { dismiss() }
    }
}


// MARK: - Agent 頭像

/// Agent 的頭像：亮色圓形裡的 selfIE 圖示（和底部中間的 Agent 按鈕同一個）
struct AgentAvatar: View {
    var size: CGFloat = 32

    var body: some View {
        SelfieGlyph(size: size * 0.66, color: Theme.onAccent)
            .frame(width: size, height: size)
            .background(Theme.accent)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}


// MARK: - 會自動換行的建議小標籤

/// 建議問題：一行放不下就換行（Agent 開場用）
struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button(action: { onTap(item) }) {
                    Text(item)
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
    }
}

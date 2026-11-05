import SwiftUI
import Photos

// 筆記詳情頁（版面 A：封面＋內文＋照片牆）
//
// - 封面：第一張照片，約 1/4 螢幕，可左右滑
// - 內文緊接在封面下方；和標題、摘要重複的行不再顯示兩次
// - 「這篇的照片」：存筆記時對話用到的照片（WikiNotePhotos），兩排預覽，超過時「查看全部」
// - 「可能相關」：用筆記內容搜尋相簿的結果，和上面分開並標示
// 只讀取照片，不修改、不刪除使用者的照片。

// MARK: - Photo source

private enum WikiPhotoSource: Identifiable {
    case image(UIImage, Int)   // 舊筆記：App 自己存的對話圖片（沒有照片識別碼）
    case asset(String)         // 相簿照片

    var id: String {
        switch self {
        case .image(_, let index): return "image-\(index)"
        case .asset(let id):       return id
        }
    }

    var assetId: String? {
        if case .asset(let id) = self { return id }
        return nil
    }
}

private struct PagerRequest: Identifiable {
    let id = UUID()
    let sources: [WikiPhotoSource]
    let index: Int
    /// 筆記自己的照片才能「從筆記移除」（可能相關的照片不行）
    var removable: Bool = true
}

/// 同一天拍的照片（旅行筆記依日期分組）
private struct PhotoDay: Identifiable, Hashable {
    let id: String          // yyyy-MM-dd
    let title: String       // 8/22（六）
    let assetIds: [String]
}

/// 照片的拍攝時間與是否為截圖（排序、分組、挑封面用）
private struct LinkedPhotoInfo {
    let id: String
    let date: Date?
    let isScreenshot: Bool
}

// MARK: - Main View

struct WikiNoteDetailView: View {
    @Environment(\.dismiss) var dismiss

    /// 目前顯示的筆記（編輯後會更新，例如改主題）
    @State private var note: WikiItem
    var onQuote: ((WikiItem) -> Void)? = nil   // 引用此筆記的回調

    init(item: WikiItem, onQuote: ((WikiItem) -> Void)? = nil) {
        _note = State(initialValue: item)
        self.onQuote = onQuote
    }

    @State private var showEditor = false

    @State private var fullContent      = ""
    @State private var isLoadingContent = true
    @State private var showShareSheet   = false
    @State private var copied           = false

    @State private var heroImages:       [UIImage] = []
    @State private var linkedAssetIds:   [String]  = []
    @State private var suggestedIds:     [String]  = []
    @State private var coverIndex        = 0
    @State private var photoDays:        [PhotoDay] = []
    @State private var coverPicks:       [String]  = []      // 多天的筆記：封面拼貼的照片

    @State private var pager:            PagerRequest? = nil
    @State private var showAllPhotos     = false

    private let coverHeight: CGFloat = 230
    private let previewLimit = 6          // 照片牆預覽：兩排 × 三張

    /// 這篇筆記的照片：有記錄照片識別碼就用相簿照片；舊筆記才用 App 存的對話圖片
    private var photos: [WikiPhotoSource] {
        if !linkedAssetIds.isEmpty { return linkedAssetIds.map { .asset($0) } }
        return heroImages.enumerated().map { .image($0.element, $0.offset) }
    }

    private var suggestions: [WikiPhotoSource] { suggestedIds.map { .asset($0) } }

    /// 照片跨好幾天（旅行）：封面改成拼貼、照片依日期分組左右滑
    private var isDayMode: Bool { photoDays.count >= 2 && linkedAssetIds.count >= 8 }

    private var bodyText: String {
        let raw = fullContent.isEmpty ? (note.preview ?? "") : fullContent
        return NoteText.removingTitleLine(raw, topic: note.topic)
    }

    /// 摘要和內文第一句幾乎一樣時不重複顯示
    private var showsSummary: Bool {
        !note.summary.isEmpty && !NoteText.isSimilar(note.summary, NoteText.firstLine(bodyText))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                navBar
                    .background(Theme.background)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if isDayMode { collageCover } else { cover }
                        articleHeader
                        if showsSummary { summaryBlock }
                        contentBlock
                        if isDayMode { daySections } else { photoWall }
                        suggestionStrip
                        Spacer(minLength: 60)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .closeOverlaysForAgent)) { _ in dismiss() }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: ["\(note.topic)\n\n\(note.summary)\n\n\(bodyText)"])
        }
        .sheet(isPresented: $showAllPhotos) {
            WikiPhotoGridSheet(title: note.topic, sources: photos, days: isDayMode ? photoDays : [],
                               onRemove: linkedAssetIds.isEmpty ? nil : { id in removePhoto(id) })
        }
        .fullScreenCover(item: $pager) { request in
            WikiPhotoPager(sources: request.sources, startIndex: request.index,
                           onRemove: request.removable ? { id in removePhoto(id) } : nil)
        }
        .sheet(isPresented: $showEditor) {
            WikiNoteEditor(note: note, content: fullContent.isEmpty ? (note.preview ?? "") : fullContent) { updated, content in
                note = updated
                fullContent = content
            }
        }
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 17))
                }
                .foregroundColor(Theme.text)
            }
            Spacer()
            if onQuote != nil {
                Button(action: {
                    onQuote?(note)
                    dismiss()
                }) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 17))
                        .foregroundColor(Theme.text)
                }
                .padding(.trailing, 8)
            }
            Button(action: { showEditor = true }) {
                Image(systemName: "pencil")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.text)
            }
            .padding(.trailing, 8)
            .accessibilityLabel("編輯筆記")
            // 複製整篇（標題、摘要、內文）；內文也可以長按選取一部分
            Button(action: copyNote) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.text)
                    .frame(width: 22)
            }
            .padding(.trailing, 8)
            .accessibilityLabel(copied ? "已複製" : "複製筆記")
            Button(action: { showShareSheet = true }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.text)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func copyNote() {
        let parts = [note.topic, showsSummary ? note.summary : "", bodyText].filter { !$0.isEmpty }
        UIPasteboard.general.string = parts.joined(separator: "\n\n")
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { withAnimation { copied = false } }
        }
    }

    // MARK: - Cover

    @ViewBuilder
    private var cover: some View {
        let sources = photos
        if !sources.isEmpty {
            TabView(selection: $coverIndex) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    WikiPhotoView(source: source, pixelSize: 1400, fill: true)
                        .frame(maxWidth: .infinity)
                        .frame(height: coverHeight)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { pager = PagerRequest(sources: sources, index: index) }
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: coverHeight)
            .overlay(alignment: .bottomTrailing) {
                if sources.count > 1 {
                    Text("\(min(coverIndex, sources.count - 1) + 1) / \(sources.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .padding(12)
                }
            }
            .padding(.bottom, 18)
        }
    }

    // MARK: - Header

    private var articleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.topic)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            let meta = [note.updated_at.flatMap { $0.isEmpty ? nil : formattedDate($0) },
                        photos.isEmpty ? nil : "\(photos.count) 張照片"]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text.opacity(0.38))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, photos.isEmpty ? 6 : 0)
        .padding(.bottom, 14)
    }

    // MARK: - Summary Quote

    private var summaryBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Theme.text.opacity(0.55))
                .frame(width: 3)
                .cornerRadius(2)
            Text(note.summary)
                .font(.system(size: 15))
                .foregroundColor(Theme.text.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(5)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentBlock: some View {
        let text = bodyText
        Group {
            if isLoadingContent && text.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.text)
                    Text("載入內容中…")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text.opacity(0.45))
                }
            } else if !text.isEmpty {
                NoteContentRenderer(content: text)
                    .textSelection(.enabled)   // 長按可以選取、複製一段文字
            } else {
                Text("目前無筆記內容")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.text.opacity(0.28))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Photo wall（這篇的照片）

    @ViewBuilder
    private var photoWall: some View {
        let sources = photos
        if sources.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                sectionDivider
                HStack {
                    sectionLabel("這篇的照片", icon: "photo.on.rectangle.angled")
                    Spacer()
                    if sources.count > previewLimit {
                        Button("查看全部 \(sources.count) 張") { showAllPhotos = true }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.text.opacity(0.75))
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(Array(sources.prefix(previewLimit).enumerated()), id: \.element.id) { index, source in
                        let isLast = index == previewLimit - 1 && sources.count > previewLimit
                        WikiSquareCell(source: source,
                                       overlayText: isLast ? "+\(sources.count - previewLimit + 1)" : nil)
                            .onTapGesture {
                                if isLast { showAllPhotos = true }
                                else { pager = PagerRequest(sources: sources, index: index) }
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }

    // MARK: - Suggestions（可能相關）

    @ViewBuilder
    private var suggestionStrip: some View {
        let sources = suggestions
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionDivider
                VStack(alignment: .leading, spacing: 3) {
                    sectionLabel("可能相關的照片", icon: "photo.stack")
                    Text("依筆記內容在相簿中搜尋，不一定屬於這篇筆記")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.text.opacity(0.32))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                            WikiSquareCell(source: source, overlayText: nil)
                                .frame(width: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .onTapGesture { pager = PagerRequest(sources: sources, index: index, removable: false) }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Theme.text.opacity(0.1))
            .frame(height: 1)
            .padding(.bottom, 8)
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12))
            Text(title).font(.system(size: 14, weight: .semibold))
        }
        .foregroundColor(Theme.text.opacity(0.75))
    }

    // MARK: - Loading

    private func load() async {
        heroImages = WikiImageStorage.loadAll(topic: note.topic)

        // 直接讀這一篇（不用模糊搜尋，避免讀到名稱相近的別篇）
        if let stored = try? await WikiService.shared.note(topic: note.topic) {
            fullContent = stored.content
        }
        isLoadingContent = false

        await reloadPhotos()

        let query = "\(note.topic) \(note.summary)"
        let exclude = Set(linkedAssetIds)
        let found = await Task.detached(priority: .userInitiated) {
            DatabaseManager.shared.searchPhotos(text: query)
        }.value
        suggestedIds = Array(found.filter { !exclude.contains($0) }.prefix(9))
    }

    private func reloadPhotos() async {
        let linked = (try? await WikiService.shared.photoAssetIds(topic: note.topic)) ?? []
        // 照片在相簿中被刪掉的就不顯示；依拍攝時間排序
        let infos = await Task.detached(priority: .userInitiated) { Self.photoInfos(linked) }.value
        linkedAssetIds = infos.map(\.id)
        photoDays = Self.groupByDay(infos)
        coverPicks = Self.pickCover(infos, days: photoDays)
        coverIndex = 0
    }

    /// 從筆記移除一張照片（只刪連結，相簿裡的照片不受影響）
    private func removePhoto(_ assetId: String) {
        Task {
            try? await WikiService.shared.unlinkPhoto(topic: note.topic, assetId: assetId)
            await reloadPhotos()
        }
    }

    /// 仍在相簿中的照片，依拍攝時間排序（沒有時間的放最後，保持原本順序）
    private static func photoInfos(_ ids: [String]) -> [LinkedPhotoInfo] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byId: [String: LinkedPhotoInfo] = [:]
        result.enumerateObjects { asset, _, _ in
            byId[asset.localIdentifier] = LinkedPhotoInfo(id: asset.localIdentifier, date: asset.creationDate,
                                                          isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot))
        }
        let ordered = ids.compactMap { byId[$0] }
        return ordered.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x < y
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.offset < b.offset
            }
        }.map(\.element)
    }

    private static func groupByDay(_ infos: [LinkedPhotoInfo]) -> [PhotoDay] {
        let keyFormatter = DateFormatter()
        keyFormatter.dateFormat = "yyyy-MM-dd"
        let titleFormatter = DateFormatter()
        titleFormatter.locale = Locale(identifier: "zh_Hant_TW")
        titleFormatter.dateFormat = "M/d（EEEEE）"
        var days: [PhotoDay] = []
        for info in infos {
            guard let date = info.date else { continue }
            let key = keyFormatter.string(from: date)
            if let last = days.last, last.id == key {
                days[days.count - 1] = PhotoDay(id: key, title: last.title, assetIds: last.assetIds + [info.id])
            } else {
                days.append(PhotoDay(id: key, title: titleFormatter.string(from: date), assetIds: [info.id]))
            }
        }
        return days
    }

    /// 封面拼貼：從照片最多的幾天各挑一張（避開截圖），再依時間排列
    private static func pickCover(_ infos: [LinkedPhotoInfo], days: [PhotoDay]) -> [String] {
        let screenshots = Set(infos.filter(\.isScreenshot).map(\.id))
        let order = Dictionary(uniqueKeysWithValues: infos.enumerated().map { ($0.element.id, $0.offset) })
        var picks: [String] = []
        for day in days.sorted(by: { $0.assetIds.count > $1.assetIds.count }) {
            let candidates = day.assetIds.filter { !screenshots.contains($0) }
            guard !candidates.isEmpty else { continue }
            picks.append(candidates[candidates.count / 2])
            if picks.count == 3 { break }
        }
        if picks.count < 3 {
            for info in infos where !info.isScreenshot && !picks.contains(info.id) {
                picks.append(info.id)
                if picks.count == 3 { break }
            }
        }
        return picks.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
    }

    // MARK: - 旅行筆記：拼貼封面、依日期分組

    @ViewBuilder
    private var collageCover: some View {
        let all = photos
        let picks = coverPicks.isEmpty ? Array(linkedAssetIds.prefix(3)) : coverPicks
        let open: (String) -> Void = { id in
            pager = PagerRequest(sources: all, index: linkedAssetIds.firstIndex(of: id) ?? 0)
        }
        GeometryReader { geo in
            let gap: CGFloat = 3
            let height = coverHeight + 20
            HStack(spacing: gap) {
                if let first = picks.first {
                    collageCell(first, open: open)
                        .frame(width: picks.count > 1 ? geo.size.width * 0.64 : geo.size.width, height: height)
                }
                if picks.count > 1 {
                    VStack(spacing: gap) {
                        ForEach(picks.dropFirst().prefix(2), id: \.self) { id in
                            collageCell(id, open: open)
                                .frame(height: picks.count > 2 ? (height - gap) / 2 : height)
                        }
                    }
                }
            }
        }
        .frame(height: coverHeight + 20)
        .overlay(alignment: .bottomTrailing) {
            Text("\(linkedAssetIds.count) 張・\(photoDays.count) 天")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
                .padding(12)
        }
        .padding(.bottom, 18)
    }

    private func collageCell(_ id: String, open: @escaping (String) -> Void) -> some View {
        WikiPhotoView(source: .asset(id), pixelSize: 1200, fill: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { open(id) }
    }

    /// 這篇的照片：每天一列，左右滑動
    private var daySections: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionDivider
            HStack {
                sectionLabel("這篇的照片", icon: "photo.on.rectangle.angled")
                Spacer()
                Button("查看全部 \(linkedAssetIds.count) 張") { showAllPhotos = true }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text.opacity(0.75))
            }
            .padding(.horizontal, 20)
            ForEach(photoDays) { day in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(day.title)・\(day.assetIds.count) 張")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.7))
                        .padding(.horizontal, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 4) {
                            let sources = day.assetIds.map { WikiPhotoSource.asset($0) }
                            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                                WikiSquareCell(source: source, overlayText: nil)
                                    .frame(width: 108)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .onTapGesture { pager = PagerRequest(sources: sources, index: index) }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .frame(height: 108)
                }
            }
        }
        .padding(.top, 10)
    }

    private func formattedDate(_ raw: String) -> String {
        AppDateFormatters.localDateTime(fromSQLite: raw)
    }
}

// MARK: - Text helpers

private enum NoteText {
    private static func normalize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^(#{1,6}\s*|[-*•]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "**", with: "")
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return String(s.unicodeScalars.filter { !drop.contains($0) })
    }

    static func firstLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    /// 內文第一行就是標題（例如「# 亞尼克原味生乳捲」）時拿掉，標題已經顯示在上方
    static func removingTitleLine(_ text: String, topic: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first, !topic.isEmpty, normalize(first) == normalize(topic) {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 兩句話幾乎一樣（只差一兩個字，例如「是」和「為」）
    static func isSimilar(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y || x.contains(y) || y.contains(x) { return true }
        func bigrams(_ s: String) -> Set<String> {
            let chars = Array(s)
            guard chars.count > 1 else { return [s] }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
        }
        let p = bigrams(x), q = bigrams(y)
        let overlap = Double(p.intersection(q).count) / Double(max(p.union(q).count, 1))
        return overlap >= 0.6
    }
}

// MARK: - Photo views

/// 相簿照片（依需要的大小讀取）或 App 存的圖片
private struct WikiPhotoView: View {
    let source: WikiPhotoSource
    let pixelSize: CGFloat
    let fill: Bool

    var body: some View {
        switch source {
        case .image(let image, _):
            Color.clear.overlay(
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            )
        case .asset(let assetId):
            WikiAssetImage(assetId: assetId, pixelSize: pixelSize, fill: fill)
        }
    }
}

private struct WikiAssetImage: View {
    let assetId: String
    let pixelSize: CGFloat
    let fill: Bool

    @State private var image: UIImage?

    var body: some View {
        Theme.surface(0.1)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                }
            }
            .task(id: assetId) { image = await Self.load(assetId: assetId, pixelSize: pixelSize, fill: fill) }
    }

    private static func load(assetId: String, pixelSize: CGFloat, fill: Bool) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // 只回呼一次
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: CGSize(width: pixelSize, height: pixelSize),
                                                  contentMode: fill ? .aspectFill : .aspectFit,
                                                  options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

/// 全螢幕瀏覽的一頁：可以兩指縮放、點兩下放大
private struct ZoomablePhotoPage: View {
    let source: WikiPhotoSource
    @Binding var isZoomed: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.background
            if let image {
                ZoomableImage(image: image, isZoomed: $isZoomed)
            } else {
                ProgressView().tint(Theme.text)
            }
        }
        .task(id: source.id) {
            switch source {
            case .image(let value, _):
                image = value
            case .asset(let assetId):
                image = await Self.load(assetId: assetId)
            }
        }
    }

    private static func load(assetId: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 2400, height: 2400),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

/// 正方形縮圖（照片牆、可能相關）
private struct WikiSquareCell: View {
    let source: WikiPhotoSource
    let overlayText: String?

    var body: some View {
        Theme.surface(0.1)
            .aspectRatio(1, contentMode: .fit)
            .overlay { WikiPhotoView(source: source, pixelSize: 360, fill: true) }
            .overlay {
                if let overlayText {
                    ZStack {
                        Color.black.opacity(0.55)
                        Text(overlayText)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

// MARK: - All photos（查看全部）

private struct WikiPhotoGridSheet: View {
    let title: String
    let sources: [WikiPhotoSource]
    var days: [PhotoDay] = []
    var onRemove: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var pager: PagerRequest?

    var body: some View {
        NavigationStack {
            ScrollView {
                if days.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                            WikiSquareCell(source: source, overlayText: nil)
                                .onTapGesture { pager = PagerRequest(sources: sources, index: index) }
                        }
                    }
                } else {
                    // 依日期分段（標題固定在上方）
                    let indexById = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, $0.offset) })
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                              spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(days) { day in
                            Section {
                                ForEach(day.assetIds, id: \.self) { id in
                                    WikiSquareCell(source: .asset(id), overlayText: nil)
                                        .onTapGesture { pager = PagerRequest(sources: sources, index: indexById[id] ?? 0) }
                                }
                            } header: {
                                Text("\(day.title)・\(day.assetIds.count) 張")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Theme.background.opacity(0.92))
                            }
                        }
                    }
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("\(sources.count) 張照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .fullScreenCover(item: $pager) { request in
            WikiPhotoPager(sources: request.sources, startIndex: request.index, onRemove: onRemove)
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeOverlaysForAgent)) { _ in dismiss() }
    }
}

// MARK: - Pager（點照片後左右滑動瀏覽）

private struct WikiPhotoPager: View {
    /// 從筆記移除照片（只刪連結）；nil 時不顯示移除按鈕
    let onRemove: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var sources: [WikiPhotoSource]
    @State private var index: Int
    @State private var infoAssetId: String?
    @State private var confirmRemove = false
    @State private var isZoomed = false
    /// 往下拖的距離：超過一段就關閉（和系統照片 App 一樣）
    @State private var dragOffset: CGFloat = 0

    private var dragProgress: Double { min(Double(dragOffset / 300), 1) }

    init(sources: [WikiPhotoSource], startIndex: Int, onRemove: ((String) -> Void)? = nil) {
        _sources = State(initialValue: sources)
        self.onRemove = onRemove
        _index = State(initialValue: min(max(startIndex, 0), max(sources.count - 1, 0)))
    }

    private var currentAssetId: String? {
        sources.indices.contains(index) ? sources[index].assetId : nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.opacity(1 - dragProgress * 0.8).ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { offset, source in
                    ZoomablePhotoPage(source: source, isZoomed: $isZoomed)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(isZoomed)   // 放大時拖曳照片，不換頁
            .onChange(of: index) { _, _ in isZoomed = false }
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .scaleEffect(1 - dragProgress * 0.15)
            // 由上往下滑：離開這張照片（放大時不觸發，左右滑仍是換頁）
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard !isZoomed, value.translation.height > 0,
                              value.translation.height > abs(value.translation.width) * 1.5 else { return }
                        dragOffset = value.translation.height
                    }
                    .onEnded { value in
                        guard dragOffset > 0 else { return }
                        if dragOffset > 120 || value.predictedEndTranslation.height > 300 {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                        }
                    }
            )

            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                Spacer()
                if sources.count > 1 {
                    Text("\(index + 1) / \(sources.count)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text)
                }
                Spacer()
                if onRemove != nil, currentAssetId != nil {
                    Button(action: { confirmRemove = true }) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("從筆記移除這張照片")
                }
                if let assetId = currentAssetId {
                    Button(action: { infoAssetId = assetId }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                } else {
                    Color.clear.frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .opacity(1 - dragProgress)
        }
        .presentationBackground(.clear)   // 往下拖時看得到後面的筆記
        .sheet(item: Binding(
            get: { infoAssetId.map { IdentifiableString(id: $0) } },
            set: { infoAssetId = $0?.id }
        )) { asset in
            PhotoDetailModal(assetId: asset.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeOverlaysForAgent)) { _ in dismiss() }
        .confirmationDialog("從筆記移除這張照片？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("從筆記移除", role: .destructive) {
                guard let id = currentAssetId else { return }
                onRemove?(id)
                sources.remove(at: index)
                if sources.isEmpty { dismiss() } else { index = min(index, sources.count - 1) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只移除筆記和照片的連結，相簿裡的照片不受影響。")
        }
    }
}

// MARK: - 編輯筆記

/// 使用者自己修改筆記：主題（最多 10 字）、摘要、內容（Markdown）。
struct WikiNoteEditor: View {
    let note: WikiItem
    let onSaved: (WikiItem, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var topic: String
    @State private var summary: String
    @State private var content: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(note: WikiItem, content: String, onSaved: @escaping (WikiItem, String) -> Void) {
        self.note = note
        self.onSaved = onSaved
        _topic = State(initialValue: note.topic)
        _summary = State(initialValue: note.summary)
        _content = State(initialValue: content)
    }

    /// 想去、購物清單的筆記由 App 自動整理，不能改名
    private var topicLocked: Bool { ListNotes.isListNote(note.topic) }
    private var trimmedTopic: String { topic.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmedTopic.isEmpty && trimmedTopic.count <= 10
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("主題（最多 10 字）") {
                        TextField("主題", text: $topic)
                            .disabled(topicLocked)
                            .opacity(topicLocked ? 0.5 : 1)
                        if trimmedTopic.count > 10 {
                            Text("主題超過 10 個字").font(.system(size: 12)).foregroundColor(.orange)
                        }
                        if topicLocked {
                            Text("想去清單由 App 自動整理，不能改名；內容也會在清單變動時重新產生。")
                                .font(.system(size: 12)).foregroundColor(Theme.text.opacity(0.45))
                        }
                    }
                    field("摘要") {
                        TextField("一句話說明這篇筆記", text: $summary, axis: .vertical)
                            .lineLimit(1...3)
                    }
                    field("內容（Markdown：## 標題、- 項目）") {
                        TextEditor(text: $content)
                            .frame(minHeight: 320)
                            .scrollContentBackground(.hidden)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.system(size: 13)).foregroundColor(.orange)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("編輯筆記")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("儲存", action: save).disabled(!canSave)
                    }
                }
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text.opacity(0.55))
            VStack(alignment: .leading, spacing: 6, content: content)
                .font(.system(size: 16))
                .foregroundColor(Theme.text)
                .padding(12)
                .themeCard(radius: 22)
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        let newTopic = trimmedTopic, newSummary = summary, newContent = content
        Task {
            do {
                let updated = try await WikiService.shared.edit(oldTopic: note.topic, newTopic: newTopic,
                                                                summary: newSummary, content: newContent)
                await MainActor.run {
                    isSaving = false
                    if let updated { onSaved(updated, WikiText.compactContent(newContent)) }
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

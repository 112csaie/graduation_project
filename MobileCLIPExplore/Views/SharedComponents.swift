import SwiftUI

// MARK: - 頂部頭像 (靠左)
struct HeaderSection: View {
    var body: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(Theme.tile)
                    .frame(width: 44, height: 44)
                
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(Theme.secondaryText)
            }
            .padding(.horizontal, 20)
            
            Spacer()
        }
    }
}

// MARK: - 卡片內的單張圖片框
struct AlbumItem: View {
    let assetId: String // 接收真實的 assetId
    
    var body: some View {
        // 使用你寫好的照片讀取元件
        PhotoThumbnailView(assetId: assetId)
    }
}

// MARK: - 分類卡片元件
struct CategoryCard: View {
    let title: String
    let assetIds: [String]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            // 卡片標題
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Theme.text)
                .padding(.top, 15)
                .padding(.leading, 15)
            
            // 橫向滑動的照片列表
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 15) {
                    // 若有照片則顯示，若沒有則顯示空框 (符合你設計圖的樣式)
                    if assetIds.isEmpty {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.surface(0.3))
                            .frame(width: 120, height: 120)
                    } else {
                        ForEach(assetIds, id: \.self) { id in
                            PhotoThumbnailView(assetId: id)
                                .frame(width: 120, height: 120)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 15)
            }
        }

        .themeCard(radius: 22)
    }
}
// MARK: - 底部導覽列
/// 圓角的分頁列，中間是凸起的 Agent 圓形按鈕（亮色）。順序：照片、相簿、Agent、最愛、我的（編號見 AppTab）。
/// 顏色跟著深色模式（Theme）。
struct BottomNavBar: View {
    @Binding var selectedTab: Int
    /// 「相簿」分頁的紅點：待確認 tag 的數量
    @ObservedObject private var candidates = CandidateCounter.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            NavBarItem(iconName: "photo", title: "照片", tabIndex: AppTab.photos, selectedTab: $selectedTab)
            NavBarItem(iconName: "square.grid.2x2", title: "相簿", tabIndex: AppTab.albums, selectedTab: $selectedTab,
                       badge: candidates.count >= CandidateReminderCard.minimumCount ? candidates.count : 0)
            AgentNavButton(selectedTab: $selectedTab)
            NavBarItem(iconName: "heart", title: "最愛", tabIndex: AppTab.favorites, selectedTab: $selectedTab)
            NavBarItem(iconName: "person", title: "我的", tabIndex: AppTab.me, selectedTab: $selectedTab)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.bar)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }
}

/// 中間凸起的 Agent 按鈕
private struct AgentNavButton: View {
    @Binding var selectedTab: Int

    var body: some View {
        Button(action: { selectedTab = AppTab.agent }) {
            VStack(spacing: 3) {
                SelfieGlyph(size: 32, color: Theme.onAccent)
                    .frame(width: 54, height: 54)
                    .background(Theme.accent)
                    .clipShape(Circle())
                    // 外圈用頁面背景色，看起來像從分頁列浮起來
                    .overlay(Circle().stroke(Theme.background, lineWidth: 5))
                    .offset(y: -18)
                    .padding(.bottom, -18)
                Text("Agent")
                    .font(.system(size: 10, weight: selectedTab == AppTab.agent ? .bold : .medium, design: .rounded))
                    .foregroundColor(selectedTab == AppTab.agent ? Theme.text : Theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agent")
    }
}

// MARK: - 底部導覽列按鈕
struct NavBarItem: View {
    let iconName: String
    /// 圖示下方的文字（第一次使用也看得懂每個分頁是什麼）
    var title: String = ""
    let tabIndex: Int
    @Binding var selectedTab: Int
    /// 圖示右上角的數字（0 不顯示）
    var badge: Int = 0

    private var isSelected: Bool { selectedTab == tabIndex }

    var body: some View {
        Button(action: { selectedTab = tabIndex }) {
            VStack(spacing: 3) {
                Image(systemName: iconName)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 30, height: 26)   // 固定外框，不同圖示看起來一樣大
                    .foregroundColor(isSelected ? Theme.text : Theme.secondaryText)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.red)
                                .clipShape(Capsule())
                                .offset(x: 10, y: -4)
                        }
                    }
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .rounded))
                        .foregroundColor(isSelected ? Theme.text : Theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - 照片排序（由新到舊／由舊到新）

/// 照片排序偏好：「照片」頁與所有相簿共用同一個設定。
enum PhotoSortPreference {
    static let storageKey = "photoSortNewestFirst"
}

/// 小圓形排序按鈕：點開選擇「由新到舊」或「由舊到新」（依照片拍攝時間）。
struct PhotoSortButton: View {
    @Binding var newestFirst: Bool

    /// 點一下直接換成另一種排序（不用再從選單選）
    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) { newestFirst.toggle() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            VStack(spacing: 1) {
                Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Text(newestFirst ? "新→舊" : "舊→新")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(Theme.text)
            .frame(width: 44, height: 44)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(newestFirst ? "排序：由新到舊，點一下改成由舊到新" : "排序：由舊到新，點一下改成由新到舊")
    }
}

// MARK: - 可縮放的照片

/// 兩指縮放（1～5 倍）、放大後可以拖曳、點兩下放大／還原。
/// isZoomed 讓外層的左右滑動在放大時暫停，避免拖曳照片時換到下一張。
struct ZoomableImage: View {
    let image: UIImage
    @Binding var isZoomed: Bool

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var zoomed: Bool { scale > 1.01 }

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in scale = min(max(lastScale * value, 1), 5) }
                        .onEnded { _ in
                            if scale <= 1.01 { reset() } else { lastScale = scale; isZoomed = true }
                        }
                )
                // 只有放大時才接手拖曳；沒放大時讓外層可以左右滑到下一張
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in lastOffset = clamped(offset, in: geo.size) ; offset = lastOffset },
                    including: zoomed ? .all : .subviews
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if zoomed {
                            reset()
                        } else {
                            scale = 2.5
                            lastScale = 2.5
                            isZoomed = true
                        }
                    }
                }
        }
        .clipped()
        .onDisappear { reset() }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
        isZoomed = false
    }

    /// 拖曳不要超出照片放大後的範圍
    private func clamped(_ value: CGSize, in size: CGSize) -> CGSize {
        let maxX = size.width * (scale - 1) / 2
        let maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(value.width, -maxX), maxX), height: min(max(value.height, -maxY), maxY))
    }
}

// MARK: - 共用的日期格式

/// 建立 DateFormatter 的成本不低；清單每一列、每次畫面更新都重建會拖慢捲動。這裡建一次重複使用（格式化是執行緒安全的）。
enum AppDateFormatters {
    /// SQLite CURRENT_TIMESTAMP（UTC）
    static let sqliteUTC: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    static let dateTime: DateFormatter = make("yyyy/M/d HH:mm")
    static let dateTimeWeekday: DateFormatter = make("yyyy/M/d（EEEEE）HH:mm")
    static let time: DateFormatter = make("HH:mm")
    static let monthDay: DateFormatter = make("M/d")
    static let yearMonth: DateFormatter = make("yyyy 年 M 月")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    /// SQLite 的 UTC 時間字串 → 裝置時區的「yyyy/M/d HH:mm」；看不懂的格式原樣傳回
    static func localDateTime(fromSQLite raw: String) -> String {
        guard let date = sqliteUTC.date(from: raw) else { return raw }
        return dateTime.string(from: date)
    }
}

// MARK: - 沒有連上電腦（Agent 後端）的提示

/// 需要電腦後端的功能上方顯示：沒連上時說明哪些功能暫時不能用、哪些照常，並可以重試。
/// 連上或還不知道時不顯示任何東西。
struct AgentOfflineNotice: View {
    /// 這裡哪個動作需要電腦，例如「Agent 回覆」「加入新的商品」
    let feature: String
    /// 不需要電腦、照常可以用的部分（可省略）
    var stillWorks: String? = nil
    @ObservedObject private var connection = AgentConnection.shared

    var body: some View {
        // 外層 VStack 一定在畫面上，onAppear 才會觸發檢查（連得上時裡面是空的，不占空間）
        VStack(spacing: 0) {
            if connection.isOffline {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                        .font(.system(size: 16))
                        .foregroundColor(.orange)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("沒有連上後端：\(feature)暫時不能用")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.text)
                        Text("需要開發者的後端開著、和手機在同一個 Wi-Fi。" + (stillWorks.map { "\($0)照常可以用。" } ?? ""))
                            .font(.system(size: 12))
                            .foregroundColor(Theme.text.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button("重試") { connection.check(force: true) }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.text)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(12)
            }
        }
        .onAppear { connection.check() }
    }
}

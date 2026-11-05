// Theme.swift
//
// App 的配色與深色模式。
// - 冷調灰藍配色：Silver White #E7E8E4、Praise Giving #B1B2AE、Puffy Cloud #D3DFF2、Wild Clary #93A4C1、Hēi Sè Black #18202B
// - 深色模式（預設）：黑藍底，Puffy Cloud 當唯一的亮色重點
// - 淺色模式：米白底，Puffy Cloud 方塊、Wild Clary 重點、Praise Giving 邊線
// 規則：整頁只有一個亮色（Theme.accent），用在選中狀態、狀態小標籤、中間的 Agent 按鈕。
// 所有畫面都用這裡的顏色（不要再寫死 .white / .black / Color(white:)）：
// - 字與線：Theme.text（可加 .opacity）、Theme.secondaryText；頁面底：Theme.background；層次底色：Theme.surface(level)
// - 照片上、黑色遮罩上、紅色徽章上的字維持 .white
// 字型：ContentView 統一設成圓體（.fontDesign(.rounded)）。

import SwiftUI
import UIKit

/// 深色模式設定：開啟（黑色）、關閉（米色）、跟隨系統
enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system

    static let storageKey = "appearanceMode"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "開啟"
        case .light: return "關閉"
        case .system: return "跟隨系統"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .dark
    }
}

enum Theme {
    // 原始色票
    static let silverWhite = UIColor(hex: 0xE7E8E4)
    static let praiseGiving = UIColor(hex: 0xB1B2AE)
    static let puffyCloud = UIColor(hex: 0xD3DFF2)
    static let wildClary = UIColor(hex: 0x93A4C1)
    static let black = UIColor(hex: 0x18202B)

    /// 頁面背景
    static let background = dynamic(dark: black, light: silverWhite)
    /// 卡片（摘要卡、列表）
    static let card = dynamic(dark: UIColor(hex: 0x232D3B), light: UIColor(hex: 0xF4F4F1))
    /// 紀錄方塊
    static let tile = dynamic(dark: UIColor(hex: 0x2A3647), light: puffyCloud)
    /// 底部分頁列
    static let bar = dynamic(dark: UIColor(hex: 0x1D2633), light: UIColor(hex: 0xF4F4F1))
    /// 方塊裡的圓形圖示底
    static let iconBackground = dynamic(dark: black, light: UIColor(hex: 0xF4F4F1))
    static let text = dynamic(dark: silverWhite, light: black)
    /// 給 UIKit（UITextView 等）用的文字顏色，同樣跟著深色模式
    static let uiText = UIColor { $0.userInterfaceStyle == .dark ? silverWhite : black }
    static let secondaryText = dynamic(dark: wildClary, light: UIColor(hex: 0x6E7480))
    /// 資訊標籤（照片頁的第幾張、日期、地點）：和亮色、背景都不同的中間色。深色是 Wild Clary，淺色是 Puffy Cloud
    static let info = dynamic(dark: wildClary, light: puffyCloud)
    /// 唯一的亮色重點
    static let accent = dynamic(dark: puffyCloud, light: wildClary)
    /// 放在亮色上的文字
    static let onAccent = Color(black)
    /// 卡片邊線（深色模式不畫）
    static let border = dynamic(dark: .clear, light: praiseGiving)

    /// 有顏色的狀態（打勾、去過、買到了、狀態標籤底色）：深色是 Puffy Cloud，淺色是加深的 Wild Clary（米白底上看得清楚）
    static let highlight = dynamic(dark: puffyCloud, light: UIColor(hex: 0x5A73A0))
    /// 系統按鈕、開關、連結的顏色
    static let tint = dynamic(dark: puffyCloud, light: UIColor(hex: 0x4F6A93))

    /// 層次底色（取代以前的 Color(white: 0.1) 這類灰色）。level 0 是頁面背景，越大越突出。
    /// 深色：從黑藍往 Wild Clary 漸亮；淺色：卡片比背景亮（奶白），再往上是淺藍。
    static func surface(_ level: Double) -> Color {
        let t = CGFloat(min(max(level, 0), 1))
        let dark = blend(black, level < 0.8 ? wildClary : silverWhite, level < 0.8 ? t : (t - 0.8) / 0.2)
        let light: UIColor
        switch t {
        case ..<0.05: light = silverWhite
        case ..<0.135: light = UIColor(hex: 0xF4F4F1)     // 一般卡片（以前的 0.1～0.13）
        case ..<0.2: light = UIColor(hex: 0xEAF0F8)       // 卡片裡的卡片、按鈕底
        case ..<0.3: light = puffyCloud
        default: light = blend(puffyCloud, wildClary, (t - 0.3) / 0.5)
        }
        return dynamic(dark: dark, light: light)
    }

    private static func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        let t = min(max(t, 0), 1)
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }

    private static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - 共用元件

/// 卡片底：圓角、卡片色，淺色模式加細邊線
struct ThemeCard: ViewModifier {
    var color: Color = Theme.card
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
    }
}

extension View {
    func themeCard(_ color: Color = Theme.card, radius: CGFloat = 20) -> some View {
        modifier(ThemeCard(color: color, radius: radius))
    }
}

/// 狀態小標籤（「連續 2 週」「4」「1 天」）：全部用同一個亮色
struct AccentPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(Theme.onAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accent)
            .clipShape(Capsule())
    }
}

/// 可以左右滑的分類小標籤（選中的是亮色）
struct ThemeChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                .foregroundColor(isSelected ? Theme.onAccent : Theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Theme.accent : Theme.card)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isSelected ? Color.clear : Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// 圓形圖示（方塊左上角）
struct ThemeIcon: View {
    let systemName: String
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundColor(Theme.text)
            .frame(width: size, height: size)
            .background(Theme.iconBackground)
            .clipShape(Circle())
    }
}

/// 深色模式快速切換（月亮／太陽）。跟隨系統時，切到和目前相反的模式。
struct AppearanceToggleButton: View {
    @AppStorage(AppearanceMode.storageKey) private var mode = AppearanceMode.dark.rawValue
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.25)) {
                mode = (scheme == .dark ? AppearanceMode.light : AppearanceMode.dark).rawValue
            }
        }) {
            Image(systemName: scheme == .dark ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Theme.onAccent)
                .frame(width: 44, height: 44)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(scheme == .dark ? "關閉深色模式" : "開啟深色模式")
    }
}

/// 標題列右邊的圓角方形按鈕（搜尋、排序…），和深色模式按鈕同樣大小
struct HeaderIconButton: View {
    let systemName: String
    var label: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.text)
                .frame(width: 44, height: 44)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 照片頁每天的日期貼紙（今天・10/21　12）
struct PhotoDaySticker: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .bold))
            Text(title)
                .font(.system(size: 13, weight: .bold))
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .opacity(0.65)
        }
        .foregroundColor(Theme.onAccent)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Theme.accent)
        .clipShape(Capsule())
    }
}


/// 想去清單的「出發」按鈕：箭頭緊貼文字的小膠囊（不用 Label，避免在清單裡圖示和文字被拉開）
struct GoButtonLabel: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .bold))
            Text("出發")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundColor(Theme.onAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.accent)
        .clipShape(Capsule())
        .fixedSize()
    }
}


// MARK: - App 名稱與 Slogan

enum AppBrand {
    static let name = "selfIE"
    /// I = Image、E = Evaluate
    static let slogan = "自動整理你/妳拍下的瞬間"
}

/// 「selfIE」字標：self 用一般文字色，IE（Image、Evaluate）用亮色
struct SelfieWordmark: View {
    var size: CGFloat = 40

    var body: some View {
        (Text("self").foregroundColor(Theme.text) + Text("IE").foregroundColor(Theme.highlight))
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .kerning(-size * 0.02)
            .accessibilityLabel(AppBrand.name)
    }
}

// MARK: - selfIE 圖示（取代星光）

/// 和 App Icon 同一個造型：一張微微傾斜的照片，旁邊三個分類吊牌（Image + Evaluate）。
/// 用在 Agent 按鈕、Agent 頭像、照片頁的「問 Agent」，不用星光（避免像其他 AI 產品）。
struct SelfieGlyph: View {
    var size: CGFloat = 22
    var color: Color = Theme.onAccent

    var body: some View {
        let s = size
        ZStack {
            // 照片：外框＋山＋太陽
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.12, style: .continuous)
                    .stroke(color, lineWidth: s * 0.1)
                Circle()
                    .fill(color)
                    .frame(width: s * 0.11, height: s * 0.11)
                    .offset(x: s * 0.07, y: -s * 0.14)
                MountainShape()
                    .fill(color)
                    .frame(width: s * 0.34, height: s * 0.2)
                    .offset(y: s * 0.09)
            }
            .frame(width: s * 0.5, height: s * 0.66)
            .rotationEffect(.degrees(-7))
            .offset(x: -s * 0.2)

            // 三個吊牌
            VStack(alignment: .leading, spacing: s * 0.08) {
                TagShape().fill(color).frame(width: s * 0.36, height: s * 0.15)
                TagShape().fill(color.opacity(0.55)).frame(width: s * 0.3, height: s * 0.15)
                TagShape().stroke(color, lineWidth: s * 0.06).frame(width: s * 0.24, height: s * 0.15)
            }
            .frame(width: s * 0.38, alignment: .leading)
            .offset(x: s * 0.29)
        }
        .frame(width: s, height: s)
        .accessibilityHidden(true)
    }
}

/// 吊牌：左邊是尖角，右邊圓角
struct TagShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.height * 0.35, rect.width * 0.2)
        let point = rect.height * 0.5
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + point, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + point, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 照片裡的兩座山
struct MountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.45))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.25))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}


// MARK: - 說明重點

/// 取代一整段灰色小字的說明：每個重點一行（圖示＋短句），放在淡色底的小框裡。
/// collapsible 為 true 時預設收起，只顯示「怎麼運作？」，點開才看重點。
struct TipList: View {
    struct Point: Hashable {
        let icon: String
        let text: String
        init(_ icon: String, _ text: String) { self.icon = icon; self.text = text }
    }

    var title: String = "怎麼運作？"
    let points: [Point]
    var collapsible: Bool = true
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if collapsible {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 13, weight: .semibold))
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .foregroundColor(Theme.text.opacity(0.75))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(expanded ? "收起說明" : "展開說明")
            }
            if !collapsible || expanded {
                ForEach(points, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: point.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.highlight)
                            .frame(width: 18)
                        Text(point.text)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

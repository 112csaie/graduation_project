// PersonalizationSetupView.swift
//
// 兩階段個人化設定（全中文介面）：
//   第一階段「讓相簿更懂你的生活」——選擇興趣定位（可複選、可跳過）。
//   第二階段「你想優先整理哪些照片？」——選擇大分類（依興趣推薦排序、可查看完整清單、可跳過）。
// 同一個畫面也用在「設定 → 分類偏好」，會正確帶入已儲存的選擇。
//
// 版面：依實際可用寬度調整欄數、邊距與字級，適用 iPhone SE / mini（375pt）、一般機型（390–402pt）、
// Pro Max（430–440pt）、橫向與 iPad；底部按鈕避開 Home 指示條（safe area），並限制動態字級上限避免卡片破版。
//
// 注意：興趣定位是「偏好」，不是 GPS 地理位置，也不會決定照片的辨識結果。

import SwiftUI

struct PersonalizationSetupView: View {

    enum Mode {
        case onboarding   // 註冊 / 登入後的新手引導
        case settings     // 設定頁重新編輯
    }

    let mode: Mode
    let onFinish: () -> Void

    private let catalog = PersonalizationService.shared.catalog

    @State private var step = 1
    @State private var selectedInterests: Set<String> = []
    @State private var selectedTopLevel: Set<String> = []
    @State private var expandedTopLevel: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var lastSaveAction: SaveAction?
    @State private var hasLoadedSelection = false
    @State private var containerWidth: CGFloat = 390

    private enum SaveAction { case finish, skip }

    // MARK: - 版面參數（依寬度）

    private struct Metrics {
        let width: CGFloat

        var isCompact: Bool { width < 380 }          // iPhone SE / mini / 放大顯示模式
        var isWide: Bool { width >= 700 }            // iPad、大螢幕橫向
        var horizontalPadding: CGFloat { isWide ? 32 : (isCompact ? 16 : 20) }
        var gridSpacing: CGFloat { isCompact ? 10 : 12 }
        var interestColumns: Int { isWide ? 3 : 2 }
        var categoryColumns: Int { isWide ? 2 : 1 }
        var titleSize: CGFloat { isCompact ? 24 : (isWide ? 32 : 28) }
        var bodySize: CGFloat { isCompact ? 14 : 15 }
        var interestCardMinHeight: CGFloat { isCompact ? 118 : 128 }
        var contentMaxWidth: CGFloat { 760 }

        func columns(_ count: Int) -> [GridItem] {
            Array(repeating: GridItem(.flexible(), spacing: gridSpacing, alignment: .top), count: count)
        }
    }

    private var metrics: Metrics { Metrics(width: containerWidth) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                if isLoading {
                    Spacer()
                    ProgressView().tint(Theme.text)
                    Text("正在載入你/妳的設定…")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text.opacity(0.6))
                        .padding(.top, 8)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                Color.clear.frame(height: 0).id("top")
                                if step == 1 { interestStep } else { categoryStep }
                            }
                            .frame(maxWidth: metrics.contentMaxWidth)
                            .padding(.horizontal, metrics.horizontalPadding)
                            .padding(.bottom, 24)
                            .frame(maxWidth: .infinity)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .onChange(of: step) { _, _ in
                            withAnimation { proxy.scrollTo("top", anchor: .top) }
                        }
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
            containerWidth = width
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isLoading { footer }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)   // 限制動態字級上限，避免卡片破版
        .environment(\.locale, Locale(identifier: "zh-Hant"))
        .onAppear(perform: loadSaved)
        .alert("儲存失敗", isPresented: errorBinding) {
            Button("重試") { retryLastSave() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header / Footer

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                if mode == .settings {
                    Button("取消") { onFinish() }
                        .foregroundColor(Theme.text.opacity(0.8))
                        .disabled(isSaving)
                } else {
                    Text("個人化設定")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.5))
                }
                Spacer()
                Text("步驟 \(step) / 2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text.opacity(0.5))
                Spacer()
                if mode == .onboarding {
                    Button("稍後再設定") { save(action: .skip) }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text.opacity(0.75))
                        .disabled(isSaving || isLoading)
                        .accessibilityIdentifier("personalization.skipAll")
                } else {
                    // 讓標題置中的佔位
                    Text("取消").opacity(0).accessibilityHidden(true)
                }
            }

            HStack(spacing: 6) {
                ForEach(1...2, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Theme.accent : Theme.text.opacity(0.18))
                        .frame(height: 4)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: step)
        }
        .frame(maxWidth: metrics.contentMaxWidth)
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.text.opacity(0.1))
            HStack(spacing: 12) {
                if step == 2 {
                    Button(action: { withAnimation { step = 1 } }) {
                        Text("上一步")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Theme.text.opacity(0.12))
                            .cornerRadius(14)
                    }
                    .frame(maxWidth: metrics.isCompact ? 110 : 140)
                    .disabled(isSaving)
                }

                Button(action: primaryAction) {
                    ZStack {
                        if isSaving {
                            ProgressView().tint(Theme.onAccent)
                        } else {
                            Text(primaryTitle)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Theme.onAccent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.accent)
                    .cornerRadius(14)
                }
                .disabled(isSaving)
                .accessibilityIdentifier("personalization.primary")
            }
            .frame(maxWidth: metrics.contentMaxWidth)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.opacity(0.96))
    }

    private var primaryTitle: String {
        if step == 1 {
            return selectedInterests.isEmpty ? "跳過此步驟" : "下一步"
        }
        if mode == .settings { return "儲存" }
        return selectedTopLevel.isEmpty ? "先不選，完成" : "完成"
    }

    private func primaryAction() {
        if step == 1 {
            withAnimation { step = 2 }
        } else {
            save(action: .finish)
        }
    }

    // MARK: - 第一階段：興趣定位

    private var interestStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleBlock(
                title: "讓相簿更懂你/妳的生活",
                subtitle: "選擇你/妳平常感興趣的主題，我們會為你/妳推薦適合的照片分類。你/妳可以複選，也可以之後再設定。"
            )

            selectionCountBadge(count: selectedInterests.count)

            LazyVGrid(columns: metrics.columns(metrics.interestColumns), spacing: metrics.gridSpacing) {
                ForEach(catalog.interests) { interest in
                    InterestCard(
                        icon: interest.icon,
                        title: interest.nameZh,
                        subtitle: interest.summaryZh,
                        isSelected: selectedInterests.contains(interest.id),
                        minHeight: metrics.interestCardMinHeight,
                        isCompact: metrics.isCompact
                    ) {
                        toggle(interest.id, in: &selectedInterests)
                    }
                    .accessibilityIdentifier("interest.\(interest.id)")
                }
            }

            Text("興趣定位只用來推薦與排序分類，不代表你/妳的地理位置，也不會決定照片的辨識結果。")
                .font(.system(size: 12))
                .foregroundColor(Theme.text.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    // MARK: - 第二階段：大分類

    private var rankedTopLevel: [TopLevelRecommendation] {
        InterestRecommender.rankTopLevel(selectedInterestIds: selectedInterests, catalog: catalog)
    }

    private var categoryStep: some View {
        let ranked = rankedTopLevel
        let recommended = ranked.filter(\.isRecommended)
        let others = ranked.filter { !$0.isRecommended }
        let grid = metrics.columns(metrics.categoryColumns)

        return VStack(alignment: .leading, spacing: 16) {
            titleBlock(
                title: "你/妳想優先整理哪些照片？",
                subtitle: "我們會依照你/妳的興趣推薦相關分類，並自動啟用對應的小分類。其他類型的照片仍然可以正常辨識。"
            )

            HStack(spacing: 8) {
                selectionCountBadge(count: selectedTopLevel.count)
                if !selectedTopLevel.isEmpty {
                    Text(comparisonSummary)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text.opacity(0.5))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }

            if !recommended.isEmpty {
                HStack {
                    sectionLabel("根據你/妳的興趣推薦")
                    Spacer()
                    Button("全選推薦") {
                        recommended.forEach { selectedTopLevel.insert($0.node.id) }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text.opacity(0.85))
                }
                LazyVGrid(columns: grid, spacing: metrics.gridSpacing) {
                    ForEach(recommended) { categoryCard($0) }
                }
                sectionLabel("其他大分類")
            } else {
                sectionLabel("完整分類清單")
            }

            LazyVGrid(columns: grid, spacing: metrics.gridSpacing) {
                ForEach(others) { categoryCard($0) }
            }
        }
    }

    /// 例：「將自動啟用 32 個細分類」
    private var comparisonSummary: String {
        let count = selectedTopLevel.reduce(0) { total, id in
            total + catalog.descendants(of: id).filter { $0.level == 3 && $0.enabledByDefault }.count
        }
        return "將自動啟用 \(count) 個細分類"
    }

    private func categoryCard(_ recommendation: TopLevelRecommendation) -> some View {
        let node = recommendation.node
        let isExpanded = expandedTopLevel.contains(node.id)
        let isSelected = selectedTopLevel.contains(node.id)
        let reason = recommendation.recommendedBy
            .compactMap { catalog.interest($0)?.nameZh }
            .joined(separator: "、")
        let detailCount = catalog.descendants(of: node.id).filter { $0.level == 3 }.count

        return VStack(alignment: .leading, spacing: 0) {
            Button(action: { toggle(node.id, in: &selectedTopLevel) }) {
                HStack(alignment: .top, spacing: 12) {
                    iconBubble(node.icon, isSelected: isSelected, size: metrics.isCompact ? 36 : 40)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(node.nameZh)
                                .font(.system(size: metrics.isCompact ? 15 : 16, weight: .semibold))
                                .foregroundColor(Theme.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            if recommendation.isRecommended {
                                badge("推薦")
                            }
                        }
                        Text(node.summaryZh)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("例：\(node.examplesZh)")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.text.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                        if !reason.isEmpty {
                            Text("因為你/妳選了：\(reason)")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.text.opacity(0.4))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundColor(isSelected ? Theme.text : Theme.text.opacity(0.3))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("category.\(node.id)")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            Button(action: { toggle(node.id, in: &expandedTopLevel) }) {
                HStack(spacing: 6) {
                    Text(isExpanded ? "收起子分類" : "查看子分類")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    Spacer()
                    if detailCount > 0 {
                        Text("共 \(detailCount) 個細分類")
                            .foregroundColor(Theme.text.opacity(0.4))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.text.opacity(0.65))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(catalog.children(of: node.id)) { child in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(child.nameZh)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.text.opacity(0.9))
                            Text(catalog.children(of: child.id).map(\.nameZh).joined(separator: "・"))
                                .font(.system(size: 12))
                                .foregroundColor(Theme.text.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(isSelected ? "已選取：以上子分類會自動啟用。" : "未選取時，這些照片仍會被辨識、也能搜尋。")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.text.opacity(0.45))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(isSelected ? Theme.text.opacity(0.14) : Theme.surface(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Theme.text.opacity(0.85) : Theme.text.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .cornerRadius(16)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    // MARK: - 共用小元件

    private func titleBlock(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: metrics.titleSize, weight: .bold))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: metrics.bodySize))
                .foregroundColor(Theme.text.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func iconBubble(_ icon: String, isSelected: Bool, size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundColor(isSelected ? Theme.onAccent : Theme.text)
            .frame(width: size, height: size)
            .background(isSelected ? Theme.accent : Theme.text.opacity(0.1))
            .clipShape(Circle())
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Theme.onAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accent)
            .cornerRadius(6)
            .fixedSize()
    }

    private func selectionCountBadge(count: Int) -> some View {
        Text("已選擇 \(count) 項")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(count > 0 ? Theme.onAccent : Theme.text.opacity(0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(count > 0 ? Theme.accent : Theme.text.opacity(0.1))
            .cornerRadius(999)
            .fixedSize()
            .animation(.easeInOut(duration: 0.15), value: count)
            .accessibilityIdentifier("personalization.selectedCount")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.text.opacity(0.45))
    }

    private func toggle(_ id: String, in set: inout Set<String>) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    // MARK: - 載入 / 儲存

    private func loadSaved() {
        guard !hasLoadedSelection else { return }
        hasLoadedSelection = true
        isLoading = true
        Task {
            let saved = await Task.detached(priority: .userInitiated) { () -> SavedPersonalization? in
                try? PersonalizationService.shared.loadSavedPersonalization()
            }.value
            await MainActor.run {
                if let saved {
                    selectedInterests = saved.interestIds
                    selectedTopLevel = saved.topLevelIds
                }
                isLoading = false
            }
        }
    }

    private func retryLastSave() {
        if let lastSaveAction { save(action: lastSaveAction) }
    }

    private func save(action: SaveAction) {
        guard !isSaving else { return }   // 防止重複點擊
        isSaving = true
        lastSaveAction = action
        let interests = selectedInterests
        let topLevel = selectedTopLevel
        let currentMode = mode

        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                do {
                    switch action {
                    case .finish:
                        try PersonalizationService.shared.savePersonalization(
                            interestIds: interests, topLevelIds: topLevel, status: .completed)
                    case .skip:
                        if currentMode == .onboarding {
                            try PersonalizationService.shared.skipOnboarding()
                        }
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            await MainActor.run {
                isSaving = false
                switch result {
                case .success:
                    onFinish()
                case .failure(let error):
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 興趣卡片（直式，適合手機兩欄）

struct InterestCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    var minHeight: CGFloat = 128
    var isCompact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: isCompact ? 16 : 18, weight: .semibold))
                        .foregroundColor(isSelected ? Theme.onAccent : Theme.text)
                        .frame(width: isCompact ? 34 : 38, height: isCompact ? 34 : 38)
                        .background(isSelected ? Theme.accent : Theme.text.opacity(0.1))
                        .clipShape(Circle())
                    Spacer(minLength: 4)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? Theme.text : Theme.text.opacity(0.3))
                }
                Text(title)
                    .font(.system(size: isCompact ? 14 : 15, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text.opacity(0.6))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(isCompact ? 12 : 14)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(isSelected ? Theme.text.opacity(0.14) : Theme.surface(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Theme.text.opacity(0.85) : Theme.text.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            )
            .cornerRadius(16)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

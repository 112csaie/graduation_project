// PersonalCategoryViews.swift
//
// 個人化分類瀏覽（Dashboard 的「For You」模式）、跨分類搜尋、分類照片牆、待確認標籤審核。
// 所有資料都來自 PersonalizationService（SQLite），不是靜態展示。

import SwiftUI

// MARK: - 分類頁（嵌入 Dashboard 的「分類」模式）

/// 個人化分類（取代舊的 45 類 Classification）。版面精簡為：
/// 一排工具 chip（偏好設定／待確認 tag／目前的分類篩選）→ 你選的大分類 → 收合的「其他分類」。
/// 搜尋統一使用首頁上方的搜尋列：輸入文字時會同時建議分類，點選後成為這裡的篩選條件。
struct PersonalCategoryBrowserView: View {
    @ObservedObject var syncVM: PhotoSyncViewModel
    /// 跨分類篩選（由首頁搜尋列加入），照片需同時符合全部條件。
    @Binding var selectedFilterNodes: [String]

    private let catalog = PersonalizationService.shared.catalog

    @State private var data: PersonalBrowseData = .empty
    @State private var hasLoaded = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var loadInFlight = false
    @State private var reloadQueued = false
    @State private var containerWidth: CGFloat = 390
    @State private var showOtherSections = false
    @State private var progress: (done: Int, total: Int)?
    /// 分類文字向量準備進度（第一次使用或分類更新後才會出現）
    @State private var preparing: (done: Int, total: Int)?
    /// 這次啟動累計分類的張數（掃描進行中顯示，不會每一輪歸零）
    @State private var sessionTagged = 0

    @State private var filterResults: [String] = []
    @State private var isFiltering = false
    @State private var filterTask: Task<Void, Never>?

    @State private var selectedAsset: IdentifiableString?
    @State private var showPreferences = false

    private var isCompactWidth: Bool { containerWidth < 380 }
    private var horizontalPadding: CGFloat { isCompactWidth ? 16 : 20 }
    private var photoColumns: [GridItem] {
        [GridItem(.adaptive(minimum: isCompactWidth ? 90 : 100), spacing: 2)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbarRow
            if isScanning || preparing != nil || (progress.map { $0.done < $0.total } ?? false) {
                progressRow
            }

            if !selectedFilterNodes.isEmpty {
                filterResultsSection
            } else if isLoading && !hasLoaded {
                HStack { Spacer(); ProgressView().tint(Theme.text); Spacer() }
                    .padding(.top, 30)
            } else if let loadError {
                errorState(loadError)
            } else if data.categorizedPhotoCount == 0 {
                emptyState
            } else {
                ForEach(data.enabledSections.filter { !$0.items.isEmpty }) { sectionCard($0) }

                if data.hasSelectedCategories {
                    if !data.otherSections.isEmpty {
                        otherSectionsToggle
                        if showOtherSections {
                            ForEach(data.otherSections) { sectionCard($0) }
                        }
                    }
                } else {
                    ForEach(data.otherSections) { sectionCard($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
            containerWidth = width
        }
        .onAppear {
            reload()
            refreshFilterResults()
            PersonalizationService.shared.scheduleTagging()
        }
        .onChange(of: selectedFilterNodes) { _, _ in refreshFilterResults() }
        .onReceive(NotificationCenter.default.publisher(for: .personalizationUpdated)) { _ in
            reload()
            refreshFilterResults()
        }
        .onReceive(NotificationCenter.default.publisher(for: .personalizationTaggingProgress)) { note in
            if let done = note.userInfo?["preparing"] as? Int, let total = note.userInfo?["preparingTotal"] as? Int {
                preparing = done < total ? (done, total) : nil
            }
            if let session = note.userInfo?["sessionDone"] as? Int { sessionTagged = session }
            if let done = note.userInfo?["done"] as? Int, let total = note.userInfo?["total"] as? Int {
                progress = (done, total)
                if done >= total { reload() }
            }
        }
        .onChange(of: syncVM.isSyncing) { _, isSyncing in
            if !isSyncing { reload() }
        }
        .sheet(item: $selectedAsset) { item in
            PhotoDetailModal(assetId: item.id)
        }
        .sheet(isPresented: $showPreferences) {
            PersonalizationSetupView(mode: .settings) { showPreferences = false }
        }
    }

    // MARK: 工具列

    private var toolbarRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(action: { showPreferences = true }) {
                    TagChip(text: "偏好設定", systemImage: "slider.horizontal.3", style: .neutral)
                }
                .buttonStyle(.plain)

                if data.candidateCount > 0 {
                    NavigationLink(destination: CandidateTagReviewView()) {
                        TagChip(text: "待確認 tag \(data.candidateCount)", systemImage: "questionmark.circle", style: .candidate)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(selectedFilterNodes, id: \.self) { nodeId in
                    Button(action: { selectedFilterNodes.removeAll { $0 == nodeId } }) {
                        TagChip(text: catalog.node(nodeId)?.nameZh ?? nodeId, systemImage: "xmark", style: .selected)
                    }
                    .buttonStyle(.plain)
                }
                if selectedFilterNodes.count > 1 {
                    Button("清除") { selectedFilterNodes.removeAll() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.6))
                }
            }
            .padding(.horizontal, horizontalPadding)
        }
    }

    private var isScanning: Bool {
        syncVM.isSyncing && syncVM.totalCount > 0 && syncVM.syncedCount < syncVM.totalCount
    }

    /// 掃描與分類共用一條進度：掃描中顯示「掃描 x / y · 已分類 n 張」，只剩分類時顯示分類進度。
    private var progressRow: some View {
        let tagging = progress ?? (done: 0, total: 0)
        let scanning = isScanning
        let label: String
        let value: Double
        let total: Double
        if let preparing {
            label = (scanning ? "掃描 \(syncVM.syncedCount) / \(syncVM.totalCount) · " : "")
                + "正在準備分類（\(preparing.done) / \(preparing.total)）"
            value = scanning ? Double(syncVM.syncedCount) : Double(preparing.done)
            total = Double(max(scanning ? syncVM.totalCount : preparing.total, 1))
        } else if scanning {
            label = "掃描 \(syncVM.syncedCount) / \(syncVM.totalCount) · 已分類 \(sessionTagged) 張"
            value = Double(syncVM.syncedCount)
            total = Double(max(syncVM.totalCount, 1))
        } else if tagging.done < tagging.total {
            label = "正在分類 \(tagging.done) / \(tagging.total)"
            value = Double(tagging.done)
            total = Double(max(tagging.total, 1))
        } else {
            label = "整理中…"
            value = 0
            total = 1
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.text.opacity(0.6))
            ProgressView(value: min(value, total), total: total)
                .tint(Theme.text)
        }
        .padding(.horizontal, horizontalPadding)
    }

    private var otherSectionsToggle: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showOtherSections.toggle() } }) {
            HStack {
                Text("其他分類")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(data.otherSections.count)")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text.opacity(0.5))
                Spacer()
                Image(systemName: showOtherSections ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(Theme.text)
            .padding(14)
            .themeCard(radius: 22)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, horizontalPadding)
    }

    private var filterResultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedFilterNodes.count > 1
                 ? "同時符合 \(selectedFilterNodes.count) 個分類的照片"
                 : "\(catalog.node(selectedFilterNodes.first ?? "")?.nameZh ?? "") 的照片")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text.opacity(0.6))
                .padding(.horizontal, horizontalPadding)

            if isFiltering {
                HStack { Spacer(); ProgressView().tint(Theme.text); Spacer() }.padding(.top, 20)
            } else if filterResults.isEmpty {
                Text("目前沒有符合的照片。")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            } else {
                LazyVGrid(columns: photoColumns, spacing: 2) {
                    ForEach(filterResults, id: \.self) { assetId in
                        Button(action: { selectedAsset = IdentifiableString(id: assetId) }) {
                            // 縮圖不撐出格子，可點範圍就是這一格
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(PhotoThumbnailView(assetId: assetId))
                                .clipped()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    /// 一個大分類一張卡：標題＋總張數，前三個小分類拼成「一大兩小」，其他小分類在下面橫向滑。
    private func sectionCard(_ section: PersonalCategorySection) -> some View {
        let featured = Array(section.items.prefix(3))
        let rest = Array(section.items.dropFirst(3))
        return VStack(alignment: .leading, spacing: 12) {
            NavigationLink(destination: PersonalGroupAlbumListView(section: section, syncVM: syncVM)) {
                HStack(alignment: .center, spacing: 8) {
                    Text(section.node.nameZh)
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    AccentPill(text: "\(section.photoCount)")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            collage(featured)

            if !rest.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(rest) { item in
                            itemLink(item).frame(width: 118, height: 118)
                        }
                    }
                }
            }
        }
        .padding(12)
        .themeCard(radius: 24)
        .padding(.horizontal, horizontalPadding)
    }

    /// 1 個：一張大圖；2 個：左右各一；3 個：左邊一大、右邊上下兩小
    @ViewBuilder
    private func collage(_ items: [PersonalCategoryItem]) -> some View {
        switch items.count {
        case 0:
            EmptyView()
        case 1:
            itemLink(items[0]).frame(height: 170)
        case 2:
            HStack(spacing: 8) {
                itemLink(items[0])
                itemLink(items[1])
            }
            .frame(height: 150)
        default:
            HStack(spacing: 8) {
                itemLink(items[0])
                VStack(spacing: 8) {
                    itemLink(items[1])
                    itemLink(items[2])
                }
            }
            .frame(height: 230)
        }
    }

    private func itemLink(_ item: PersonalCategoryItem) -> some View {
        NavigationLink(destination: CategoryDetailView(personalNodeId: item.node.id,
                                                       title: item.node.nameZh,
                                                       syncVM: syncVM)) {
            CollageTile(title: item.node.nameZh, count: item.photoCount, assetId: item.coverAssetId)
                .id(item.coverAssetId ?? item.id)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 34))
                .foregroundColor(Theme.text.opacity(0.35))
            Text(syncVM.isSyncing
                 ? ("正在分析你/妳的照片…")
                 : ("還沒有已分類的照片"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text.opacity(0.7))
            Text("請先同步相簿。分類會直接使用既有的照片特徵向量，不需要重新計算。")
                .font(.system(size: 12))
                .foregroundColor(Theme.text.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 30)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Theme.text.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("重試") { reload() }
                .foregroundColor(Theme.text)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.text.opacity(0.15))
                .cornerRadius(10)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    // MARK: 動作

    /// 重新載入分類資料。
    ///
    /// 掃描期間每分類完一批就會通知一次。以前每次通知都會取消上一次還沒載完的載入；
    /// 掃描時資料庫一直在寫入、讀取變慢，結果永遠載不完，要等全部掃完才看得到分類相簿。
    /// 現在進行中的載入一定會完成並顯示，期間收到的通知合併成「載完後再載一次」。
    private func reload() {
        if loadInFlight {
            reloadQueued = true
            return
        }
        loadInFlight = true
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<PersonalBrowseData, Error> in
                do { return .success(try PersonalizationService.shared.loadBrowseData()) } catch { return .failure(error) }
            }.value
            await MainActor.run {
                switch result {
                case .success(let loaded):
                    data = loaded
                    loadError = nil
                case .failure(let error):
                    loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                hasLoaded = true
                isLoading = false
                loadInFlight = false
                if reloadQueued {
                    reloadQueued = false
                    // 同步期間通知很頻繁：至少間隔 1 秒再載下一次，讓畫面穩定更新
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { reload() }
                }
            }
        }
    }

    private func refreshFilterResults() {
        filterTask?.cancel()
        let nodes = selectedFilterNodes
        guard !nodes.isEmpty else { filterResults = []; return }
        isFiltering = true
        filterTask = Task {
            let ids = await Task.detached(priority: .userInitiated) { () -> [String] in
                (try? PersonalizationService.shared.assetIds(matchingAll: nodes)) ?? []
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                filterResults = ids
                isFiltering = false
            }
        }
    }
}

// MARK: - 「View all」：與原本 GroupAlbumListView 相同的版面

struct PersonalGroupAlbumListView: View {
    let section: PersonalCategorySection
    @ObservedObject var syncVM: PhotoSyncViewModel

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(section.node.nameZh)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(Theme.text)
                        .padding(.top, 12)

                    Text("\(section.items.count) 個相簿")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text.opacity(0.6))

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(section.items) { item in
                            NavigationLink(
                                destination: CategoryDetailView(personalNodeId: item.node.id,
                                                                title: item.node.nameZh,
                                                                syncVM: syncVM)
                            ) {
                                CategoryAlbumCard(album: item.albumSummary(english: false))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }
}

extension PersonalCategoryItem {
    /// 轉成原本 Classification 相簿卡片使用的資料。
    func albumSummary(english: Bool) -> CategoryAlbumSummary {
        CategoryAlbumSummary(id: node.id, title: node.displayName(english: english),
                             coverAssetId: coverAssetId, photoCount: photoCount)
    }
}

// MARK: - 待確認標籤

struct CandidateTagReviewView: View {
    private let catalog = PersonalizationService.shared.catalog
    /// 只顯示「我的 IP」的待確認（從 IP 頁進來）
    var onlyCustom = false

    @State private var candidates: [CandidateTag] = []
    @State private var isLoading = true
    @State private var busyIds: Set<String> = []
    @State private var errorMessage: String?
    @State private var selectedAsset: IdentifiableString?

    /// 依分類分組：同一個問題（例如「演唱會」）可以一次回答。
    private var groups: [(nodeId: String, items: [CandidateTag])] {
        Dictionary(grouping: candidates, by: \.nodeId)
            .map { (nodeId: $0.key, items: $0.value) }
            .sorted { $0.items.count > $1.items.count }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if isLoading {
                ProgressView().tint(Theme.text)
            } else if candidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.system(size: 30)).foregroundColor(Theme.text.opacity(0.4))
                    Text("沒有需要確認的 tag").foregroundColor(Theme.secondaryText)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        TipList(title: "為什麼要確認？", points: [
                            .init("questionmark.square", "看得出相關畫面，但無法確定情境的照片"),
                            .init("arrow.triangle.2.circlepath", "你/妳的回答會成為範例，很像的照片之後會自動分對"),
                            .init("hand.raised", "不回答也沒關係"),
                        ])
                        ForEach(groups, id: \.nodeId) { group in
                            groupCard(group.nodeId, group.items)
                        }
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                }
            }
        }
        .navigationTitle("待確認 tag")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .sheet(item: $selectedAsset) { item in
            PhotoDetailModal(assetId: item.id)
        }
        .alert("操作失敗", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func groupCard(_ nodeId: String, _ items: [CandidateTag]) -> some View {
        let name = PersonalizationService.shared.displayName(for: nodeId)
        return CandidateAnswerCard(
            title: "這些照片是「\(name)」嗎？",
            items: items,
            isBusy: items.contains { busyIds.contains($0.id) },
            onView: { selectedAsset = IdentifiableString(id: $0) },
            onSubmit: { yes, no in
                decide(yes, accept: true)
                decide(no, accept: false)
            }
        )
    }

    private func load() {
        let only = onlyCustom
        Task {
            let list = await Task.detached(priority: .userInitiated) { () -> [CandidateTag] in
                (try? PersonalizationService.shared.candidateTags(onlyCustom: only)) ?? []
            }.value
            await MainActor.run {
                candidates = list
                isLoading = false
            }
        }
    }

    private func decide(_ items: [CandidateTag], accept: Bool) {
        let pending = items.filter { !busyIds.contains($0.id) }
        guard !pending.isEmpty else { return }
        pending.forEach { busyIds.insert($0.id) }
        Task {
            let failures = await Task.detached(priority: .userInitiated) { () -> [String: Error] in
                var failures: [String: Error] = [:]
                for candidate in pending {
                    do {
                        if accept {
                            try PersonalizationService.shared.confirmTag(assetId: candidate.assetId, nodeId: candidate.nodeId)
                        } else {
                            try PersonalizationService.shared.rejectTag(assetId: candidate.assetId, nodeId: candidate.nodeId)
                        }
                    } catch {
                        failures[candidate.id] = error
                    }
                }
                return failures
            }.value
            await MainActor.run {
                pending.forEach { busyIds.remove($0.id) }
                candidates.removeAll { candidate in pending.contains { $0.id == candidate.id } && failures[candidate.id] == nil }
                if let error = failures.values.first {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 待確認的一題（共用：主題頁待確認、IP 相簿）

/// 照片以格狀全部攤開（不用左右滑）。預設每張都是「是」，點一下標記成「不是」（變暗、紅色 ✕），
/// 再按「完成」一次送出整題。照片很多時先顯示 12 張，只送出顯示中的照片，其餘留到下次。長按可看大圖。
struct CandidateAnswerCard: View {
    let title: String
    let items: [CandidateTag]
    let isBusy: Bool
    let onView: (String) -> Void
    let onSubmit: (_ yes: [CandidateTag], _ no: [CandidateTag]) -> Void

    @State private var rejected: Set<String> = []
    @State private var expanded = false

    private let previewLimit = 12
    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 4)]

    private var shown: [CandidateTag] { expanded ? items : Array(items.prefix(previewLimit)) }

    var body: some View {
        let visible = shown
        let noItems = visible.filter { rejected.contains($0.id) }
        let yesItems = visible.filter { !rejected.contains($0.id) }
        let hiddenCount = items.count - visible.count

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("\(items.count) 張")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text.opacity(0.5))
            }

            // 一次全部改成「不是」，再把真的是的點回來（照片大多不是時比較快）；再按一次全部改回「是」
            let allNo = !visible.isEmpty && visible.allSatisfy { rejected.contains($0.id) }
            Button(action: {
                if allNo {
                    rejected.subtract(visible.map(\.id))
                } else {
                    rejected.formUnion(visible.map(\.id))
                }
            }) {
                Label(allNo ? "全部改回「是」" : "全部取消（標成「不是」）",
                      systemImage: allNo ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.text.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(visible) { candidate in
                    let isNo = rejected.contains(candidate.id)
                    // 點一下：切換是／不是；長按：直接打開大圖（不再跳出「查看照片」選單）
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(PhotoThumbnailView(assetId: candidate.assetId))
                        .clipped()
                        .overlay(Color.black.opacity(isNo ? 0.6 : 0))
                        .cornerRadius(6)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: isNo ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white, isNo ? Color.red : Theme.highlight)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                                .padding(4)
                        }
                        // 縮圖不撐出格子，可點的範圍就是這一格
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isNo { rejected.remove(candidate.id) } else { rejected.insert(candidate.id) }
                        }
                        .onLongPressGesture(minimumDuration: 0.35) {
                            onView(candidate.assetId)
                        }
                        .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(isNo ? "不是，點一下改成是" : "是，點一下改成不是")
                }
            }

            if hiddenCount > 0 {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded = true } }) {
                    Text("再顯示 \(hiddenCount) 張")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.8))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }

            if isBusy {
                HStack { Spacer(); ProgressView().tint(Theme.text); Spacer() }
            } else {
                HStack(spacing: 10) {
                    Button(action: { onSubmit(yesItems, noItems) }) {
                        Text(noItems.isEmpty ? "全部是（\(visible.count)）" : "完成（是 \(yesItems.count)・不是 \(noItems.count)）")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.onAccent)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(Theme.accent).cornerRadius(10)
                    }
                    Button(action: { onSubmit([], visible) }) {
                        Text("都不是")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .frame(width: 88, height: 40)
                            .background(Theme.text.opacity(0.12)).cornerRadius(10)
                    }
                }
                .buttonStyle(.plain)
                Text(hiddenCount > 0
                     ? "預設都是「是」，點一下標記「不是」（或先按「全部取消」再點選是的），再按完成。只會送出顯示中的照片，其餘留到下次。長按直接看大圖。"
                     : "預設都是「是」，點一下標記「不是」（或先按「全部取消」再點選是的），再按完成。長按直接看大圖。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.text.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .themeCard(radius: 22)
        .onChange(of: items.map(\.id)) { _, ids in
            rejected = rejected.intersection(Set(ids))
        }
    }
}

// MARK: - 標籤 Chip

struct TagChip: View {
    enum Style { case neutral, selected, accepted, candidate }

    let text: String
    var systemImage: String? = nil
    var style: Style = .neutral

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundColor(style == .selected ? Theme.onAccent : Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 999)
                .stroke(style == .candidate ? Theme.highlight : (style == .neutral ? Theme.border : Color.clear),
                        style: StrokeStyle(lineWidth: style == .candidate ? 1 : 0.5, dash: style == .candidate ? [3] : []))
        )
        .cornerRadius(999)
    }

    private var background: Color {
        switch style {
        case .neutral: return Theme.card
        case .selected: return Theme.accent
        case .accepted: return Theme.tile
        case .candidate: return Theme.card
        }
    }
}


// MARK: - 協助訓練分類（標記模式）

/// 設定 › 協助訓練分類：選一個分類，App 列出最需要人判斷的照片，點一下標「是」或「不是」。
/// 標記會直接成為這張照片的手動分類（平常回答「待確認」也一樣），並讓 App 越用越準。
/// 「匯出標記資料」只匯出照片向量（一串數字）和答案，不含照片，傳給組員合併後在 Mac 上訓練判斷器。
struct TagLabelingView: View {
    @AppStorage("labelingContributor") private var contributor = ""
    @State private var counts: [String: (positive: Int, negative: Int)] = [:]
    @State private var exportFile: LabelingExportFile?
    @State private var message: String?
    @State private var isExporting = false

    /// 每個分類的目標張數（是、不是各幾張）
    static let target = 50

    private var groups: [(title: String, nodes: [TaxonomyNode])] {
        let service = PersonalizationService.shared
        let catalog = TaxonomyCatalog.builtIn
        var order: [String] = []
        var byTop: [String: [TaxonomyNode]] = [:]
        for node in service.labelableNodes {
            let top = catalog.topLevelId(of: node.id) ?? ""
            if byTop[top] == nil { order.append(top) }
            byTop[top, default: []].append(node)
        }
        return order.map { (service.displayName(for: $0), byTop[$0] ?? []) }
    }

    var body: some View {
        List {
            Section {
                Text("選一個分類，點照片標「是」或「不是」。標過的照片會直接放進（或移出）那個分類。匯出的檔案只有照片的特徵數字和答案，不含照片，傳給組員一起訓練。")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryText)
                TextField("你/妳的名字（匯出檔會用）", text: $contributor)
            }
            Section {
                Button {
                    export()
                } label: {
                    HStack {
                        Label("匯出標記資料", systemImage: "square.and.arrow.up")
                        Spacer()
                        if isExporting { ProgressView() }
                    }
                }
                .disabled(isExporting)
                if let message {
                    Text(message).font(.system(size: 12)).foregroundColor(Theme.secondaryText)
                }
            } footer: {
                Text("每個分類「是」和「不是」各 \(Self.target) 張以上，訓練出來的判斷器比較準。")
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.nodes, id: \.id) { node in
                        NavigationLink {
                            TagLabelingGridView(nodeId: node.id,
                                                title: PersonalizationService.shared.displayName(for: node.id),
                                                onSaved: reloadCounts)
                        } label: {
                            row(node)
                        }
                    }
                }
            }
        }
        .navigationTitle("協助訓練分類")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadCounts)
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
    }

    private func row(_ node: TaxonomyNode) -> some View {
        let count = counts[node.id] ?? (0, 0)
        let done = count.positive >= Self.target && count.negative >= Self.target
        return HStack {
            Text(PersonalizationService.shared.displayName(for: node.id))
                .foregroundColor(Theme.text)
            Spacer()
            Text("是 \(count.positive)・不是 \(count.negative)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(done ? Theme.highlight : Theme.secondaryText)
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.highlight)
            }
        }
    }

    private func reloadCounts() {
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                PersonalizationService.shared.trainingLabelCounts()
            }.value
            await MainActor.run { counts = loaded }
        }
    }

    private func export() {
        isExporting = true
        message = nil
        let name = contributor
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result { try PersonalizationService.shared.exportTrainingLabels(contributor: name) }
            }.value
            await MainActor.run {
                isExporting = false
                switch result {
                case .success(let url): exportFile = LabelingExportFile(url: url)
                case .failure(let error): message = "沒有匯出：\(error.localizedDescription)"
                }
            }
        }
    }
}

private struct LabelingExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// 一個分類的標記頁：一次 30 張，點一下「是」→ 再點「不是」→ 再點取消；長按看大圖。
struct TagLabelingGridView: View {
    let nodeId: String
    let title: String
    var onSaved: () -> Void = {}

    @State private var ids: [String] = []
    /// true = 是、false = 不是；沒有 = 還沒標
    @State private var answers: [String: Bool] = [:]
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var viewing: IdentifiableString?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("這些是「\(title)」嗎？點一下標「是」，再點一下改「不是」，再點一下取消。長按看大圖。只會儲存標過的照片。")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if ids.isEmpty {
                    Text("沒有需要標記的照片了。")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(ids, id: \.self) { id in cell(id) }
                    }
                    HStack(spacing: 10) {
                        actionButton("沒標的都算不是") {
                            for id in ids where answers[id] == nil { answers[id] = false }
                        }
                        actionButton(isSaving ? "儲存中…" : "儲存，下一批", primary: true) { save() }
                            .disabled(isSaving)
                    }
                    .padding(.top, 4)
                    Text("是 \(answers.values.filter { $0 }.count)・不是 \(answers.values.filter { !$0 }.count)・還沒標 \(ids.count - answers.count)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if ids.isEmpty { load() } }
        .sheet(item: $viewing) { item in PhotoDetailModal(assetId: item.id) }
    }

    private func cell(_ id: String) -> some View {
        let answer = answers[id]
        let color: Color = answer == true ? .green : (answer == false ? .red : .clear)
        return PhotoThumbnailView(assetId: id, pixelSize: 300)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 112)
            .clipped()
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 4))
            .overlay(alignment: .topTrailing) {
                if let answer {
                    Image(systemName: answer ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, answer ? Color.green : Color.red)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                switch answers[id] {
                case nil: answers[id] = true
                case true?: answers[id] = false
                case false?: answers[id] = nil
                }
            }
            .onLongPressGesture { viewing = IdentifiableString(id: id) }
            .accessibilityLabel(answer == true ? "是" : (answer == false ? "不是" : "還沒標"))
    }

    private func actionButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(primary ? Theme.onAccent : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(primary ? Theme.accent : Theme.text.opacity(0.12))
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private func load() {
        isLoading = true
        let node = nodeId
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                PersonalizationService.shared.labelingCandidates(nodeId: node, limit: 30)
            }.value
            await MainActor.run {
                ids = loaded
                answers = [:]
                isLoading = false
            }
        }
    }

    private func save() {
        let marked = answers
        let node = nodeId
        guard !marked.isEmpty else { load(); return }
        isSaving = true
        Task {
            await Task.detached(priority: .userInitiated) {
                for (assetId, isYes) in marked {
                    if isYes {
                        try? PersonalizationService.shared.confirmTag(assetId: assetId, nodeId: node)
                    } else {
                        try? PersonalizationService.shared.rejectTag(assetId: assetId, nodeId: node)
                    }
                }
            }.value
            await MainActor.run {
                isSaving = false
                onSaved()
                load()
            }
        }
    }
}

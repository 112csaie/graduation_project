// IPCategoryViews.swift
//
// 「專屬相簿」（程式內部代號仍為 ip）：使用者挑幾張範例照片，App 用照片向量找出同一個對象的其他照片。
// 對象可以是任何反覆出現的主角：寵物、收藏品、角色、作品……，相關的可以放進同一個分組。
//   - SpecialAlbumExample：依使用者興趣顯示的通用範例文字
//   - IPBrowserView：首頁「專屬」分頁（每個分組一區：全部 + 組內相簿 + 加入這組）
//   - IPCreateSheet：輸入對象（必填）與分組（選填）、挑範例照片（可從照片詳情帶入）
//
// 照片安全：只讀取照片（PhotosPicker 只取得識別碼），建立／改名／刪除 IP 都只動 App 自己的分類資料。

import SwiftUI
import PhotosUI

// MARK: - 依興趣顯示的範例（通用詞，不指定特定物種、作品或品牌）

struct SpecialAlbumExample {
    /// 空白頁的第一句，例如「幫你的寵物建立專屬相簿」
    let headline: String
    /// 「要認出的對象」欄位的提示
    let objectPlaceholder: String
    /// 「放進分組」欄位的提示
    let groupPlaceholder: String

    static let fallback = SpecialAlbumExample(
        headline: "幫常出現的主角建立專屬相簿",
        objectPlaceholder: "例如：名字或稱呼",
        groupPlaceholder: "例如：分組名稱")

    /// 興趣 ID → 範例。依第一階段個人化設定選的興趣決定。
    static let byInterest: [String: SpecialAlbumExample] = [
        "pets_animals": .init(headline: "幫你/妳的寵物建立專屬相簿", objectPlaceholder: "例如：寵物的名字", groupPlaceholder: "例如：我家的寵物"),
        "anime_games": .init(headline: "收集喜歡的角色", objectPlaceholder: "例如：角色名稱", groupPlaceholder: "例如：作品名稱"),
        "cafe_hopping": .init(headline: "整理常去的店", objectPlaceholder: "例如：店名", groupPlaceholder: "例如：口袋名單"),
        "food_cafe": .init(headline: "整理喜歡的店或料理", objectPlaceholder: "例如：店名或料理名稱", groupPlaceholder: "例如：口袋名單"),
        "travel_photo": .init(headline: "整理反覆造訪的地方", objectPlaceholder: "例如：地點名稱", groupPlaceholder: "例如：城市或地區"),
        "fashion_lifestyle": .init(headline: "整理你/妳的穿搭單品", objectPlaceholder: "例如：單品名稱", groupPlaceholder: "例如：單品類型"),
        "music_live": .init(headline: "收集喜歡的歌手、偶像或樂團", objectPlaceholder: "例如：歌手名稱", groupPlaceholder: "例如：樂團名稱"),
        "outdoor_hiking": .init(headline: "整理去過的山與步道", objectPlaceholder: "例如：山或步道名稱", groupPlaceholder: "例如：百岳"),
        "film_arts": .init(headline: "整理看過的電影與展覽", objectPlaceholder: "例如：電影或展覽名稱", groupPlaceholder: "例如：年份或系列"),
        "sports_outdoor": .init(headline: "整理你/妳的運動裝備", objectPlaceholder: "例如：裝備名稱", groupPlaceholder: "例如：運動項目"),
        "crafts_collecting": .init(headline: "整理你/妳的收藏品、娃娃或作品", objectPlaceholder: "例如：收藏品或娃娃的名字", groupPlaceholder: "例如：系列名稱"),
        "family_life": .init(headline: "整理家裡常拍的東西", objectPlaceholder: "例如：名稱或稱呼", groupPlaceholder: "例如：家裡的回憶"),
        "study_work": .init(headline: "整理某門課或專案的資料", objectPlaceholder: "例如：課程或專案名稱", groupPlaceholder: "例如：學期"),
    ]

    /// 目前使用者的範例：取個人化設定中排序最前面、且有範例的興趣；沒有就用通用範例。
    static func forCurrentUser() -> SpecialAlbumExample {
        let service = PersonalizationService.shared
        guard let selected = try? service.loadSavedPersonalization().interestIds, !selected.isEmpty else { return fallback }
        for interest in service.catalog.interests where selected.contains(interest.id) {
            if let example = byInterest[interest.id] { return example }
        }
        return fallback
    }
}

/// 首頁「專屬」分頁：每個分組一張卡片區塊，裡面是「全部」與組內各專屬相簿。
struct IPBrowserView: View {
    @ObservedObject var syncVM: PhotoSyncViewModel

    @State private var data: IPBrowseData = .empty
    @State private var hasLoaded = false
    @State private var loadInFlight = false
    @State private var reloadQueued = false
    /// 開啟「新增 IP」的請求。用 sheet(item:) 把「要帶入哪個作品」和開啟動作綁在一起：
    /// 以前用 sheet(isPresented:)，畫面打開時讀到的是舊的作品值，作品欄因此是空的。
    @State private var createRequest: CreateRequest?
    @State private var example = SpecialAlbumExample.fallback

    private struct CreateRequest: Identifiable {
        let id = UUID()
        let parent: CustomCategory?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button(action: { openCreate(parent: nil) }) {
                        TagChip(text: "建立專屬相簿", systemImage: "plus", style: .neutral)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
            }

            if !hasLoaded {
                HStack { Spacer(); ProgressView().tint(Theme.text); Spacer() }.padding(.top, 30)
            } else if data.groups.isEmpty {
                emptyState
            } else {
                ForEach(data.groups) { group in groupCard(group) }
            }
        }
        .onAppear {
            example = SpecialAlbumExample.forCurrentUser()
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .personalizationUpdated)) { _ in reload() }
        .sheet(item: $createRequest) { request in
            IPCreateSheet(initialParentId: request.parent?.id, initialParentName: request.parent?.name)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(example.headline)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("輸入名稱、挑幾張照片，App 就會從圖庫找出同一個對象的其他照片，自動整理成一本專屬相簿。相關的可以放進同一個分組，分組相簿會包含組內所有照片。")
                .font(.system(size: 13))
                .foregroundColor(Theme.text.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { openCreate(parent: nil) }) {
                Text("建立第一本專屬相簿")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Theme.accent)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .themeCard(radius: 22)
        .padding(.horizontal, 20)
    }

    private func groupCard(_ group: IPGroup) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            NavigationLink(destination: detail(group.work)) {
                HStack {
                    Text(group.work.category.name)
                        .font(.system(size: 21, weight: .heavy))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    if group.work.candidateCount > 0 {
                        // 待確認在相簿裡回答
                        TagChip(text: "待確認 \(group.work.candidateCount)", systemImage: "questionmark.circle", style: .candidate)
                    }
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
                LazyHStack(spacing: 15) {
                    // 有角色的作品：第一張是「全部」；單獨的角色（沒有作品）：直接顯示它自己的相簿
                    NavigationLink(destination: detail(group.work)) {
                        CategoryAlbumCard(album: CategoryAlbumSummary(id: group.work.id,
                                                                      title: group.characters.isEmpty ? group.work.category.name : "全部",
                                                                      coverAssetId: group.work.coverAssetId,
                                                                      photoCount: group.work.photoCount))
                            .id(group.work.coverAssetId ?? group.work.id)
                    }
                    .buttonStyle(.plain)
                    ForEach(group.characters) { character in
                        NavigationLink(destination: detail(character)) {
                            CategoryAlbumCard(album: character.albumSummary)
                                .id(character.coverAssetId ?? character.id)
                        }
                        .buttonStyle(.plain)
                    }
                    if !group.characters.isEmpty {
                    Button(action: { openCreate(parent: group.work.category) }) {
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Theme.text.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                                .frame(width: 160, height: 160)
                                .overlay(Image(systemName: "plus").font(.system(size: 28, weight: .semibold)).foregroundColor(Theme.text.opacity(0.7)))
                            Text("加入這組")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.text)
                            Text("加到「\(group.work.category.name)」")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.text.opacity(0.55))
                                .lineLimit(1)
                        }
                        .frame(width: 160, alignment: .leading)
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

    private func detail(_ item: CustomCategorySummary) -> some View {
        CategoryDetailView(personalNodeId: item.category.nodeId, title: item.category.name, syncVM: syncVM)
    }

    private func openCreate(parent: CustomCategory?) {
        createRequest = CreateRequest(parent: parent)
    }

    /// 進行中的載入不取消；期間的更新合併成「載完後再載一次」。
    private func reload() {
        if loadInFlight { reloadQueued = true; return }
        loadInFlight = true
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> IPBrowseData in
                (try? PersonalizationService.shared.loadIPBrowseData()) ?? .empty
            }.value
            await MainActor.run {
                data = loaded
                hasLoaded = true
                loadInFlight = false
                if reloadQueued {
                    reloadQueued = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { reload() }
                }
            }
        }
    }
}

// MARK: - 我的相簿裡的專屬分組

/// 開啟「建立專屬相簿」的請求（sheet(item:) 用；可以帶入要加到哪個分組）
struct IPCreateRequest: Identifiable {
    let id = UUID()
    var parentId: String? = nil
    var parentName: String? = nil
}

/// 「我的相簿」點開有分組的專屬相簿：「全部」＋組內每一本＋「加入這組」，兩欄方格
struct IPGroupAlbumsView: View {
    let group: IPGroup
    @ObservedObject var syncVM: PhotoSyncViewModel
    var onAdd: (IPCreateRequest) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                NavigationLink(destination: detail(group.work, title: group.work.category.name)) {
                    CollageTile(title: "全部", count: group.work.photoCount, assetId: group.work.coverAssetId, badge: "tag.fill")
                        .aspectRatio(1, contentMode: .fit)
                }
                .buttonStyle(.plain)
                ForEach(group.characters) { character in
                    NavigationLink(destination: detail(character, title: character.category.name)) {
                        CollageTile(title: character.category.name, count: character.photoCount, assetId: character.coverAssetId)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: { onAdd(IPCreateRequest(parentId: group.work.category.id, parentName: group.work.category.name)) }) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.secondaryText.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(Theme.onAccent)
                                    .frame(width: 40, height: 40)
                                    .background(Theme.accent)
                                    .clipShape(Circle())
                                Text("加入這組")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.secondaryText)
                            }
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(group.work.category.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ item: CustomCategorySummary, title: String) -> some View {
        CategoryDetailView(personalNodeId: item.category.nodeId, title: title, syncVM: syncVM)
    }
}

// MARK: - 相簿裡的待確認

/// IP 相簿最上方的「待確認」：直接在這本相簿裡回答（每個角色一題，格狀顯示，見 CandidateAnswerCard）。
struct IPCandidateSection: View {
    let nodeId: String
    var onAnswered: () -> Void = {}

    @State private var candidates: [CandidateTag] = []
    @State private var busy = false
    @State private var viewing: IdentifiableString?
    @State private var loadInFlight = false

    private var groups: [(nodeId: String, items: [CandidateTag])] {
        Dictionary(grouping: candidates, by: \.nodeId)
            .map { (nodeId: $0.key, items: $0.value.sorted { ($0.score ?? 0) > ($1.score ?? 0) }) }
            .sorted { ($0.nodeId == nodeId ? 0 : 1, -$0.items.count) < ($1.nodeId == nodeId ? 0 : 1, -$1.items.count) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.nodeId) { group in questionCard(group.nodeId, group.items) }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .personalizationUpdated)) { _ in load() }
        .sheet(item: $viewing) { item in PhotoDetailModal(assetId: item.id) }
    }

    private func questionCard(_ questionNodeId: String, _ items: [CandidateTag]) -> some View {
        let name = PersonalizationService.shared.displayName(for: questionNodeId)
        return CandidateAnswerCard(
            title: "待確認：這些是「\(name)」嗎？",
            items: items,
            isBusy: busy,
            onView: { viewing = IdentifiableString(id: $0) },
            onSubmit: { yes, no in answer(yes: yes, no: no) }
        )
    }

    private func load() {
        guard !loadInFlight else { return }
        loadInFlight = true
        let id = nodeId
        Task {
            let list = await Task.detached(priority: .userInitiated) { () -> [CandidateTag] in
                (try? PersonalizationService.shared.customCandidates(forFamilyOf: id)) ?? []
            }.value
            await MainActor.run {
                candidates = list
                loadInFlight = false
            }
        }
    }

    private func answer(yes: [CandidateTag], no: [CandidateTag]) {
        guard !(yes.isEmpty && no.isEmpty), !busy else { return }
        busy = true
        Task {
            let failed = await Task.detached(priority: .userInitiated) { () -> Bool in
                var failed = false
                for item in yes {
                    do { try PersonalizationService.shared.confirmTag(assetId: item.assetId, nodeId: item.nodeId) } catch { failed = true }
                }
                for item in no {
                    do { try PersonalizationService.shared.rejectTag(assetId: item.assetId, nodeId: item.nodeId) } catch { failed = true }
                }
                return failed
            }.value
            await MainActor.run {
                busy = false
                let answered = Set((yes + no).map(\.id))
                if !failed { candidates.removeAll { answered.contains($0.id) } }
                onAnswered()
            }
        }
    }
}

// MARK: - 新增 IP

struct IPCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 從「新增角色」進來時預先選好上層作品
    var initialParentId: String? = nil
    /// 作品名稱（直接帶入欄位，不必等作品清單載入）
    var initialParentName: String? = nil
    /// 從照片詳情「用這張照片建立專屬相簿」進來時，先放入的範例照片
    var initialExampleIds: [String] = []
    /// 建立成功後呼叫
    var onCreated: (() -> Void)? = nil
    @State private var example = SpecialAlbumExample.fallback

    @State private var workName = ""
    @State private var characterName = ""
    @State private var works: [CustomCategory] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var exampleIds: [String] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let maxExamples = 20
    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 6)]

    private var trimmedWork: String { workName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCharacter: String { characterName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var existingWork: CustomCategory? {
        works.first { $0.name.compare(trimmedWork, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }
    }

    /// 角色必填：角色長相固定，是比對最準的單位；作品只用來分組（選填）。
    private var canSave: Bool {
        !trimmedCharacter.isEmpty && !exampleIds.isEmpty && !isSaving
    }

    /// 依填寫內容說明會建立什麼，避免使用者不確定結果。
    private var resultDescription: String? {
        guard !trimmedCharacter.isEmpty else { return nil }
        if trimmedWork.isEmpty {
            return "會建立專屬相簿「\(trimmedCharacter)」。"
        }
        return existingWork == nil
            ? "會建立分組「\(trimmedWork)」，並在底下建立「\(trimmedCharacter)」。"
            : "會在「\(trimmedWork)」底下新增「\(trimmedCharacter)」。"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("要認出的對象")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.text.opacity(0.6))
                        TextField(example.objectPlaceholder, text: $characterName)
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(Theme.text.opacity(0.08))
                            .cornerRadius(10)
                            .foregroundColor(Theme.text)
                        Text("對象越具體越準：同一隻寵物、同一個角色、同一件收藏品，外觀固定最容易認出來。")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.text.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("放進分組（選填）")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.text.opacity(0.6))
                        TextField(example.groupPlaceholder, text: $workName)
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(Theme.text.opacity(0.08))
                            .cornerRadius(10)
                            .foregroundColor(Theme.text)
                        if !works.isEmpty {
                            // 已建立的作品：點一下帶入（再點一次取消）
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(works) { work in
                                        let isChosen = existingWork?.id == work.id
                                        Button(action: { workName = isChosen ? "" : work.name }) {
                                            TagChip(text: work.name, systemImage: isChosen ? "checkmark" : "square.stack",
                                                    style: isChosen ? .selected : .neutral)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        Text("填了分組，這個對象的照片也會出現在分組相簿裡；分組還沒建立會自動建立。")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.text.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                        if let resultDescription {
                            Label(resultDescription, systemImage: "arrow.turn.down.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.text.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("範例照片")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.text.opacity(0.6))
                            Spacer()
                            Text("\(exampleIds.count) / \(maxExamples)")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.text.opacity(0.45))
                        }
                        Text("建議 3–10 張，包含不同的周邊或畫面（立牌、小卡、截圖…）。挑得越多樣，找得越完整。")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.text.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)

                        PhotosPicker(selection: $pickerItems, maxSelectionCount: max(1, maxExamples - initialExampleIds.count),
                                     matching: .images, photoLibrary: .shared()) {
                            Label(exampleIds.isEmpty ? "選擇照片" : "重新選擇", systemImage: "photo.on.rectangle.angled")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.onAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Theme.accent)
                                .cornerRadius(10)
                        }

                        if !exampleIds.isEmpty {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(exampleIds, id: \.self) { id in
                                    PhotoThumbnailView(assetId: id)
                                        .aspectRatio(1, contentMode: .fill)
                                        .clipped()
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }

                    TipList(points: [
                        .init("square.stack.3d.up", "拿這些照片和你/妳的圖庫比對"),
                        .init("checkmark.circle", "很像的直接加入；有點像的放到「待確認 tag」問你/妳"),
                        .init("arrow.triangle.2.circlepath", "回答「是」或「不是」都會成為參考，越用越準"),
                        .init("lock", "只整理 App 裡的分類，不移動或修改原始照片"),
                    ])
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            // 標題跟著「所屬作品」欄位即時變化（改了作品名稱或清空都會更新）。
            // 用 toolbar 中央的 Text 顯示，確保每次輸入都會重新繪製。
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(trimmedWork.isEmpty ? "建立專屬相簿" : "加到「\(trimmedWork)」")
                        .font(.headline)
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("建立", action: save)
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
            .onChange(of: pickerItems) { _, items in
                // 從照片詳情帶入的照片保留在最前面，再加上另外挑的
                var ids = initialExampleIds
                for id in items.compactMap(\.itemIdentifier) where !ids.contains(id) { ids.append(id) }
                exampleIds = ids
            }
            .onAppear {
                example = SpecialAlbumExample.forCurrentUser()
                if exampleIds.isEmpty { exampleIds = initialExampleIds }
                works = PersonalizationService.shared.customCategories().filter { $0.parentId == nil }
                if workName.isEmpty, let initialParentName {
                    workName = initialParentName   // 從作品的「新增角色」進來：所屬作品已預先填好
                } else if workName.isEmpty, let initialParentId, let parent = works.first(where: { $0.id == initialParentId }) {
                    workName = parent.name   // 從「新增角色」進來：作品已帶入，只要填角色
                }
            }
            .alert("無法建立", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let work = trimmedWork
        let character = trimmedCharacter
        let ids = exampleIds
        Task {
            do {
                _ = try await PersonalizationService.shared.createIP(character: character, work: work.isEmpty ? nil : work,
                                                                    exampleAssetIds: ids)
                await MainActor.run {
                    isSaving = false
                    onCreated?()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

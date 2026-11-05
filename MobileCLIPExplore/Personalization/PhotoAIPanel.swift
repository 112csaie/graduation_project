// PhotoAIPanel.swift
//
// 照片詳情頁中的 AI 區塊：
//   - 多個內容標籤（已確認 / 待確認，可確認、拒絕、手動新增）
//   - 收錄在相簿（一張照片可加入多本，沿用既有自訂相簿）：一行 chip，最後一顆是「加入相簿／管理」
//   - 「重新分析」與「移除 AI 分析資料」收在 tag 標題旁的「⋯」選單（不常用，避免佔版面）
//
// 照片安全：本畫面沒有任何會刪除、移動或修改原始照片的操作。
// 「移除 AI 分析資料」只影響 App 自己的 AI 資料，並在確認對話框中明確告知使用者。

import SwiftUI

struct PhotoAIPanel: View {
    let assetId: String
    private let catalog = PersonalizationService.shared.catalog

    @State private var tags: [PhotoTagRecord] = []
    @State private var albums: [ThemeAlbumMembership] = []
    @State private var isRemoved = false
    @State private var analysisStatus: String?
    @State private var isLoading = true

    private enum Operation: Equatable { case none, removing, reanalyzing, updatingTag(String) }
    @State private var operation: Operation = .none
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    @State private var showRemoveConfirm = false
    @State private var showTagPicker = false
    @State private var showAlbumPicker = false
    @State private var showCreateSpecialAlbum = false

    private var isBusy: Bool { operation != .none }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tagSection
            Divider().overlay(Theme.text.opacity(0.12))
            albumRow
            // 從這張照片出發：用它當範例，建立一本專屬相簿（找出同一個對象的其他照片）
            Button(action: { showCreateSpecialAlbum = true }) {
                Label("用這張照片建立專屬相簿", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.text.opacity(0.12))
                    .cornerRadius(999)
            }
            .buttonStyle(.plain)
            .disabled(isBusy || isRemoved)
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.highlight.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .themeCard(radius: 22)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .personalizationUpdated)) { _ in reload() }
        .confirmationDialog(
            "移除 AI 分析資料？",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("移除 AI 分析資料", role: .destructive) { removeAIAnalysis() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只會移除這張照片的特徵向量、AI 自動 tag與分析快取。原始照片、系統相簿、我的相簿與你/妳手動加入的 tag都會保留，之後也可以重新分析。")
        }
        .sheet(isPresented: $showTagPicker) {
            TagPickerSheet(existing: Set(tags.filter { $0.status != .rejected }.map(\.nodeId))) { nodeId in
                updateTag(nodeId: nodeId, accept: true)
            }
        }
        .sheet(isPresented: $showCreateSpecialAlbum) {
            IPCreateSheet(initialExampleIds: [assetId])
        }
        .sheet(isPresented: $showAlbumPicker) {
            ThemeAlbumPickerSheet(assetId: assetId)
        }
        .alert("操作失敗", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: 標籤

    private var acceptedTags: [PhotoTagRecord] { tags.filter { $0.status == .accepted } }
    private var candidateTags: [PhotoTagRecord] { tags.filter { $0.status == .candidate } }

    /// tag 區塊：
    /// - 每個 tag 是一顆 chip，點開會看到分類路徑、來源（AI／你加入的），以及「移除這個 tag」。
    /// - 模型不確定的情境（最多 1 個）以問句呈現：「這張照片是『演唱會』嗎？」→ 是／不是。
    /// - 右上角「＋ 新增」自己加入 tag；「⋯」收納不常用的「重新分析」與「移除 AI 分析資料」。
    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                sectionTitle(icon: "tag.fill", title: "tag")
                Spacer()
                Button(action: { showTagPicker = true }) {
                    Label("新增", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.text.opacity(0.12))
                        .cornerRadius(999)
                }
                .disabled(isBusy || isRemoved)
                analysisMenu
            }

            if isLoading {
                ProgressView().tint(Theme.text)
            } else if isRemoved {
                Text("這張照片的 AI 分析資料已移除，原始照片沒有任何變更。")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text.opacity(0.65))
            } else if acceptedTags.isEmpty && candidateTags.isEmpty {
                Text(analysisStatus == "failed"
                     ? "分析失敗，可以點右上角「⋯」→「重新分析」再試一次。"
                     : "還沒有 tag，可以點「＋ 新增」自己加入。")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text.opacity(0.55))
            }

            if !acceptedTags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(acceptedTags) { tag in
                        Menu {
                            Section(path(tag.nodeId)) {
                                Text(tag.source == .manual ? "你/妳手動加入的 tag" : "AI 依照片內容自動加入")
                                Button(role: .destructive, action: { updateTag(nodeId: tag.nodeId, accept: false) }) {
                                    Label("移除這個 tag", systemImage: "tag.slash")
                                }
                            }
                        } label: {
                            TagChip(text: name(tag.nodeId), systemImage: "chevron.down", style: .accepted)
                        }
                        .disabled(isBusy)
                    }
                }
            }

            ForEach(candidateTags) { tag in
                VStack(alignment: .leading, spacing: 10) {
                    Text("這張照片是「\(name(tag.nodeId))」嗎？")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text(path(tag.nodeId))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.text.opacity(0.45))
                    if operation == .updatingTag(tag.nodeId) {
                        ProgressView().tint(Theme.text)
                    } else {
                        HStack(spacing: 10) {
                            Button(action: { updateTag(nodeId: tag.nodeId, accept: true) }) {
                                Text("是")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.onAccent)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 36)
                                    .background(Theme.accent)
                                    .cornerRadius(10)
                            }
                            Button(action: { updateTag(nodeId: tag.nodeId, accept: false) }) {
                                Text("不是")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 36)
                                    .background(Theme.text.opacity(0.12))
                                    .cornerRadius(10)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Theme.text.opacity(0.06))
                .cornerRadius(12)
                .disabled(isBusy)
            }
        }
    }

    /// 例：「收藏與手作 › 收藏品」
    private func path(_ nodeId: String) -> String {
        PersonalizationService.shared.displayPath(for: nodeId)
    }

    // MARK: 主題相簿（一行：已加入的相簿 + 「＋ 加入相簿」）

    private var albumRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("收錄在相簿")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.text.opacity(0.55))
            FlowLayout(spacing: 8) {
                ForEach(albums) { album in
                    TagChip(text: album.title, systemImage: "rectangle.stack", style: .neutral)
                }
                Button(action: { showAlbumPicker = true }) {
                    TagChip(text: albums.isEmpty ? "加入相簿" : "管理", systemImage: albums.isEmpty ? "plus" : "slider.horizontal.3", style: .neutral)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
    }

    // MARK: AI 分析資料（收在「⋯」選單）

    private var analysisMenu: some View {
        Menu {
            Section("AI 分析資料") {
                Button(action: reanalyze) {
                    Label("重新分析", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("photo.reanalyze")
                Button(role: .destructive, action: { showRemoveConfirm = true }) {
                    Label("移除 AI 分析資料", systemImage: "eraser")
                }
                .disabled(isRemoved)
                .accessibilityIdentifier("photo.removeAIAnalysis")
            }
            Section {
                Text("只影響 App 的 AI 資料，不會刪除或修改原始照片")
            }
        } label: {
            Group {
                if operation == .reanalyzing || operation == .removing {
                    ProgressView().tint(Theme.text)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.text)
                }
            }
            .frame(width: 30, height: 30)
            .background(Theme.text.opacity(0.12))
            .clipShape(Circle())
        }
        .disabled(isBusy)
        .accessibilityLabel("更多 AI 分析選項")
    }

    // MARK: 小工具

    private func sectionTitle(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(Theme.text.opacity(0.8))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text)
        }
    }

    private func name(_ nodeId: String) -> String {
        PersonalizationService.shared.displayName(for: nodeId)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: 動作

    private func reload() {
        let id = assetId
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> ([PhotoTagRecord], [ThemeAlbumMembership], Bool, String?) in
                let service = PersonalizationService.shared
                let status = service.analysisStatus(for: id)
                return (service.tags(for: id), service.themeAlbums(containing: id), status.isRemoved, status.status)
            }.value
            await MainActor.run {
                tags = loaded.0
                albums = loaded.1
                isRemoved = loaded.2
                analysisStatus = loaded.3
                isLoading = false
            }
        }
    }

    private func updateTag(nodeId: String, accept: Bool) {
        guard !isBusy else { return }
        operation = .updatingTag(nodeId)
        let id = assetId
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    if accept {
                        try PersonalizationService.shared.confirmTag(assetId: id, nodeId: nodeId)
                    } else {
                        try PersonalizationService.shared.rejectTag(assetId: id, nodeId: nodeId)
                    }
                    return nil
                } catch { return error }
            }.value
            await MainActor.run {
                operation = .none
                if let error { errorMessage = describe(error) }
                reload()
            }
        }
    }

    private func removeAIAnalysis() {
        guard !isBusy else { return }   // 防止重複點擊
        operation = .removing
        statusMessage = nil
        let id = assetId
        Task {
            do {
                let report = try await PersonalizationService.shared.removeAIAnalysis(assetId: id)
                await MainActor.run {
                    operation = .none
                    statusMessage = "已移除 AI 分析資料（自動 tag \(report.autoTagsRemoved) 個，以及智慧搜尋的場景圖）。已保留手動 tag \(report.manualTagsKept) 個、我的相簿 \(report.albumMembershipsKept) 本，原始照片未變更。"
                    reload()
                }
            } catch {
                await MainActor.run {
                    operation = .none
                    errorMessage = ("資料沒有任何變更，可以再試一次。\n") + describe(error)
                }
            }
        }
    }

    private func reanalyze() {
        guard !isBusy else { return }
        operation = .reanalyzing
        statusMessage = nil
        let id = assetId
        Task {
            do {
                try await PersonalizationService.shared.reanalyze(assetId: id)
                await MainActor.run {
                    operation = .none
                    statusMessage = "重新分析完成，原始照片未變更。"
                    reload()
                }
            } catch {
                await MainActor.run {
                    operation = .none
                    errorMessage = describe(error)
                    reload()
                }
            }
        }
    }
}

// MARK: - 新增標籤

struct TagPickerSheet: View {
    let existing: Set<String>
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    private let catalog = PersonalizationService.shared.catalog
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                // 我的 IP：手動加入也會成為這個 IP 的範例
                let ips = PersonalizationService.shared.customCategories()
                    .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                if !ips.isEmpty {
                    Section("專屬相簿") {
                        ForEach(ips) { ip in
                            Button(action: {
                                onSelect(ip.nodeId)
                                dismiss()
                            }) {
                                HStack {
                                    Text(ip.name)
                                    Spacer()
                                    if existing.contains(ip.nodeId) {
                                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .disabled(existing.contains(ip.nodeId))
                        }
                    }
                }
                ForEach(catalog.topLevelNodes) { top in
                    let nodes = catalog.descendants(of: top.id)
                        .filter { $0.level == 3 }
                        .filter { query.isEmpty || $0.nameZh.localizedCaseInsensitiveContains(query) || $0.nameEn.localizedCaseInsensitiveContains(query) }
                    if !nodes.isEmpty {
                        Section(top.nameZh) {
                            ForEach(nodes) { node in
                                Button(action: {
                                    onSelect(node.id)
                                    dismiss()
                                }) {
                                    HStack {
                                        Text(node.nameZh)
                                        if node.recognition == .manualOnly {
                                            Text("僅手動")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if existing.contains(node.id) {
                                            Image(systemName: "checkmark").foregroundColor(.accentColor)
                                        }
                                    }
                                }
                                .disabled(existing.contains(node.id))
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜尋分類")
            .navigationTitle("新增 tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 加入主題相簿（沿用既有自訂相簿，一張照片可加入多本）

struct ThemeAlbumPickerSheet: View {
    let assetId: String

    @Environment(\.dismiss) private var dismiss

    @State private var albums: [CustomAlbumSummary] = []
    @State private var memberIds: Set<String> = []
    @State private var newAlbumName = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("建立新相簿") {
                    HStack {
                        TextField("例如：2026 日本旅行", text: $newAlbumName)
                        Button("建立") { createAlbum() }
                            .disabled(isWorking || newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("我的相簿") {
                    if albums.isEmpty {
                        Text("還沒有我的相簿").foregroundColor(.secondary)
                    }
                    ForEach(albums) { album in
                        Button(action: { toggle(album) }) {
                            HStack {
                                Text(album.title)
                                Spacer()
                                Image(systemName: memberIds.contains(album.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(memberIds.contains(album.id) ? .accentColor : .secondary)
                            }
                        }
                        .disabled(isWorking)
                    }
                }
                Section {
                    Text("加入我的相簿只會記錄照片的參照，不會複製或移動照片檔案。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("我的相簿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("操作失敗", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let id = assetId
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([CustomAlbumSummary], Set<String>) in
                let all = DatabaseManager.shared.fetchCustomAlbums()
                let members = Set(PersonalizationService.shared.themeAlbums(containing: id).map(\.id))
                return (all, members)
            }.value
            await MainActor.run {
                albums = result.0
                memberIds = result.1
            }
        }
    }

    private func toggle(_ album: CustomAlbumSummary) {
        guard !isWorking else { return }
        isWorking = true
        let id = assetId
        let isMember = memberIds.contains(album.id)
        Task {
            await Task.detached(priority: .userInitiated) {
                if isMember {
                    // 只移除相簿中的參照，不影響照片本身。
                    DatabaseManager.shared.removePhotoFromCustomAlbum(assetId: id, albumId: album.id)
                } else {
                    DatabaseManager.shared.addPhotos([id], toCustomAlbum: album.id)
                }
            }.value
            await MainActor.run {
                isWorking = false
                NotificationCenter.default.post(name: .personalizationUpdated, object: nil)
                load()
            }
        }
    }

    private func createAlbum() {
        let title = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isWorking else { return }
        isWorking = true
        let id = assetId
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
                if DatabaseManager.shared.customAlbumExists(named: title) { return "exists" }
                return DatabaseManager.shared.createCustomAlbum(title: title, assetIds: [id]) == nil ? "failed" : nil
            }.value
            await MainActor.run {
                isWorking = false
                switch outcome {
                case "exists"?:
                    errorMessage = "已經有同名的我的相簿。"
                case "failed"?:
                    errorMessage = "無法建立我的相簿。"
                default:
                    newAlbumName = ""
                    NotificationCenter.default.post(name: .personalizationUpdated, object: nil)
                    load()
                }
            }
        }
    }
}

// MARK: - 簡易自動換行排版

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

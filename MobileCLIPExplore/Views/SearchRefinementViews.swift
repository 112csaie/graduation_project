// SearchRefinementViews.swift
//
// 1. SearchRefinementBar：搜尋結果上方的篩選列（時間、地點、排除截圖）＋「存成相簿」「選取」。
//    選項只列這次結果裡實際有的（附張數）；句子裡拆出來的時間、地點（例如「去年夏天」「日本」）會直接套用，
//    顯示在這一列，點 ✕ 就拿掉。
// 2. SimilarPhotosView：照片頁的「相似照片」（MobileCLIP 照片向量最像的照片），可以多選、存成相簿。
// 只讀取照片與資料庫，不修改照片。

import SwiftUI

struct SearchRefinementBar: View {
    @Binding var refinement: SearchRefinement
    /// 篩選前的結果（用來算每個選項的張數）
    let resultIds: [String]
    let facts: [String: PhotoSearchFacts]
    let trips: [DetectedTrip]
    /// 篩選後的張數
    let shownCount: Int
    let onSaveAsAlbum: () -> Void
    let onSelect: () -> Void

    /// 時間選項只看「符合目前地點」的照片；地點選項只看「符合目前時間」的照片
    /// （選了「2026 年 8 月」時，地點只列 8 月拍過的地方，不會列出整本相簿去過的地方）
    private var idsForDateOptions: [String] { refinement.ignoringDate.apply(resultIds, facts: facts) }
    private var idsForPlaceOptions: [String] { refinement.ignoringPlace.apply(resultIds, facts: facts) }
    private var dateOptions: [SearchFacetOption<SearchDateRange>] { SearchFacets.dateOptions(ids: idsForDateOptions, facts: facts) }
    private var tripOptions: [SearchFacetOption<SearchDateRange>] { SearchFacets.tripOptions(ids: idsForDateOptions, trips: trips) }
    private var placeOptions: [SearchFacetOption<SearchPlaceFilter>] { SearchFacets.placeOptions(ids: idsForPlaceOptions, facts: facts) }
    private var screenshotCount: Int { SearchFacets.screenshotCount(ids: resultIds, facts: facts) }
    private var unlocatedCount: Int { SearchFacets.unlocatedCount(ids: idsForPlaceOptions, facts: facts) }
    /// 選的時間裡沒有照片：最接近的、有照片的月份（直接點就換過去）
    private var nearestMonths: [SearchFacetOption<SearchDateRange>] {
        guard shownCount == 0, let range = refinement.dateRange else { return [] }
        return SearchFacets.nearestMonths(to: range, ids: idsForDateOptions, facts: facts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    timeMenu
                    placeMenu
                    if screenshotCount > 0 || refinement.excludeScreenshots {
                        Button(action: { refinement.excludeScreenshots.toggle() }) {
                            chip(refinement.excludeScreenshots ? "已排除截圖" : "排除截圖 \(screenshotCount)",
                                 icon: refinement.excludeScreenshots ? "xmark" : "rectangle.slash",
                                 active: refinement.excludeScreenshots)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: onSaveAsAlbum) { chip("存成相簿", icon: "rectangle.stack.badge.plus", active: false) }
                        .buttonStyle(.plain)
                    Button(action: onSelect) { chip("選取", icon: "checkmark.circle", active: false) }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
            }
            if !refinement.isEmpty {
                Text("篩選後 \(shownCount) / \(resultIds.count) 張" + (refinement.place != nil && unlocatedCount > 0 ? "（\(unlocatedCount) 張沒有地點，不在地點篩選裡）" : ""))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text.opacity(0.5))
                    .padding(.horizontal, 20)
            }
            if let range = refinement.dateRange, shownCount == 0 {
                emptyDateHint(range)
            }
        }
    }

    /// 「2026 年 8 月沒有符合的照片」＋最接近、有照片的月份
    private func emptyDateHint(_ range: SearchDateRange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(nearestMonths.isEmpty ? "\(range.label)沒有符合的照片"
                                       : "\(range.label)沒有符合的照片，最接近、有照片的月份：")
                .font(.system(size: 13))
                .foregroundColor(Theme.text.opacity(0.7))
            if !nearestMonths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(nearestMonths, id: \.self) { option in
                            Button(action: { refinement.dateRange = option.value }) {
                                chip("\(option.label)・\(option.count) 張", icon: "calendar", active: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var timeMenu: some View {
        Menu {
            if refinement.dateRange != nil {
                Button(role: .destructive, action: { refinement.dateRange = nil }) { Label("不限時間", systemImage: "xmark") }
            }
            if !tripOptions.isEmpty {
                Section("旅行") {
                    ForEach(tripOptions, id: \.self) { option in
                        Button(action: { refinement.dateRange = option.value }) {
                            Text("\(option.label)・\(option.count) 張")
                        }
                    }
                }
            }
            Section("時間") {
                ForEach(dateOptions, id: \.self) { option in
                    Button(action: { refinement.dateRange = option.value }) {
                        Text("\(option.label)・\(option.count) 張")
                    }
                }
            }
        } label: {
            chip(refinement.dateRange?.label ?? "時間", icon: refinement.dateRange == nil ? "calendar" : "xmark.circle.fill",
                 active: refinement.dateRange != nil)
        }
    }

    private var placeMenu: some View {
        Menu {
            if refinement.place != nil {
                Button(role: .destructive, action: { refinement.place = nil }) { Label("不限地點", systemImage: "xmark") }
            }
            ForEach(placeOptions, id: \.self) { option in
                Button(action: { refinement.place = option.value }) {
                    Text("\(option.label)・\(option.count) 張")
                }
            }
            if placeOptions.isEmpty {
                Text("這些照片沒有地點資料")
            } else if unlocatedCount > 0 {
                Text("另有 \(unlocatedCount) 張沒有地點（截圖、沒開定位）")
            }
        } label: {
            chip(refinement.place?.label ?? "地點", icon: refinement.place == nil ? "mappin.and.ellipse" : "xmark.circle.fill",
                 active: refinement.place != nil)
        }
    }

    private func chip(_ text: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(active ? Theme.onAccent : Theme.text)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(active ? Theme.accent : Theme.text.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - 相似照片

struct SimilarPhotosView: View {
    let assetId: String

    @Environment(\.dismiss) private var dismiss
    @State private var results: [String] = []
    @State private var isLoading = true
    @State private var selection = PhotoSelectionState()
    @State private var showAddToAlbum = false
    @State private var sharePayload: SharePayload?
    @State private var message: String?
    @State private var viewing: IdentifiableString?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            PhotoThumbnailView(assetId: assetId)
                                .frame(width: 64, height: 64)
                                .cornerRadius(8)
                                .clipped()
                            Text(isLoading ? "正在比對…" : (results.isEmpty ? "沒有找到很像的照片" : "和這張很像的 \(results.count) 張照片，由像到不像"))
                                .font(.system(size: 14))
                                .foregroundColor(Theme.text.opacity(0.7))
                        }
                        .padding(.horizontal, 16)
                        if let message {
                            Text(message).font(.system(size: 13)).foregroundColor(Theme.highlight.opacity(0.85)).padding(.horizontal, 16)
                        }
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(results, id: \.self) { id in
                                Button(action: {
                                    if selection.isSelecting { selection.toggle(id) } else { viewing = IdentifiableString(id: id) }
                                }) {
                                    Color.clear
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay { PhotoThumbnailView(assetId: id) }
                                        .clipped()
                                        .overlay(alignment: .topTrailing) {
                                            if selection.isSelecting { SelectionCheckmark(selected: selection.selected.contains(id)) }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 140)
                }
                if selection.isSelecting {
                    PhotoSelectionBar(
                        count: selection.selected.count,
                        allSelected: selection.selected.count == results.count,
                        onSelectAll: {
                            selection.selected = selection.selected.count == results.count ? [] : Set(results)
                        },
                        onAddToAlbum: { showAddToAlbum = true },
                        onShare: share,
                        onFavorite: { message = PhotoFavoriteBatch.toggle(selection.ordered(results)) },
                        onDone: { selection.end() })
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("相似照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if !results.isEmpty && !selection.isSelecting {
                        Menu {
                            Button(action: { selection.isSelecting = true }) { Label("選取", systemImage: "checkmark.circle") }
                            Button(action: {
                                // 全部（含這張）存成相簿
                                selection.selected = Set(results)
                                showAddToAlbum = true
                            }) { Label("全部存成相簿", systemImage: "rectangle.stack.badge.plus") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
        .task {
            let id = assetId
            let found = await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.similarPhotos(to: id).map(\.assetId)
            }.value
            results = found
            isLoading = false
        }
        .sheet(item: $viewing) { item in PhotoDetailModal(assetId: item.id, browseAssetIds: results) }
        .sheet(isPresented: $showAddToAlbum) {
            AddPhotosToAlbumSheet(assetIds: selectedOrAll()) { text in
                message = text
                selection.end()
            }
        }
        .sheet(item: $sharePayload) { payload in ShareSheet(items: payload.items) }
        // 「全部存成相簿」取消時清掉暫時的全選，下次按「選取」才不會一開始就全選
        .onChange(of: showAddToAlbum) { _, showing in
            if !showing && !selection.isSelecting { selection.selected = [] }
        }
    }

    /// 「全部存成相簿」時連同原本這張一起
    private func selectedOrAll() -> [String] {
        let ids = selection.ordered(results)
        return selection.isSelecting ? ids : [assetId] + ids
    }

    private func share() {
        let ids = selection.ordered(results)
        Task {
            let images = await PhotoShareLoader.images(for: ids)
            await MainActor.run {
                if !images.isEmpty { sharePayload = SharePayload(items: images) }
            }
        }
    }
}

// MARK: - 地名快取

/// 搜尋句子裡可以認出來的地名（照片的地區資料）。第一次搜尋時讀一次，之後每 10 分鐘最多重讀一次。
enum SearchPlaceCache {
    private static let lock = NSLock()
    private static var cached: (date: Date, places: [SearchKnownPlace])?

    /// 不可在主執行緒呼叫（會讀資料庫）
    static func places() -> [SearchKnownPlace] {
        lock.lock()
        if let cached, Date().timeIntervalSince(cached.date) < 600 {
            lock.unlock()
            return cached.places
        }
        lock.unlock()
        let places = DatabaseManager.shared.knownSearchPlaces()
        lock.lock()
        cached = (Date(), places)
        lock.unlock()
        return places
    }
}

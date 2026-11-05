// FandomViews.swift
//
// 「我的」→「我的紀錄」的追星足跡：演出場次（演唱會、舞台劇）依年份整理，地圖上標出場館，列出每一場的照片與票券資訊。
// 計算見 PersonalizationCore 的 FandomFootprint.swift。只讀取 App 自己的分析資料與照片縮圖，不修改照片。

import MapKit
import Photos
import SwiftUI

// MARK: - 資料

enum FandomLoader {

    /// 所有演出場次（主題樂園不算），附上場館、城市與票券資訊。不可在主執行緒呼叫。
    static func loadShows() -> [FandomShow] {
        let calendar = Calendar.current
        let events = LiveEventCenter.shared.currentEvents.filter { $0.id.hasPrefix(LiveEventProfile.concert.idPrefix) }
        guard !events.isEmpty else { return [] }
        let existing = DatabaseManager.shared.existingAssetIds(events.flatMap(\.assetIds))
        let shows: [FandomShow] = events.compactMap { event in
            let ids = event.assetIds.filter { existing.contains($0) }
            guard let first = ids.first else { return nil }
            return FandomShow(id: event.id, date: event.startDate, kindNodeId: event.kindNodeId,
                              venue: LiveEventCenter.shared.venueName(for: event),
                              city: LiveEventCenter.shared.venueCity(for: event),
                              latitude: event.latitude, longitude: event.longitude,
                              coverAssetId: ids.contains(event.coverAssetId) ? event.coverAssetId : first,
                              assetIds: ids)
        }
        guard let store = DatabaseManager.shared.personalization else { return shows }
        // 票券：同一場的照片文字，加上其他看起來像演出票券的照片（例如事先截圖的電子票券）
        var texts = (try? store.photoTexts(assetIds: shows.flatMap(\.assetIds))) ?? [:]
        let others = (try? store.photoTexts(containingAny: ConcertTicketReader.searchWords, limit: 2000)) ?? [:]
        texts.merge(others) { current, _ in current }
        return FandomFootprint.attachTickets(to: shows, texts: texts, calendar: calendar)
    }

    // MARK: 顯示用文字

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "M/d（EEEEE）"
        return formatter
    }()

    static let fullDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "yyyy/M/d（EEEEE）"
        return formatter
    }()

    /// 「還有 3 天」「今天」「已過 2 天」
    static func relativeDays(to date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        if days == 0 { return "今天" }
        if days == 1 { return "明天" }
        return days > 0 ? "還有 \(days) 天" : "已過 \(-days) 天"
    }

    static func kindName(_ nodeId: String) -> String {
        TaxonomyCatalog.builtIn.node(nodeId)?.nameZh ?? "演唱會"
    }

    /// 「我的紀錄」磚塊的說明
    static func footprintSubtitle(_ shows: [FandomShow]) -> String {
        guard !shows.isEmpty else { return "去看演出後，會依場次整理在這裡" }
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let summary = FandomFootprint.summary(year: year, shows: shows, calendar: calendar)
        if summary.showCount > 0 {
            return summary.cities.isEmpty ? "今年 \(summary.showCount) 場" : "今年 \(summary.showCount) 場・\(summary.cities.count) 個城市"
        }
        let latest = FandomFootprint.years(of: shows, calendar: calendar).first ?? year
        return "\(latest) 年 \(FandomFootprint.summary(year: latest, shows: shows, calendar: calendar).showCount) 場"
    }

}

// MARK: - 追星足跡

struct FandomFootprintView: View {
    let shows: [FandomShow]
    @ObservedObject var syncVM: PhotoSyncViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int
    @State private var viewingTicket: IdentifiableString?

    init(shows: [FandomShow], syncVM: PhotoSyncViewModel) {
        self.shows = shows
        self.syncVM = syncVM
        let years = FandomFootprint.years(of: shows, calendar: .current)
        _year = State(initialValue: years.first ?? Calendar.current.component(.year, from: Date()))
    }

    private var years: [Int] { FandomFootprint.years(of: shows, calendar: .current) }
    private var summary: FandomYearSummary { FandomFootprint.summary(year: year, shows: shows, calendar: .current) }

    /// 地圖上的場館（同一個場館的多場合成一個點）
    private struct VenuePin: Identifiable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let count: Int
        let coverAssetId: String
    }

    private var pins: [VenuePin] {
        var grouped: [String: [FandomShow]] = [:]
        for show in summary.shows {
            guard let lat = show.latitude, let lon = show.longitude else { continue }
            grouped[String(format: "%.3f,%.3f", lat, lon), default: []].append(show)
        }
        return grouped.compactMap { key, shows in
            guard let first = shows.first, let lat = first.latitude, let lon = first.longitude else { return nil }
            return VenuePin(id: key, name: first.venue ?? FandomLoader.kindName(first.kindNodeId),
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            count: shows.count, coverAssetId: first.coverAssetId)
        }
        .sorted { $0.id < $1.id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if shows.isEmpty {
                        emptyHint
                    } else {
                        yearChips
                        statsRow
                        if !pins.isEmpty { mapCard }
                        if !summary.cities.isEmpty { citiesRow }
                        showList
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("追星足跡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .tint(Theme.text)
        .sheet(item: $viewingTicket) { item in PhotoDetailModal(assetId: item.id) }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("還沒有演出場次")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(Theme.text)
            Text("去看演唱會、音樂祭時拍幾張舞台照片，App 會依「同一個晚上、同一個場館」自動整理成一場，並標在地圖上。截圖和存下來的別人照片不會算進去。")
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(Theme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private var yearChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(years, id: \.self) { item in
                    ThemeChip(title: "\(item)", isSelected: item == year) {
                        withAnimation(.easeInOut(duration: 0.2)) { year = item }
                    }
                }
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            stat(value: summary.showCount, label: "場演出")
            stat(value: summary.venues.count, label: "個場館")
            stat(value: summary.cities.count, label: "個城市")
        }
    }

    private func stat(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(Theme.text)
            Text(label)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(Theme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(Theme.tile)
    }

    private var mapCard: some View {
        Map(initialPosition: .automatic) {
            ForEach(pins) { pin in
                Annotation(pin.name, coordinate: pin.coordinate) {
                    PhotoThumbnailView(assetId: pin.coverAssetId, pixelSize: 120)
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .overlay(alignment: .topTrailing) {
                            if pin.count > 1 {
                                Text("\(pin.count)")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(Theme.onAccent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.accent))
                                    .offset(x: 6, y: -4)
                            }
                        }
                }
            }
        }
        // 換年份時重建地圖，讓畫面重新框住當年的場館
        .id(year)
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var citiesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("城市")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(Theme.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(summary.cities) { city in
                        AccentPill(text: "\(city.name) \(city.count) 場")
                    }
                }
            }
        }
    }

    private var showList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(String(year)) 年的場次")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(Theme.text)
            ForEach(summary.shows) { show in
                HStack(spacing: 12) {
                    NavigationLink(destination: CategoryDetailView(metadataAlbum: album(for: show), syncVM: syncVM)) {
                        showRow(show)
                    }
                    .buttonStyle(.plain)
                    if let ticket = show.ticketAssetId {
                        Button(action: { viewingTicket = IdentifiableString(id: ticket) }) {
                            Image(systemName: "ticket")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(Theme.text)
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("看票券")
                    }
                }
                .padding(10)
                .themeCard()
            }
        }
    }

    private func showRow(_ show: FandomShow) -> some View {
        HStack(spacing: 12) {
            PhotoThumbnailView(assetId: show.coverAssetId, pixelSize: 160)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title(for: show))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                Text(subtitle(for: show))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(2)
                if let seat = show.seat {
                    Text("座位：\(seat)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func title(for show: FandomShow) -> String {
        show.title ?? show.venue ?? FandomLoader.kindName(show.kindNodeId)
    }

    private func subtitle(for show: FandomShow) -> String {
        var parts = [FandomLoader.dayFormatter.string(from: show.date)]
        if show.title != nil, let venue = show.venue { parts.append(venue) }
        if let city = show.city { parts.append(city) }
        parts.append("\(show.assetIds.count) 張")
        return parts.joined(separator: "・")
    }

    private func album(for show: FandomShow) -> MetadataAlbumSummary {
        MetadataAlbumSummary(id: show.id,
                             title: title(for: show),
                             subtitle: subtitle(for: show),
                             coverAssetId: show.coverAssetId,
                             photoCount: show.assetIds.count,
                             primaryAssetIds: show.assetIds,
                             otherAssetIds: [])
    }
}

// MemorySuggestionService.swift
//
// 回憶提醒：最近 60 天內結束的旅行或演唱會場次，照片夠多、還沒有筆記，就在首頁提醒「要整理成回憶嗎？」。
// 只讀取既有的相簿分析結果與照片拍攝時間；使用者按「略過」後同一本相簿不再提醒。

import Foundation
import Photos

struct MemorySuggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let kind: String            // trip / concert / theme_park
    let coverAssetId: String
    let assetIds: [String]
}

final class MemorySuggestionService {
    static let shared = MemorySuggestionService()

    private let dismissedKey = "memorySuggestion.dismissed"
    private let recentDays: Double = 60
    private let minimumPhotos = 8
    private var cachedCandidates: (date: Date, value: [MemorySuggestion])?
    private let lock = NSLock()

    private init() {}

    func dismiss(_ suggestion: MemorySuggestion) {
        var list = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        guard !list.contains(suggestion.id) else { return }
        list.append(suggestion.id)
        UserDefaults.standard.set(Array(list.suffix(200)), forKey: dismissedKey)
    }

    /// 目前最值得提醒的一本（沒有就回傳 nil）
    func currentSuggestion() async -> MemorySuggestion? {
        let candidates = await Task.detached(priority: .utility) { self.candidates() }.value
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
        for candidate in candidates where !dismissed.contains(candidate.id) {
            if await hasNote(candidate) { continue }
            return candidate
        }
        return nil
    }

    /// 最近結束的旅行與演唱會場次（新到舊）。旅行偵測比較花時間，30 分鐘內沿用上次結果。
    private func candidates() -> [MemorySuggestion] {
        lock.lock()
        if let cached = cachedCandidates, Date().timeIntervalSince(cached.date) < 30 * 60 {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        var albums: [(album: MetadataAlbumSummary, kind: String)] = []
        albums += DatabaseManager.shared.fetchMetadataAlbumSections().flatMap(\.albums).map { ($0, "trip") }
        albums += PersonalizationService.shared.liveEventAlbums(for: "concert").map { ($0, "concert") }
        albums += PersonalizationService.shared.liveEventAlbums(for: "theme_park").map { ($0, "theme_park") }

        let cutoff = Date().addingTimeInterval(-recentDays * 24 * 3600)
        var dated: [(suggestion: MemorySuggestion, end: Date)] = []
        for (album, kind) in albums where album.photoCount >= minimumPhotos {
            let ids = album.assetIds
            guard let end = Self.latestDate(of: ids), end >= cutoff else { continue }
            let cover = album.coverAssetId ?? ids.first ?? ""
            guard !cover.isEmpty else { continue }
            dated.append((MemorySuggestion(id: kind + ":" + album.id, title: album.title, subtitle: album.subtitle,
                                           kind: kind, coverAssetId: cover, assetIds: ids), end))
        }
        let result = dated.sorted { $0.end > $1.end }.map(\.suggestion)
        lock.lock()
        cachedCandidates = (Date(), result)
        lock.unlock()
        return result
    }

    /// 相簿裡已經有照片連到筆記（例如已整理過）就不提醒
    private func hasNote(_ suggestion: MemorySuggestion) async -> Bool {
        let ids = suggestion.assetIds
        let samples = [suggestion.coverAssetId, ids.first, ids.dropFirst(ids.count / 2).first, ids.last].compactMap { $0 }
        for id in Set(samples) {
            if let topics = try? await WikiService.shared.topics(containing: id), !topics.isEmpty { return true }
        }
        return false
    }

    private static func latestDate(of ids: [String]) -> Date? {
        guard !ids.isEmpty else { return nil }
        var latest: Date?
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            if let date = asset.creationDate, date > (latest ?? .distantPast) { latest = date }
        }
        return latest
    }
}

// TripDetector.swift
//
// Time & Place：自動把「旅行」整理成相簿（例如 8/22–8/25 東京旅遊）。
//
// 核心問題：住家、學校、公司的照片不能被當成旅行。做法（全部只用照片的時間與 GPS，不需要使用者輸入地址）：
//
// 1. 找出「常去地點」（anchor）：把有定位的照片放進約 1 公里的格子，
//    若某格子出現在「至少 6 個不同的週」，且「至少 4 次分開的造訪」或「前後跨度超過 35 天」
//    （每天都在的住家只算一次連續造訪，所以需要跨度條件）→ 視為住家／學校／公司等日常地點。
//    旅行目的地即使去過好幾次（例如東京去 3 次，每次 4 天），造訪次數與跨週數也不夠，不會被誤判成日常地點。
// 2. 一張照片距離「所有」常去地點都 ≥ 40 km 才算「在外地」；
//    若仍在常住的第一級行政區內（例如住高雄、在高雄市內），需 ≥ 100 km 才算。
// 3. 依時間串起在外地的照片：中間出現「回到常去地點」的照片、或相隔超過 48 小時，就切成不同旅程。
// 4. 有效旅程：至少 2 天且 ≥ 6 張，或單日 ≥ 15 張且距離 ≥ 80 km；超過 30 天視為搬遷／長住，不產生旅遊相簿。
// 5. 沒有定位的照片（例如相機未開定位）只在旅程「開始到結束之間」才加入，螢幕截圖一律排除。
// 6. 地區名稱只到第一級行政區（日本東京、韓國首爾、台灣高雄），不細分到區。
//
// 本檔案只依賴 Foundation，可在 macOS 用 swift test 驗證。

import Foundation

// MARK: - 資料模型

/// 第一級行政區（都道府縣、廣域市、直轄市／縣…）。
struct GeoRegion: Hashable, Codable {
    let name: String          // 反向地理編碼的 administrativeArea，例如「東京都」「首爾特別市」「高雄市」
    let country: String       // 例如「日本」
    let countryCode: String   // ISO 代碼，例如 "JP"

    var key: String { countryCode + "|" + name }
    var shortName: String { RegionNaming.shortName(name) }
}

struct GeoPhoto: Equatable {
    let id: String
    let date: Date
    let latitude: Double?
    let longitude: Double?
    let region: GeoRegion?
    let isScreenshot: Bool

    var hasLocation: Bool { latitude != nil && longitude != nil }
}

struct PlaceAnchor: Equatable {
    let latitude: Double
    let longitude: Double
    let distinctDays: Int
    let distinctWeeks: Int
    let visits: Int
    /// 照片太少、只能用「最常出現的地點」推估時為 true。
    let isFallback: Bool
}

struct RegionCount: Equatable {
    let region: GeoRegion
    let count: Int
}

struct DetectedTrip: Identifiable, Equatable {
    let id: String
    let startDate: Date
    let endDate: Date
    /// 在外地、有定位的照片（依時間排序）。
    let primaryAssetIds: [String]
    /// 旅程期間內、沒有定位的照片（不含螢幕截圖）。
    let otherAssetIds: [String]
    let regions: [RegionCount]
    let dayCount: Int
    let maxDistanceKm: Double

    var allAssetIds: [String] { primaryAssetIds + otherAssetIds }
    var country: String? { regions.first?.region.country }
    var countryCode: String? { regions.first?.region.countryCode }

    /// 常住地所在國家（ISO 代碼）。用來判斷是不是出國：出國且跑了很多地方時，標題改用國家名稱。
    var homeCountryCode: String? = nil

    /// 例：「東京」「東京、神奈川」「京都、大阪等地」「泰國」「日本、韓國」；還沒有地區資料時為 nil。
    ///
    /// 命名規則：
    /// 1. 簡稱相同的行政區合併（嘉義市＋嘉義縣 → 嘉義，不會出現「嘉義、嘉義」）。
    /// 2. 只佔 10% 以下照片的行政區略過（例如出發時在機場所在的縣市拍的幾張）。
    /// 3. 查不到行政區、只拿到國家名稱的照片，不和同國的行政區並列（不會出現「泰國、曼谷」）。
    /// 4. 跨國：列出國家；出國且去了 3 個以上行政區：用國家名稱；其餘：最多列 2 個，超過加「等地」。
    var title: String? {
        // 1. 依簡稱合併
        var merged: [(name: String, country: String, countryCode: String, count: Int)] = []
        for item in regions {
            let short = item.region.shortName
            if let index = merged.firstIndex(where: { $0.name == short && $0.countryCode == item.region.countryCode }) {
                merged[index].count += item.count
            } else {
                merged.append((short, item.region.country, item.region.countryCode, item.count))
            }
        }
        guard !merged.isEmpty else { return nil }

        // 3. 只有國家名稱的項目：同國已有行政區時略過
        let isCountryOnly: ((name: String, country: String, countryCode: String, count: Int)) -> Bool = { entry in
            !entry.country.isEmpty && (entry.name == entry.country || entry.name == RegionNaming.shortName(entry.country))
        }
        merged = merged.filter { entry in
            guard isCountryOnly(entry) else { return true }
            return !merged.contains { $0.countryCode == entry.countryCode && !isCountryOnly($0) }
        }

        // 2. 略過零星的行政區（至少保留最多照片的一個）
        merged.sort { ($0.count, $1.name) > ($1.count, $0.name) }
        let total = merged.reduce(0) { $0 + $1.count }
        let main = merged.enumerated()
            .filter { $0.offset == 0 || Double($0.element.count) / Double(max(total, 1)) >= 0.1 }
            .map { $0.element }

        // 4. 組合標題
        var countries: [(code: String, name: String)] = []
        for entry in main where !countries.contains(where: { $0.code == entry.countryCode }) {
            countries.append((entry.countryCode, entry.country))
        }
        let isAbroad = homeCountryCode.map { home in countries.contains { $0.code != home } } ?? false
        if countries.count >= 2, isAbroad || homeCountryCode == nil {
            let names = countries.map { $0.name }.filter { !$0.isEmpty }
            if !names.isEmpty {
                return names.count > 2 ? names.prefix(2).joined(separator: "、") + "等地" : names.joined(separator: "、")
            }
        }
        if isAbroad, main.count >= 3, let country = countries.first?.name, !country.isEmpty {
            return country
        }
        let names = main.map { $0.name }
        return names.count > 2 ? names.prefix(2).joined(separator: "、") + "等地" : names.joined(separator: "、")
    }
}

struct TripDetectionConfig: Equatable {
    var anchorCellDegrees: Double = 0.01
    var anchorMinDistinctWeeks: Int = 6
    var anchorMinVisits: Int = 4
    /// 連續出現超過這個天數（旅行不會這麼長）也視為日常地點，例如每天都拍的住家。
    var anchorMinSpanDays: Int = 35
    var visitGapDays: Int = 2
    var fallbackAnchorMinDays: Int = 3
    var fallbackAnchorMinVisits: Int = 2
    var awayDistanceKm: Double = 40
    var homeRegionAwayDistanceKm: Double = 100
    var tripBreakHours: Double = 48
    var maxTripDays: Int = 30
    var minPhotos: Int = 6
    var minDays: Int = 2
    var dayTripMinPhotos: Int = 15
    var dayTripMinDistanceKm: Double = 80

    static let `default` = TripDetectionConfig()
}

struct TripDetectionResult: Equatable {
    let trips: [DetectedTrip]
    let anchors: [PlaceAnchor]
    let homeRegion: GeoRegion?
    /// 定位照片太少、無法判斷常去地點，因此沒有產生任何旅遊相簿。
    let insufficientHistory: Bool
}

// MARK: - 偵測

enum TripDetector {

    static func detect(photos: [GeoPhoto],
                       config: TripDetectionConfig = .default,
                       calendar: Calendar = .current) -> TripDetectionResult {
        let located = photos
            .filter { $0.hasLocation && !$0.isScreenshot }
            .sorted { $0.date < $1.date }

        let anchors = findAnchors(located, config: config, calendar: calendar)
        guard !anchors.isEmpty else {
            return TripDetectionResult(trips: [], anchors: [], homeRegion: nil, insufficientHistory: true)
        }
        let homeRegion = dominantRegion(of: located, near: anchors, config: config)

        func distanceToHome(_ photo: GeoPhoto) -> Double {
            guard let lat = photo.latitude, let lon = photo.longitude else { return 0 }
            return anchors.map { haversineKm(lat, lon, $0.latitude, $0.longitude) }.min() ?? 0
        }

        func isAway(_ photo: GeoPhoto, distance: Double) -> Bool {
            guard distance >= config.awayDistanceKm else { return false }
            if let homeRegion, let region = photo.region, region.key == homeRegion.key {
                return distance >= config.homeRegionAwayDistanceKm
            }
            return true
        }

        // 依時間串起在外地的照片
        var groups: [[(photo: GeoPhoto, distance: Double)]] = []
        var current: [(photo: GeoPhoto, distance: Double)] = []
        for photo in located {
            let distance = distanceToHome(photo)
            if isAway(photo, distance: distance) {
                if let last = current.last,
                   photo.date.timeIntervalSince(last.photo.date) > config.tripBreakHours * 3600 {
                    groups.append(current)
                    current = []
                }
                current.append((photo, distance))
            } else if !current.isEmpty {
                // 回到常去地點 → 旅程結束
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }

        let unlocated = photos
            .filter { !$0.hasLocation && !$0.isScreenshot }
            .sorted { $0.date < $1.date }

        var trips: [DetectedTrip] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let days = Set(group.map { calendar.startOfDay(for: $0.photo.date) })
            let spanDays = (calendar.dateComponents([.day], from: calendar.startOfDay(for: first.photo.date),
                                                    to: calendar.startOfDay(for: last.photo.date)).day ?? 0) + 1
            let maxDistance = group.map(\.distance).max() ?? 0

            guard spanDays <= config.maxTripDays else { continue }               // 長住／搬遷
            guard group.count >= config.minPhotos else { continue }
            let isMultiDay = days.count >= config.minDays
            let isBigDayTrip = group.count >= config.dayTripMinPhotos && maxDistance >= config.dayTripMinDistanceKm
            guard isMultiDay || isBigDayTrip else { continue }

            let start = first.photo.date
            let end = last.photo.date
            let others = unlocated.filter { $0.date >= start && $0.date <= end }.map(\.id)

            var regionCounts: [GeoRegion: Int] = [:]
            for item in group { if let region = item.photo.region { regionCounts[region, default: 0] += 1 } }
            let regions = regionCounts
                .map { RegionCount(region: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.region.name) > ($1.count, $0.region.name) }

            trips.append(DetectedTrip(
                id: "trip-\(Int(start.timeIntervalSince1970))",
                startDate: start,
                endDate: end,
                primaryAssetIds: group.map(\.photo.id),
                otherAssetIds: others,
                regions: regions,
                dayCount: spanDays,
                maxDistanceKm: maxDistance,
                homeCountryCode: homeRegion?.countryCode
            ))
        }

        return TripDetectionResult(trips: trips.sorted { $0.startDate > $1.startDate },
                                   anchors: anchors, homeRegion: homeRegion, insufficientHistory: false)
    }

    // MARK: 常去地點

    private struct CellKey: Hashable { let lat: Int; let lon: Int }

    private static func cellKey(_ photo: GeoPhoto, _ size: Double) -> CellKey? {
        guard let lat = photo.latitude, let lon = photo.longitude else { return nil }
        return CellKey(lat: Int((lat / size).rounded(.down)), lon: Int((lon / size).rounded(.down)))
    }

    static func findAnchors(_ located: [GeoPhoto], config: TripDetectionConfig, calendar: Calendar) -> [PlaceAnchor] {
        var cells: [CellKey: [GeoPhoto]] = [:]
        for photo in located {
            if let key = cellKey(photo, config.anchorCellDegrees) { cells[key, default: []].append(photo) }
        }

        func stats(_ photos: [GeoPhoto]) -> (days: Int, weeks: Int, visits: Int, span: Int, lat: Double, lon: Double) {
            let days = Set(photos.map { calendar.startOfDay(for: $0.date) }).sorted()
            let weeks = Set(photos.map { photo -> String in
                let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: photo.date)
                return "\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
            })
            var visits = 0
            var previous: Date?
            for day in days {
                if let previous,
                   (calendar.dateComponents([.day], from: previous, to: day).day ?? 0) <= config.visitGapDays {
                    // 同一次造訪（連續幾天）
                } else {
                    visits += 1
                }
                previous = day
            }
            let span = (days.first.flatMap { first in days.last.map { calendar.dateComponents([.day], from: first, to: $0).day ?? 0 } } ?? 0) + 1
            let lat = photos.compactMap(\.latitude).reduce(0, +) / Double(max(photos.count, 1))
            let lon = photos.compactMap(\.longitude).reduce(0, +) / Double(max(photos.count, 1))
            return (days.count, weeks.count, visits, span, lat, lon)
        }

        var anchors: [PlaceAnchor] = []
        var best: (rank: [Int], anchor: PlaceAnchor)?
        for (_, photos) in cells {
            let s = stats(photos)
            if s.weeks >= config.anchorMinDistinctWeeks
                && (s.visits >= config.anchorMinVisits || s.span > config.anchorMinSpanDays) {
                anchors.append(PlaceAnchor(latitude: s.lat, longitude: s.lon, distinctDays: s.days,
                                           distinctWeeks: s.weeks, visits: s.visits, isFallback: false))
            } else if s.days >= config.fallbackAnchorMinDays, s.visits >= config.fallbackAnchorMinVisits,
                      [s.visits, s.days].lexicographicallyPrecedes(best?.rank ?? [0, 0]) == false,
                      [s.visits, s.days] != (best?.rank ?? [0, 0]) {
                // 備援：只有「分次造訪」的地點才可能是住家（單次長時間停留＝旅行目的地，不採用）
                best = ([s.visits, s.days], PlaceAnchor(latitude: s.lat, longitude: s.lon, distinctDays: s.days,
                                            distinctWeeks: s.weeks, visits: s.visits, isFallback: true))
            }
        }
        if anchors.isEmpty, let best {
            // 照片歷史太短：以「造訪次數最多」的地點當作住家推估
            anchors.append(best.anchor)
        }
        return anchors.sorted { $0.distinctDays > $1.distinctDays }
    }

    /// 常住的第一級行政區：常去地點附近照片中最常見的行政區。
    private static func dominantRegion(of located: [GeoPhoto], near anchors: [PlaceAnchor], config: TripDetectionConfig) -> GeoRegion? {
        var counts: [GeoRegion: Int] = [:]
        for photo in located {
            guard let region = photo.region, let lat = photo.latitude, let lon = photo.longitude else { continue }
            let near = anchors.contains { haversineKm(lat, lon, $0.latitude, $0.longitude) < config.awayDistanceKm }
            if near { counts[region, default: 0] += 1 }
        }
        return counts.max { ($0.value, $1.key.name) < ($1.value, $0.key.name) }?.key
    }

    // MARK: 距離

    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - 地區名稱

enum RegionNaming {
    /// 第一級行政區的常見後綴（由長到短）。
    private static let suffixes = ["特別自治市", "特別自治道", "特別市", "廣域市", "自治區", "都", "府", "縣", "县", "市", "省", "州"]

    /// 「東京都」→「東京」、「首爾特別市」→「首爾」、「高雄市」→「高雄」、「京都府」→「京都」；
    /// 去掉後綴後少於 2 個字就保留原名（例如「北海道」「加州」不變）。
    static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in suffixes where trimmed.hasSuffix(suffix) {
            let stripped = String(trimmed.dropLast(suffix.count))
            return stripped.count >= 2 ? stripped : trimmed
        }
        return trimmed
    }

    /// 反向地理編碼網格（約 2 km），同一格只需查詢一次。
    static func gridKey(latitude: Double, longitude: Double, cellDegrees: Double = 0.02) -> String {
        let lat = (latitude / cellDegrees).rounded(.down) * cellDegrees
        let lon = (longitude / cellDegrees).rounded(.down) * cellDegrees
        return String(format: "%.2f,%.2f", lat, lon)
    }
}

// PhotoMemoryService.swift
//
// 回憶草稿：把一本相簿（旅行、演唱會場次）在手機上整理成文字，寫成筆記，存進手機並連結這些照片。
// - 支援的手機：在手機上寫（OnDeviceMemoryWriter，每天分開寫，避免超過手機上模型能讀的長度）
// - 其他手機：交給電腦上的 Agent
// - 照片不上傳：送出的只有日期、地名、分類標籤、Apple Intelligence 的場景描述、已辨識的照片文字
// - 去過的地方：用照片的定位向 Apple 地圖查附近的景點、店家名稱（只送座標給 Apple 地圖，不送照片），
//   筆記裡寫的是「嘉義市立美術館」而不是「畫面像寺廟」
// - 只讀取照片資訊，不修改、不刪除照片

import CoreLocation
import Foundation
import MapKit
import Photos

/// 一組照片整理成的文字
struct PhotoContext {
    let text: String
    let dateRange: String?
    let places: [String]
    let photoCount: Int
    /// 每天的整理結果（手機上寫筆記時一天一天寫）
    var days: [MemoryDayFacts] = []
    /// 照片所在的國家代碼，多到少（用來過濾 Apple 地圖回傳的外文店名）
    var countryCodes: [String] = []
    /// 第一張到最後一張跨了幾天（7/31～8/9 是 10 天，中間沒拍照的日子也算）
    var spanDays: Int = 1
}

/// 一天的照片資料
struct MemoryDayFacts {
    /// 例如「8/6（四）」
    let label: String
    let photoCount: Int
    /// 縣市、地區（多到少）
    let regions: [String]
    /// Apple 地圖查到去過的地方（依時間）
    let visits: [String]
    /// 已確認的 tag（多到少）
    let tags: [String]
    /// 照片向量最像的分類（可能不準）
    let guesses: [String]
    /// Apple Intelligence 寫的場景描述（依時間）
    let scenes: [String]
    /// 照片文字（前幾張）
    let texts: [String]

    var hasContent: Bool { !visits.isEmpty || !tags.isEmpty || !scenes.isEmpty || !guesses.isEmpty || !texts.isEmpty }
}

enum PhotoContextBuilder {
    /// 每天最多整理幾張照片的「畫面描述」（照片多時平均取樣）
    static let maxScenesPerDay = 8
    /// 整本最多整理幾張的畫面描述
    static let maxScenesTotal = 60
    /// 標籤、文字、地點最多讀幾張（太大的相簿只取樣）
    static let maxDetailPhotos = 600

    private struct Detail {
        let tags: [String]
        let guesses: [String]     // 照片向量最像的分類（沒達確認門檻也列入，當作線索）
        let text: String?
        let region: String?
        let countryCode: String?
    }

    static func build(assetIds: [String]) async -> PhotoContext {
        let assets = fetchSortedByDate(assetIds)
        let calendar = Calendar.current
        // 依日期分組（同一天的照片一起看，行程才不會只描述其中一張）
        var days: [[PHAsset]] = []
        for asset in assets {
            if let last = days.last?.last, let a = last.creationDate, let b = asset.creationDate,
               calendar.isDate(a, inSameDayAs: b) {
                days[days.count - 1].append(asset)
            } else {
                days.append([asset])
            }
        }

        let scenesPerDay = max(3, min(maxScenesPerDay, maxScenesTotal / max(days.count, 1)))
        let sceneSamples = days.map { sample($0.filter { !$0.mediaSubtypes.contains(.photoScreenshot) }, max: scenesPerDay) }
        let descriptions = await AbstractSearchCoordinator.shared.sceneDescriptions(
            for: sceneSamples.flatMap { $0.map(\.localIdentifier) })

        let detailAssets = sample(assets, max: maxDetailPhotos)
        let details = await Task.detached(priority: .userInitiated) { () -> [String: Detail] in
            var result: [String: Detail] = [:]
            let guesses = PersonalizationService.shared.visualGuesses(for: detailAssets.map(\.localIdentifier))
            for asset in detailAssets {
                let id = asset.localIdentifier
                let tags = PersonalizationService.shared.tags(for: id)
                    .filter { $0.status == .accepted }
                    .map { PersonalizationService.shared.displayName(for: $0.nodeId) }
                let text = PhotoTextCoordinator.shared.recognizedText(for: id).flatMap { $0.isEmpty ? nil : $0 }
                var region: String?
                var countryCode: String?
                if let location = asset.location {
                    let key = RegionNaming.gridKey(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                    let cached = DatabaseManager.shared.cachedRegion(gridKey: key)
                    region = cached?.shortName
                    countryCode = cached.map(\.countryCode).flatMap { $0.isEmpty ? nil : $0.uppercased() }
                }
                result[id] = Detail(tags: tags, guesses: guesses[id] ?? [], text: text, region: region, countryCode: countryCode)
            }
            return result
        }.value

        // 每天去過的地方（Apple 地圖依照片定位查到的景點、店家）
        var visitsByDay: [[(time: Date, name: String)]] = []
        var lookups = 0
        for day in days {
            let visits = await PlaceLookup.visits(in: day, budget: max(0, PlaceLookup.maxLookups - lookups))
            lookups += visits.lookups
            visitsByDay.append(visits.places)
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "zh_Hant_TW")
        dayFormatter.dateFormat = "M/d（EEEEE）"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        var lines: [String] = []
        var totalRegions: [String: Int] = [:]
        var countryCounts: [String: Int] = [:]
        var photoDays: [MemoryDayFacts] = []
        for (dayIndex, day) in days.enumerated() {
            var regionCounts: [String: Int] = [:]
            var tagCounts: [String: Int] = [:]
            var guessCounts: [String: Int] = [:]
            var texts: [String] = []
            for asset in day {
                guard let detail = details[asset.localIdentifier] else { continue }
                if let region = detail.region { regionCounts[region, default: 0] += 1 }
                if let code = detail.countryCode { countryCounts[code, default: 0] += 1 }
                for tag in detail.tags { tagCounts[tag, default: 0] += 1 }
                for guess in detail.guesses.prefix(2) { guessCounts[guess, default: 0] += 1 }
                if let text = detail.text, texts.count < 3 {
                    texts.append(String(text.replacingOccurrences(of: "\n", with: " ").prefix(60)))
                }
            }
            for (region, count) in regionCounts { totalRegions[region, default: 0] += count }

            var header: [String] = []
            if let first = day.first?.creationDate {
                var label = dayFormatter.string(from: first)
                if let last = day.last?.creationDate {
                    label += " \(timeFormatter.string(from: first))–\(timeFormatter.string(from: last))"
                }
                header.append(label)
            } else {
                header.append("日期未知")
            }
            header.append("\(day.count) 張")
            let screenshots = day.filter { $0.mediaSubtypes.contains(.photoScreenshot) }.count
            if screenshots > 0 { header.append("其中截圖 \(screenshots) 張") }
            let places = ranked(regionCounts)
            if !places.isEmpty { header.append(places.prefix(3).joined(separator: "、")) }
            lines.append("### 第 \(dayIndex + 1) 天：" + header.joined(separator: "｜"))
            let visits = visitsByDay[dayIndex]
            if !visits.isEmpty {
                lines.append("去過的地方（Apple 地圖依照片定位查到，名稱可信）："
                             + visits.map { timeFormatter.string(from: $0.time) + " " + $0.name }.joined(separator: "、"))
            }

            let tags = ranked(tagCounts).prefix(8).map { "\($0) ×\(tagCounts[$0] ?? 0)" }
            if !tags.isEmpty { lines.append("已確認標籤：" + tags.joined(separator: "、")) }
            let guessed = ranked(guessCounts).prefix(8).map { "\($0) ×\(guessCounts[$0] ?? 0)" }
            if !guessed.isEmpty { lines.append("畫面像（照片向量判斷，可能不準）：" + guessed.joined(separator: "、")) }

            // 依時間排列的幾張照片：有 Apple Intelligence 描述就用描述，沒有就用「畫面像…」
            var seen = Set<String>()
            let scenes = sceneSamples[dayIndex].compactMap { asset -> String? in
                let id = asset.localIdentifier
                let line: String
                if let scene = descriptions[id] {
                    line = String(scene.prefix(100))
                } else if let guess = details[id]?.guesses, !guess.isEmpty {
                    line = "像：" + guess.joined(separator: "、")
                } else {
                    return nil
                }
                guard seen.insert(line).inserted else { return nil }
                let time = asset.creationDate.map { timeFormatter.string(from: $0) + " " } ?? ""
                return "- " + time + line
            }
            if !scenes.isEmpty {
                lines.append("畫面：")
                lines += scenes
            }
            if !texts.isEmpty { lines.append("照片中的文字：" + texts.joined(separator: "／")) }
            lines.append("")

            photoDays.append(MemoryDayFacts(
                label: day.first?.creationDate.map { dayFormatter.string(from: $0) } ?? "日期未知",
                photoCount: day.count,
                regions: places,
                visits: visits.map(\.name),
                tags: ranked(tagCounts),
                guesses: ranked(guessCounts),
                scenes: sceneSamples[dayIndex].compactMap { descriptions[$0.localIdentifier] },
                texts: texts))
        }

        let places = ranked(totalRegions)
        let range = dateRange(assets)
        var header: [String] = []
        if let range { header.append("日期：\(range)") }
        if !places.isEmpty { header.append("地點：\(places.joined(separator: "、"))") }
        header.append("共 \(assets.count) 張照片，分 \(days.count) 天；以下依日期整理每天的地點、標籤與畫面判斷的次數、部分照片的畫面描述與照片文字")

        return PhotoContext(text: (header + [""] + lines).joined(separator: "\n"),
                            dateRange: range, places: places, photoCount: assets.count,
                            days: photoDays, countryCodes: ranked(countryCounts), spanDays: spanDays(assets))
    }

    private static func ranked(_ counts: [String: Int]) -> [String] {
        counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    private static func fetchSortedByDate(_ ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    /// 平均取樣（保留第一張與最後一張）
    private static func sample(_ assets: [PHAsset], max: Int) -> [PHAsset] {
        guard assets.count > max, max > 1 else { return assets }
        let step = Double(assets.count - 1) / Double(max - 1)
        var picked: [PHAsset] = []
        var seen = Set<Int>()
        for i in 0..<max {
            let index = Int((Double(i) * step).rounded())
            if seen.insert(index).inserted { picked.append(assets[index]) }
        }
        return picked
    }

    private static func spanDays(_ assets: [PHAsset]) -> Int {
        let dates = assets.compactMap(\.creationDate)
        guard let first = dates.min(), let last = dates.max() else { return 1 }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: first),
                                           to: calendar.startOfDay(for: last)).day ?? 0
        return days + 1
    }

    private static func dateRange(_ assets: [PHAsset]) -> String? {
        let dates = assets.compactMap(\.creationDate)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let full = DateFormatter()
        full.locale = Locale(identifier: "zh_Hant_TW")
        full.dateFormat = "yyyy/M/d（EEEEE）"
        let calendar = Calendar.current
        if calendar.isDate(first, inSameDayAs: last) { return full.string(from: first) }
        let short = DateFormatter()
        short.locale = Locale(identifier: "zh_Hant_TW")
        short.dateFormat = calendar.isDate(first, equalTo: last, toGranularity: .year) ? "M/d（EEEEE）" : "yyyy/M/d（EEEEE）"
        return "\(full.string(from: first)) – \(short.string(from: last))"
    }
}

/// 相簿 → 回憶筆記
enum PhotoMemoryService {
    struct Result {
        let action: String     // created / updated
        let topic: String
        let reply: String
    }

    enum MemoryError: LocalizedError {
        case skipped(String)
        case notSaved
        var errorDescription: String? {
            switch self {
            case .skipped(let reason): return reason.isEmpty ? "照片資料不夠，沒有寫成筆記。" : "沒有寫成筆記：\(reason)"
            case .notSaved: return "筆記內容不完整，沒有儲存。"
            }
        }
    }

    /// - Parameters:
    ///   - kind: trip / concert / event / album
    ///   - userNote: 使用者想補充的話（可省略）
    static func draft(title: String, kind: String, assetIds: [String], userNote: String? = nil) async throws -> Result {
        let context = await PhotoContextBuilder.build(assetIds: assetIds)
        // 同一趟旅行／同一場演出若已經有筆記：合併（手機上用同名判斷，電腦上交給 Agent 判斷）
        let related = await WikiService.shared.relatedNotes(for: [title, context.dateRange ?? ""].joined(separator: " "),
                                                            targetTopic: nil)
        let response: MemoryDraftResponse
        if AIRouter.onDevice {
            response = await OnDeviceMemoryWriter.write(title: title, kind: kind, context: context, userNote: userNote,
                                                        existingTopics: related.map(\.topic))
        } else {
            response = try await APIService.shared.draftMemory(MemoryDraftRequest(
                kind: kind,
                title_hint: title,
                date_range: context.dateRange,
                places: context.places,
                photo_context: context.text,
                local_notes: related,
                user_note: userNote
            ))
        }
        guard response.wiki_decision == "store" || response.wiki_decision == "update" else {
            throw MemoryError.skipped(response.reason ?? "")
        }
        guard let saved = try await WikiService.shared.apply(decision: response.wiki_decision, topic: response.topic,
                                                             summary: response.summary, content: response.new_content,
                                                             assetIds: assetIds) else {
            throw MemoryError.notSaved
        }
        return Result(action: saved.action, topic: saved.topic, reply: response.reply)
    }
}


// MARK: - 去過的地方（Apple 地圖）

/// 用照片的定位找出去過的景點、店家：同一個地方連續拍的照片算一站，每一站問一次 Apple 地圖。
/// 只送座標給 Apple 地圖（和系統「照片」App 顯示地點的方式相同），照片本身不送出。查過的地點會記住，不重複查。
enum PlaceLookup {
    /// 一篇回憶最多查幾個地點（Apple 地圖有查詢次數限制）
    static let maxLookups = 14
    /// 一天最多幾站
    static let maxStopsPerDay = 5
    /// 照片離這一站中心超過這個距離、或間隔超過這麼久，就是下一站
    static let stopRadiusMeters: CLLocationDistance = 250
    static let stopGap: TimeInterval = 90 * 60
    /// 景點、店家要在這個距離內才算（太遠的可能是隔壁）
    static let poiRadiusMeters: CLLocationDistance = 120

    private static let cacheKey = "memoryPlaceNames"

    private struct Stop {
        var first: Date
        var coordinates: [CLLocationCoordinate2D]
        var center: CLLocation {
            let lat = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
            let lon = coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
            return CLLocation(latitude: lat, longitude: lon)
        }
    }

    /// 這一天去過的地方（依時間），以及實際問了 Apple 地圖幾次
    static func visits(in day: [PHAsset], budget: Int) async -> (places: [(time: Date, name: String)], lookups: Int) {
        var stops: [Stop] = []
        var lastDate: Date?
        for asset in day {
            guard let location = asset.location, let date = asset.creationDate,
                  !asset.mediaSubtypes.contains(.photoScreenshot) else { continue }
            if let last = stops.last, let lastDate, date.timeIntervalSince(lastDate) < stopGap,
               location.distance(from: last.center) <= stopRadiusMeters {
                stops[stops.count - 1].coordinates.append(location.coordinate)
            } else {
                stops.append(Stop(first: date, coordinates: [location.coordinate]))
            }
            lastDate = date
        }
        // 照片多的站優先，最後再依時間排回去
        let chosen = stops.enumerated()
            .sorted { $0.element.coordinates.count != $1.element.coordinates.count
                ? $0.element.coordinates.count > $1.element.coordinates.count : $0.offset < $1.offset }
            .prefix(maxStopsPerDay)
            .sorted { $0.offset < $1.offset }
            .map(\.element)

        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        var places: [(time: Date, name: String)] = []
        var lookups = 0
        for stop in chosen {
            let center = stop.center
            let key = String(format: "%.4f,%.4f", center.coordinate.latitude, center.coordinate.longitude)
            var name = cache[key]
            if name == nil {
                guard lookups < budget else { continue }
                lookups += 1
                let found = await lookupName(at: center)
                if let found { cache[key] = found }   // 查不到（或沒網路）不記住，下次再查
                name = found
            }
            if let name, !name.isEmpty, places.last?.name != name {
                places.append((stop.first, name))
            }
        }
        UserDefaults.standard.set(cache, forKey: cacheKey)
        return (places, lookups)
    }

    /// 先問有沒有在某個景點、園區裡（例如「嘉義公園」），沒有再找最近的店家、景點
    private static func lookupName(at location: CLLocation) async -> String? {
        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_Hant_TW")).first,
           let area = placemark.areasOfInterest?.first?.trimmingCharacters(in: .whitespacesAndNewlines), !area.isEmpty {
            return area
        }
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: poiRadiusMeters)
        request.pointOfInterestFilter = MKPointOfInterestFilter(excluding: [.parking, .atm, .gasStation, .evCharger, .publicTransport])
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let nearest = response.mapItems
            .compactMap { item -> (name: String, distance: CLLocationDistance)? in
                guard let name = item.name, let other = item.placemark.location else { return nil }
                return (name, other.distance(from: location))
            }
            .filter { $0.distance <= poiRadiusMeters }
            .min { $0.distance < $1.distance }
        return nearest?.name
    }
}

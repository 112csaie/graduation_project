// SearchRefinement.swift
//
// 首頁搜尋結果的篩選：時間（年份、月份、某次旅行）、地點（國家、地區）、排除截圖。
// - 篩選只用照片已經有的資料（拍攝時間、掃描時存下的地區名稱、是不是截圖），在記憶體裡比對，不重新搜尋。
// - 篩選選項只列「這次結果裡實際有的」，並附上張數。
//
// 本檔案只依賴 Foundation，可在 macOS 用 swift test 驗證。

import Foundation

/// 一張照片和篩選有關的資料
struct PhotoSearchFacts: Equatable {
    var date: Date?
    /// 第一級行政區（例如「東京都」「臺北市」）；沒有定位時為 nil
    var region: String?
    var country: String?
    var countryCode: String?
    var isScreenshot: Bool

    init(date: Date?, region: String? = nil, country: String? = nil, countryCode: String? = nil, isScreenshot: Bool = false) {
        self.date = date
        self.region = region?.isEmpty == true ? nil : region
        self.country = country?.isEmpty == true ? nil : country
        self.countryCode = countryCode?.isEmpty == true ? nil : countryCode?.uppercased()
        self.isScreenshot = isScreenshot
    }
}

/// 時間範圍：[start, end)
struct SearchDateRange: Hashable {
    let start: Date
    let end: Date
    /// 顯示用，例如「2025 年」「去年夏天」「東京 5 天」
    let label: String

    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

enum SearchPlaceFilter: Hashable {
    case country(code: String, name: String)
    case region(name: String)

    var label: String {
        switch self {
        case .country(_, let name): return name
        case .region(let name): return name
        }
    }

    func matches(_ facts: PhotoSearchFacts) -> Bool {
        switch self {
        case .country(let code, let name):
            if let c = facts.countryCode { return c == code.uppercased() }
            return facts.country == name
        case .region(let name):
            return facts.region == name
        }
    }
}

struct SearchRefinement: Equatable {
    var dateRange: SearchDateRange?
    var place: SearchPlaceFilter?
    var excludeScreenshots = false

    var isEmpty: Bool { dateRange == nil && place == nil && !excludeScreenshots }

    /// 沒有資料的照片（還沒掃描到）：有設定時間或地點時不符合，其他情況保留
    func matches(_ facts: PhotoSearchFacts?) -> Bool {
        guard let facts else { return dateRange == nil && place == nil }
        if excludeScreenshots && facts.isScreenshot { return false }
        if let dateRange {
            guard let date = facts.date, dateRange.contains(date) else { return false }
        }
        if let place, !place.matches(facts) { return false }
        return true
    }

    func apply(_ ids: [String], facts: [String: PhotoSearchFacts]) -> [String] {
        guard !isEmpty else { return ids }
        return ids.filter { matches(facts[$0]) }
    }

    /// 不管地點、只套用其他條件（算地點選項用：選了「2026 年 8 月」時，只列 8 月去過的地方）
    var ignoringPlace: SearchRefinement {
        var copy = self
        copy.place = nil
        return copy
    }

    /// 不管時間、只套用其他條件（算時間選項用：選了「泰國」時，只列在泰國拍過的年月）
    var ignoringDate: SearchRefinement {
        var copy = self
        copy.dateRange = nil
        return copy
    }
}

// MARK: - 篩選選項

struct SearchFacetOption<Value: Hashable>: Hashable {
    let value: Value
    let label: String
    let count: Int
}

enum SearchFacets {

    /// 年份（新到舊）；同一年的照片超過一半時，另外列出那一年的月份
    static func dateOptions(ids: [String], facts: [String: PhotoSearchFacts],
                            calendar: Calendar = .current) -> [SearchFacetOption<SearchDateRange>] {
        var byYear: [Int: Int] = [:]
        var byMonth: [Int: [Int: Int]] = [:]
        for id in ids {
            guard let date = facts[id]?.date else { continue }
            let y = calendar.component(.year, from: date)
            let m = calendar.component(.month, from: date)
            byYear[y, default: 0] += 1
            byMonth[y, default: [:]][m, default: 0] += 1
        }
        var options: [SearchFacetOption<SearchDateRange>] = []
        let dated = byYear.values.reduce(0, +)
        for (year, count) in byYear.sorted(by: { $0.key > $1.key }) {
            guard let range = SearchDates.year(year, calendar: calendar) else { continue }
            options.append(SearchFacetOption(value: range, label: range.label, count: count))
            // 結果大多在同一年：那一年再細分月份（新到舊）
            if byYear.count == 1 || Double(count) > Double(dated) * 0.5, let months = byMonth[year], months.count > 1 {
                for (month, monthCount) in months.sorted(by: { $0.key > $1.key }) {
                    guard let r = SearchDates.month(month, year: year, calendar: calendar) else { continue }
                    options.append(SearchFacetOption(value: r, label: "　" + r.label, count: monthCount))
                }
            }
        }
        return options
    }

    /// 選的時間裡沒有照片時：結果裡最接近那段時間、有照片的月份（依時間遠近），最多 limit 個
    static func nearestMonths(to range: SearchDateRange, ids: [String], facts: [String: PhotoSearchFacts],
                              calendar: Calendar = .current, limit: Int = 3) -> [SearchFacetOption<SearchDateRange>] {
        var counts: [DateComponents: Int] = [:]
        for id in ids {
            guard let date = facts[id]?.date else { continue }
            counts[calendar.dateComponents([.year, .month], from: date), default: 0] += 1
        }
        let middle = range.start.addingTimeInterval(range.end.timeIntervalSince(range.start) / 2)
        let options: [(option: SearchFacetOption<SearchDateRange>, distance: TimeInterval)] = counts.compactMap { key, count in
            guard let year = key.year, let month = key.month,
                  let r = SearchDates.month(month, year: year, calendar: calendar) else { return nil }
            let center = r.start.addingTimeInterval(r.end.timeIntervalSince(r.start) / 2)
            return (SearchFacetOption(value: r, label: r.label, count: count), abs(center.timeIntervalSince(middle)))
        }
        return options.sorted { $0.distance < $1.distance }.prefix(limit).map(\.option)
    }

    /// 國家（有兩個以上國家時）與地區，依張數多到少；最多 limit 個
    static func placeOptions(ids: [String], facts: [String: PhotoSearchFacts], limit: Int = 12) -> [SearchFacetOption<SearchPlaceFilter>] {
        var countries: [String: (name: String, count: Int)] = [:]
        var regions: [String: Int] = [:]
        for id in ids {
            guard let f = facts[id] else { continue }
            if let code = f.countryCode ?? f.country {
                countries[code, default: (f.country ?? code, 0)].count += 1
            }
            if let region = f.region { regions[region, default: 0] += 1 }
        }
        var options: [SearchFacetOption<SearchPlaceFilter>] = []
        if countries.count > 1 {
            for (code, entry) in countries.sorted(by: { ($0.value.count, $1.key) > ($1.value.count, $0.key) }) {
                options.append(SearchFacetOption(value: .country(code: code, name: entry.name), label: entry.name, count: entry.count))
            }
        }
        // 地區名稱就是國名（沒有更細地區的照片，例如「泰國」）：已經有國家選項時不重複列
        let countryNames = Set(countries.values.map(\.name))
        for (name, count) in regions.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) })
            where !(countries.count > 1 && countryNames.contains(name)) {
            options.append(SearchFacetOption(value: .region(name: name), label: name, count: count))
        }
        return Array(options.prefix(limit))
    }

    /// 搜尋字串本身就是地名（例如「桃園市」「桃園 夜景」「日本」）時，找出結果裡對應的地區或國家。
    /// 只比對這次結果裡實際有的地區名稱；「臺／台」視為相同，比對時忽略「市、縣、都、府、省」。
    /// 有多個地區符合時取名稱最長的（「新北市」不會被「北市」搶走）。
    static func queryPlace(_ query: String, ids: [String], facts: [String: PhotoSearchFacts]) -> SearchPlaceFilter? {
        let q = normalizePlace(query)
        guard q.count >= 2 else { return nil }
        var regions = Set<String>()
        var countries: [String: String] = [:]   // 名稱 → 代碼
        for id in ids {
            guard let f = facts[id] else { continue }
            if let region = f.region { regions.insert(region) }
            if let name = f.country { countries[name] = f.countryCode ?? name }
        }
        // 地區名稱就是國名時（例如「泰國」）用整個國家，不只找「地區叫泰國」的照片
        let regionMatch = regions.subtracting(countries.keys)
            .map { (name: $0, core: placeCore($0)) }
            .filter { $0.core.count >= 2 && q.contains($0.core) }
            .max { ($0.core.count, $1.name) < ($1.core.count, $0.name) }
        if let regionMatch { return .region(name: regionMatch.name) }
        let countryMatch = countries
            .map { (name: $0.key, code: $0.value, core: placeCore($0.key)) }
            .filter { $0.core.count >= 2 && q.contains($0.core) }
            .max { ($0.core.count, $1.name) < ($1.core.count, $0.name) }
        if let countryMatch { return .country(code: countryMatch.code, name: countryMatch.name) }
        return nil
    }

    private static func normalizePlace(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "臺", with: "台")
            .filter { !$0.isWhitespace }
    }

    /// 「桃園市」→「桃園」、「東京都」→「東京」；去掉後太短（例如「市」）就保留原名
    private static func placeCore(_ name: String) -> String {
        let n = normalizePlace(name)
        for suffix in ["市", "縣", "都", "府", "省"] where n.hasSuffix(suffix) {
            let core = String(n.dropLast())
            return core.count >= 2 ? core : n
        }
        return n
    }

    /// 結果裡有照片的旅行（依日期新到舊），最多 limit 個
    static func tripOptions(ids: [String], trips: [DetectedTrip], calendar: Calendar = .current,
                            limit: Int = 6) -> [SearchFacetOption<SearchDateRange>] {
        let idSet = Set(ids)
        var options: [SearchFacetOption<SearchDateRange>] = []
        for trip in trips.sorted(by: { $0.startDate > $1.startDate }) {
            let count = trip.allAssetIds.filter { idSet.contains($0) }.count
            guard count > 0 else { continue }
            let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: trip.startDate),
                                                      to: calendar.startOfDay(for: trip.endDate)).day.map { $0 + 1 } ?? 1)
            let label = "\(trip.title ?? "旅行")（\(SearchDates.shortDate(trip.startDate, calendar: calendar))・\(days) 天）"
            guard let range = SearchDates.days(from: trip.startDate, count: days, calendar: calendar, label: label) else { continue }
            options.append(SearchFacetOption(value: range, label: label, count: count))
            if options.count >= limit { break }
        }
        return options
    }

    /// 沒有地點（沒有定位、截圖…）的照片張數
    static func unlocatedCount(ids: [String], facts: [String: PhotoSearchFacts]) -> Int {
        ids.filter { id in facts[id].map { $0.region == nil && $0.countryCode == nil && $0.country == nil } ?? false }.count
    }

    static func screenshotCount(ids: [String], facts: [String: PhotoSearchFacts]) -> Int {
        ids.filter { facts[$0]?.isScreenshot == true }.count
    }
}

// MARK: - 日期範圍工具

enum SearchDates {
    static func year(_ year: Int, calendar: Calendar) -> SearchDateRange? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return nil }
        return SearchDateRange(start: start, end: end, label: "\(year) 年")
    }

    static func month(_ month: Int, year: Int, calendar: Calendar) -> SearchDateRange? {
        guard (1...12).contains(month),
              let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return SearchDateRange(start: start, end: end, label: "\(year) 年 \(month) 月")
    }

    /// 從 year 年 startMonth 月 1 日起 months 個月（可以跨年，例如冬天 12～2 月）
    static func months(from startMonth: Int, count months: Int, year: Int, calendar: Calendar, label: String) -> SearchDateRange? {
        guard let start = calendar.date(from: DateComponents(year: year, month: startMonth, day: 1)),
              let end = calendar.date(byAdding: .month, value: months, to: start) else { return nil }
        return SearchDateRange(start: start, end: end, label: label)
    }

    static func shortDate(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)/\(c.month ?? 0)/\(c.day ?? 0)"
    }

    static func days(from start: Date, count days: Int, calendar: Calendar, label: String) -> SearchDateRange? {
        let s = calendar.startOfDay(for: start)
        guard let end = calendar.date(byAdding: .day, value: days, to: s) else { return nil }
        return SearchDateRange(start: s, end: end, label: label)
    }
}

// MARK: - 照片向量搜尋的門檻

/// 照片向量搜尋（MobileCLIP）：只留下「明顯比相簿裡其他照片更像」的照片。
///
/// 文字和照片的相似度沒有固定的「像／不像」分界：查詢相簿裡根本沒有的東西（例如「火星上的企鵝」）時，
/// 最像的照片分數也有 0.22 左右，以前用固定門檻 0.21 就會列出一大堆不相關的照片。
/// 改成和這次查詢的整體分數比較（平均值、標準差）：真的有拍到的照片會明顯突出，
/// 沒有任何照片突出時就當作相簿裡沒有，不顯示向量搜尋的結果（標籤、照片文字、日期地點的結果照常）。
enum VectorSearchCutoff {
    /// 分數至少要這麼高（和以前相同）
    static let minimumScore: Float = 0.21
    /// 每張照片至少要比平均高幾個標準差
    static let minimumZ: Float = 2.5
    /// 最像的那張至少要這麼突出，否則視為相簿裡沒有
    static let topZ: Float = 3.5
    /// 照片太少時統計不可靠：改用較高的固定門檻
    static let minimumSample = 50
    static let smallLibraryScore: Float = 0.24
    /// 分數這麼高就算很像（相簿裡很多照片都符合時，例如「人」「食物」，個別照片不一定突出）
    static let strongScore: Float = 0.26

    /// 智慧搜尋（場景描述）找到、但照片向量沒有列出的照片：至少要比平均高這麼多個標準差，才算「有點像」
    static let plausibleZ: Float = 1.5
    static let plausibleScore: Float = 0.2

    /// candidates 裡和查詢「至少有點像」的照片（和相簿全部照片的分數比較）。scores 是全部照片的分數。
    static func plausible(_ candidates: Set<String>, among scores: [(id: String, score: Float)]) -> Set<String> {
        guard !candidates.isEmpty, !scores.isEmpty else { return [] }
        let n = Float(scores.count)
        let mean = scores.reduce(0) { $0 + $1.score } / n
        let sd = (scores.reduce(0) { $0 + ($1.score - mean) * ($1.score - mean) } / n).squareRoot()
        let cutoff = max(plausibleScore, mean + plausibleZ * sd)
        return Set(scores.filter { candidates.contains($0.id) && $0.score >= cutoff }.map(\.id))
    }

    /// 回傳要保留的照片（依分數高到低）
    static func filter(_ scores: [(id: String, score: Float)]) -> [(id: String, score: Float)] {
        guard !scores.isEmpty else { return [] }
        let sorted = scores.sorted { $0.score > $1.score }
        guard scores.count >= minimumSample else {
            return sorted.filter { $0.score >= smallLibraryScore }
        }
        let n = Float(scores.count)
        let mean = scores.reduce(0) { $0 + $1.score } / n
        let variance = scores.reduce(0) { $0 + ($1.score - mean) * ($1.score - mean) } / n
        let sd = variance.squareRoot()
        guard sd > 0.0001 else { return [] }
        // 沒有任何照片突出、分數也不高：相簿裡多半沒有這個東西
        guard (sorted[0].score - mean) / sd >= topZ || sorted[0].score >= strongScore else { return [] }
        let cutoff = max(minimumScore, min(mean + minimumZ * sd, strongScore))
        return sorted.filter { $0.score >= cutoff }
    }
}

// MARK: - 中文查詢

/// 照片向量模型（MobileCLIP）只看得懂英文：中文查詢直接比對時，會找到「畫面裡有中文字」的照片。
/// 所以中文、日文、韓文的查詢要先翻成英文（手機上的 AI），不能翻時用分類名稱對照（「貓」→ a cat）。
enum SearchQueryLanguage {

    /// 有中文、日文、韓文字
    static func needsTranslation(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF: return true
            default: return false
            }
        }
    }

    private static let ambiguousSingleWords: Set<String> = ["花", "雪", "山", "海"]

    /// 不能用手機上的 AI 時：查詢裡出現的分類名稱換成那個分類的英文描述，例如「睡覺的貓」→ "a cat"。
    /// 長的名稱先比對（「壽司與生魚片」不會只對到「壽司」）；名稱裡的「與」「、」分開比對。找不到時回傳 nil。
    static func dictionaryEnglish(_ query: String, catalog: TaxonomyCatalog) -> String? {
        var remaining = query.replacingOccurrences(of: "臺", with: "台")
        var entries: [(word: String, english: String)] = []
        for node in catalog.nodes where node.level == 3 && !node.prompts.isEmpty
            && (node.recognition == .visual || node.recognition == .assisted) {
            let english = node.prompts[0]
            let words = node.nameZh.components(separatedBy: CharacterSet(charactersIn: "與、／/"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for word in Set(words + [node.nameZh]) where word.count >= 1 && needsTranslation(word) {
                entries.append((word, english))
            }
        }
        entries.sort { ($0.word.count, $0.word) > ($1.word.count, $1.word) }
        var found: [String] = []
        for entry in entries where remaining.contains(entry.word) {
            // 常出現在地名裡的單字（「花蓮」的花）：整個查詢就是它才算
            if ambiguousSingleWords.contains(entry.word) && query.trimmingCharacters(in: .whitespaces) != entry.word { continue }
            remaining = remaining.replacingOccurrences(of: entry.word, with: " ")
            if !found.contains(entry.english) { found.append(entry.english) }
        }
        return found.isEmpty ? nil : found.prefix(3).joined(separator: ", ")
    }
}

// SearchQueryParser.swift
//
// 看懂搜尋句子裡的時間和地點，例如「去年夏天在日本的拉麵」→ 時間：去年夏天、地點：日本、搜尋：拉麵。
// - 時間、地點這類字對照片向量（MobileCLIP）沒有幫助，反而會干擾比對，所以先拆出來變成篩選，剩下的字才拿去搜尋。
// - 時間用規則判斷（今年、去年、3 月、2025 年、2025/3、夏天、寒假、聖誕節…），不用模型，打完字馬上就有。
// - 地點只比對「你照片裡出現過的地名」（App 傳進來），不會亂猜。
// - 拆不出來時原樣回傳，不影響原本的搜尋。
//
// 本檔案只依賴 Foundation，可在 macOS 用 swift test 驗證。

import Foundation

/// 可以被認出來的地名（App 從照片的地區資料整理）
struct SearchKnownPlace: Hashable {
    let name: String
    let filter: SearchPlaceFilter
}

struct ParsedSearchQuery: Equatable {
    /// 拿掉時間、地點後要搜尋的文字（可能是空字串：只有時間／地點）
    let text: String
    let dateRange: SearchDateRange?
    let place: SearchPlaceFilter?

    var hasFilters: Bool { dateRange != nil || place != nil }
}

enum SearchQueryParser {

    static func parse(_ query: String, now: Date = Date(), calendar: Calendar = .current,
                      places: [SearchKnownPlace] = []) -> ParsedSearchQuery {
        let original = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return ParsedSearchQuery(text: "", dateRange: nil, place: nil) }
        var text = original as NSString
        var removed: [NSRange] = []

        // 1. 時間
        let time = parseTime(text as String, now: now, calendar: calendar)
        removed += time.ranges

        // 2. 地點（最長的名字先比對，避免「京都」被「東京都」的一部分搶走）
        var place: SearchPlaceFilter?
        let variants = places.flatMap { p in nameVariants(p.name).map { ($0, p.filter) } }
            .sorted { $0.0.count > $1.0.count }
        for (name, filter) in variants {
            let range = text.range(of: name)
            guard range.location != NSNotFound, !removed.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            place = filter
            removed.append(range)
            break
        }

        guard time.range != nil || place != nil else {
            return ParsedSearchQuery(text: original, dateRange: nil, place: nil)
        }

        // 3. 拿掉時間、地點，以及黏在旁邊的「在、的、時候」
        let marker = "\u{1}"
        for range in removed.sorted(by: { $0.location > $1.location }) {
            text = text.replacingCharacters(in: range, with: marker) as NSString
        }
        var rest = text as String
        let particles = try! NSRegularExpression(pattern: "(在|於|去|到)?\u{1}(的時候|時候|時|拍的|拍|的)?")
        rest = particles.stringByReplacingMatches(in: rest, range: NSRange(rest.startIndex..., in: rest), withTemplate: " ")
        rest = rest.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "的、，,")))
        return ParsedSearchQuery(text: rest, dateRange: time.range, place: place)
    }

    /// 「東京都」也認「東京」；「臺北市」也認「台北市」「台北」
    static func nameVariants(_ name: String) -> [String] {
        var result: [String] = [name]
        let suffixes: Set<Character> = ["市", "縣", "都", "府", "道", "省", "州", "區"]
        if name.count >= 3, let last = name.last, suffixes.contains(last) { result.append(String(name.dropLast())) }
        for v in result where v.contains("臺") { result.append(v.replacingOccurrences(of: "臺", with: "台")) }
        return Array(Set(result)).filter { $0.count >= 2 }
    }

    // MARK: 時間

    private enum Season: String, CaseIterable {
        case spring = "春", summer = "夏", autumn = "秋", winter = "冬"
        case summerBreak = "暑假", winterBreak = "寒假", christmas = "聖誕", newYearEve = "跨年"
    }

    private static let seasonPatterns: [(String, Season)] = [
        ("春天|春季", .spring), ("夏天|夏季", .summer), ("秋天|秋季", .autumn), ("冬天|冬季", .winter),
        ("暑假", .summerBreak), ("寒假", .winterBreak), ("聖誕節|聖誕|耶誕節|耶誕", .christmas), ("跨年", .newYearEve),
    ]

    private static let chineseDigits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]

    private static func chineseNumber(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        let chars = Array(s)
        if chars.count == 1 { return chineseDigits[chars[0]] }
        if chars.count == 2, chars[0] == "十", let d = chineseDigits[chars[1]] { return 10 + d }   // 十一、十二
        return nil
    }

    private struct TimeResult {
        var range: SearchDateRange?
        var ranges: [NSRange] = []
    }

    private static func parseTime(_ text: String, now: Date, calendar: Calendar) -> TimeResult {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)

        func first(_ pattern: String) -> NSTextCheckingResult? {
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: full)
        }

        // 相對的日子：今天、昨天、前天、這個月、上個月
        let today = calendar.startOfDay(for: now)
        let relative: [(String, () -> SearchDateRange?)] = [
            ("前天", { calendar.date(byAdding: .day, value: -2, to: today).flatMap { SearchDates.days(from: $0, count: 1, calendar: calendar, label: "前天") } }),
            ("昨天", { calendar.date(byAdding: .day, value: -1, to: today).flatMap { SearchDates.days(from: $0, count: 1, calendar: calendar, label: "昨天") } }),
            ("今天", { SearchDates.days(from: today, count: 1, calendar: calendar, label: "今天") }),
            ("上上個月", { monthRelative(-2, now: now, calendar: calendar, label: "上上個月") }),
            ("上個月|上月", { monthRelative(-1, now: now, calendar: calendar, label: "上個月") }),
            ("這個月|本月", { monthRelative(0, now: now, calendar: calendar, label: "這個月") }),
        ]
        for (pattern, make) in relative {
            if let m = first(pattern), let range = make() {
                return TimeResult(range: range, ranges: [m.range])
            }
        }

        // 數字日期：2026/8、2026-08、2026.8（月），2026/8/15、2026-08-15（日）。全形「／－．」也算
        if let m = first("(?<![0-9])((?:19|20)[0-9]{2})\\s*[/\\-.／－．]\\s*([0-9]{1,2})(?:\\s*[/\\-.／－．]\\s*([0-9]{1,2}))?(?![0-9])"),
           let y = Int(ns.substring(with: m.range(at: 1))),
           let month = Int(ns.substring(with: m.range(at: 2))), (1...12).contains(month) {
            if m.range(at: 3).location != NSNotFound, let day = Int(ns.substring(with: m.range(at: 3))),
               let start = calendar.date(from: DateComponents(year: y, month: month, day: day)),
               calendar.component(.day, from: start) == day,
               let range = SearchDates.days(from: start, count: 1, calendar: calendar, label: "\(y)/\(month)/\(day)") {
                return TimeResult(range: range, ranges: [m.range])
            }
            if m.range(at: 3).location == NSNotFound {
                return TimeResult(range: SearchDates.month(month, year: y, calendar: calendar), ranges: [m.range])
            }
        }

        // 年：今年、去年、前年、2025 年
        var year: Int?
        var yearLabel = ""
        var ranges: [NSRange] = []
        if let m = first("今年|去年|前年") {
            let word = ns.substring(with: m.range)
            year = currentYear - (word == "去年" ? 1 : word == "前年" ? 2 : 0)
            yearLabel = word
            ranges.append(m.range)
        } else if let m = first("(?<![0-9])((?:19|20)[0-9]{2})(?![0-9])\\s*年?") {
            year = Int(ns.substring(with: m.range(at: 1)))
            yearLabel = "\(year!) 年"
            ranges.append(m.range)
        }

        // 月：3 月、三月、十二月（「五月天」是樂團，不算）
        if let m = first("([0-9]{1,2}|十[一二]?|[一二三四五六七八九])\\s*月(?!天)"),
           let month = chineseNumber(ns.substring(with: m.range(at: 1))), (1...12).contains(month) {
            let y = year ?? (month > currentMonth ? currentYear - 1 : currentYear)
            ranges.append(m.range)
            let label = year == nil ? "\(month) 月" : "\(yearLabel) \(month) 月"
            return TimeResult(range: SearchDates.month(month, year: y, calendar: calendar)
                .map { SearchDateRange(start: $0.start, end: $0.end, label: label) }, ranges: ranges)
        }

        // 季節、假期、節日
        for (pattern, season) in seasonPatterns {
            guard let m = first(pattern) else { continue }
            ranges.append(m.range)
            let word = ns.substring(with: m.range)
            let label = yearLabel.isEmpty ? word : yearLabel + word
            return TimeResult(range: seasonRange(season, year: year, now: now, calendar: calendar, label: label), ranges: ranges)
        }

        // 只有年
        if let year {
            return TimeResult(range: SearchDates.year(year, calendar: calendar)
                .map { SearchDateRange(start: $0.start, end: $0.end, label: yearLabel) }, ranges: ranges)
        }
        return TimeResult()
    }

    private static func monthRelative(_ offset: Int, now: Date, calendar: Calendar, label: String) -> SearchDateRange? {
        let c = calendar.dateComponents([.year, .month], from: now)
        guard let thisMonth = calendar.date(from: c),
              let start = calendar.date(byAdding: .month, value: offset, to: thisMonth),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return SearchDateRange(start: start, end: end, label: label)
    }

    /// 沒有指定年份時，用「最近一次已經開始」的那一季
    private static func seasonRange(_ season: Season, year: Int?, now: Date, calendar: Calendar, label: String) -> SearchDateRange? {
        func make(_ y: Int) -> SearchDateRange? {
            switch season {
            case .spring: return SearchDates.months(from: 3, count: 3, year: y, calendar: calendar, label: label)
            case .summer: return SearchDates.months(from: 6, count: 3, year: y, calendar: calendar, label: label)
            case .autumn: return SearchDates.months(from: 9, count: 3, year: y, calendar: calendar, label: label)
            case .winter: return SearchDates.months(from: 12, count: 3, year: y, calendar: calendar, label: label)   // 12～2 月
            case .summerBreak: return SearchDates.months(from: 7, count: 2, year: y, calendar: calendar, label: label)
            case .winterBreak: return SearchDates.months(from: 1, count: 2, year: y, calendar: calendar, label: label)
            case .christmas:
                return calendar.date(from: DateComponents(year: y, month: 12, day: 20))
                    .flatMap { SearchDates.days(from: $0, count: 12, calendar: calendar, label: label) }
            case .newYearEve:
                return calendar.date(from: DateComponents(year: y, month: 12, day: 31))
                    .flatMap { SearchDates.days(from: $0, count: 2, calendar: calendar, label: label) }
            }
        }
        if let year { return make(year) }
        let currentYear = calendar.component(.year, from: now)
        guard let thisYear = make(currentYear) else { return nil }
        return thisYear.start <= now ? thisYear : make(currentYear - 1)
    }
}

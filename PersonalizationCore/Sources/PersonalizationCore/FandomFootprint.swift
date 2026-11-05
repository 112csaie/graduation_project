// FandomFootprint.swift
//
// 追星足跡（「我的」頁 →「我的紀錄」）。
//
// 1. 追星足跡：把演唱會場次（見 LiveEventDetector）依年份整理成「看了幾場、去了哪些場館和城市」，
//    並從票券的文字補上演出名稱、座位：
//    - 同一場裡拍到的票根、入場券
//    - 不在同一場的票券照片或電子票券截圖：票上的日期和演出當天相同
//
// - 只讀取既有的場次、場館名稱、照片文字與拍攝時間，不重新分析照片、不修改照片。
// - 本檔案只依賴 Foundation 與 SQLite（讀取照片文字），可在 macOS 用 swift test 驗證。

import Foundation
import SQLite

// MARK: - 文字中的日期

enum TextDateReader {

    /// 西元年：2026/11/15、2026-11-15、2026.11.15、2026年11月15日
    private static let western = try! NSRegularExpression(
        pattern: "(?<!\\d)(20\\d{2})\\s*[年./\\-]\\s*(\\d{1,2})\\s*[月./\\-]\\s*(\\d{1,2})(?!\\d)")
    /// 民國年：115/11/15、115年11月15日、115.11.15
    private static let roc = try! NSRegularExpression(
        pattern: "(?<!\\d)(1[0-2]\\d)\\s*[年./]\\s*(\\d{1,2})\\s*[月./]\\s*(\\d{1,2})(?!\\d)")
    /// 沒有年份：11月15日、11月15號
    private static let monthDayZh = try! NSRegularExpression(
        pattern: "(?<!\\d)(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*[日號号]")
    /// 沒有年份：11/15（容易和分數、比數混淆，只有這一行有日期相關的字才算，見 dates(in:)）
    private static let monthDaySlash = try! NSRegularExpression(
        pattern: "(?<![\\d/])(\\d{1,2})/(\\d{1,2})(?![\\d/])")

    /// 一行裡出現這些字，「11/15」這種沒有年份的寫法才當成日期
    static let slashContextWords = ["日期", "期限", "到期", "截止", "有效", "使用", "兌換", "演出", "開演", "場次",
                                    "入場", "訂位", "預約", "入住", "date", "valid", "expire", "until"]

    /// 文字裡的所有日期（當天 0 點），附上所在的行號。
    /// 沒有年份的日期以 reference 推算：取 reference 當天或之後最近的一次（例如 10 月拍的「1月5日」是明年）。
    static func dates(in text: String, reference: Date, calendar: Calendar) -> [(date: Date, line: Int)] {
        let referenceDay = calendar.startOfDay(for: reference)
        var result: [(date: Date, line: Int)] = []
        let lines = text.precomposedStringWithCompatibilityMapping
            .components(separatedBy: .newlines)
        for (index, original) in lines.enumerated() {
            var line = original
            // 有年份的先找，找到的部分換成空白，避免「2026年11月15日」又被當成「11月15日」
            for (regex, offset) in [(western, 0), (roc, 1911)] {
                for match in matches(regex, in: line) {
                    if let date = makeDate(year: Int(match[1])! + offset, month: Int(match[2])!, day: Int(match[3])!,
                                           calendar: calendar) {
                        result.append((date, index))
                    }
                }
                line = blank(regex, in: line)
            }
            for match in matches(monthDayZh, in: line) {
                if let date = inferYear(month: Int(match[1])!, day: Int(match[2])!, after: referenceDay, calendar: calendar) {
                    result.append((date, index))
                }
            }
            line = blank(monthDayZh, in: line)
            let lowered = PhotoTextHints.normalize(original)
            if slashContextWords.contains(where: { lowered.contains($0) }) {
                for match in matches(monthDaySlash, in: line) {
                    if let date = inferYear(month: Int(match[1])!, day: Int(match[2])!, after: referenceDay, calendar: calendar) {
                        result.append((date, index))
                    }
                }
            }
        }
        return result
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [[String]] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { i in
                Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    private static func blank(_ regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    static func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day,       // 2/30 這種不存在的日期
              calendar.component(.month, from: date) == month else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static func inferYear(month: Int, day: Int, after referenceDay: Date, calendar: Calendar) -> Date? {
        let year = calendar.component(.year, from: referenceDay)
        for candidateYear in [year, year + 1] {
            if let date = makeDate(year: candidateYear, month: month, day: day, calendar: calendar), date >= referenceDay {
                return date
            }
        }
        return nil
    }
}

// MARK: - 演唱會票券

struct ConcertTicketInfo: Equatable {
    /// 演出名稱（例如「XXX 2026 WORLD TOUR IN TAIPEI」）
    var title: String?
    /// 座位或入場序號（例如「特A區 12排 5號」「入場序號 128」）
    var seat: String?
    /// 票上的日期
    var dates: [Date] = []
}

enum ConcertTicketReader {

    /// 票券上常見的字
    static let ticketWords = ["門票", "入場", "票價", "票種", "座位", "售票", "整理券", "序號", "tixcraft", "拓元", "kktix",
                              "寬宏", "年代售票", "ibon", "ticket", "seat", "row", "gate"]
    /// 演出名稱常見的字
    static let showWords = ["演唱會", "巡迴", "見面會", "音樂祭", "音樂節", "concert", "tour", "live", "fanmeeting",
                            "fanmeet", "showcase", "festival"]

    /// 從資料庫找可能是演出票券的照片用的字（不含 row、seat、live 這類太常見的英文字）
    static let searchWords = ["門票", "入場", "票價", "票種", "售票", "整理券", "序號", "tixcraft", "拓元", "kktix", "寬宏",
                              "年代售票", "ticket", "演唱會", "巡迴", "見面會", "音樂祭", "concert", "worldtour", "fanmeeting"]

    /// 看起來是演出的票券：至少 2 個票券用字，或 1 個票券用字＋演出用字。電影票（影廳、放映）不算。
    static func looksLikeTicket(_ normalizedText: String) -> Bool {
        let ticketHits = ticketWords.filter { normalizedText.contains($0) }.count
        let isShow = showWords.contains { normalizedText.contains($0) }
        let isMovie = ["影廳", "放映", "影城"].contains { normalizedText.contains($0) }
        guard !isMovie else { return false }
        return ticketHits >= 2 || (ticketHits >= 1 && isShow)
    }

    private static let seatPatterns: [NSRegularExpression] = [
        // 特A區 12排 5號、2樓黃2C區15排20號
        try! NSRegularExpression(pattern: "(\\S{0,10}區)?\\s*(\\d{1,3})\\s*排\\s*(\\d{1,3})\\s*號"),
        // ROW C SEAT 12
        try! NSRegularExpression(pattern: "(?i)row\\s*[:：]?\\s*[a-z0-9]{1,3}\\s*,?\\s*seat\\s*[:：]?\\s*\\d{1,4}"),
        // 入場序號 128、整理券 #35
        try! NSRegularExpression(pattern: "(入場序號|整理券|序號)\\s*[:：#No.]*\\s*\\d{1,5}"),
    ]

    /// 演出名稱前面常有的欄位名稱
    private static let titleLabels = ["活動名稱", "演出名稱", "節目名稱", "場次名稱", "event", "title"]

    static func read(_ text: String, reference: Date, calendar: Calendar) -> ConcertTicketInfo {
        let lines = text.precomposedStringWithCompatibilityMapping
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var info = ConcertTicketInfo()
        info.title = title(in: lines)
        for line in lines where info.seat == nil {
            for pattern in seatPatterns {
                let range = NSRange(line.startIndex..., in: line)
                if let match = pattern.firstMatch(in: line, range: range), let r = Range(match.range, in: line) {
                    info.seat = collapseSpaces(String(line[r]))
                    break
                }
            }
        }
        info.dates = TextDateReader.dates(in: text, reference: reference, calendar: calendar).map(\.date)
        return info
    }

    /// 第一行有演出用字的就是演出名稱；「活動名稱：」這類欄位名稱拿掉，欄位名稱單獨一行時用下一行
    static func title(in lines: [String]) -> String? {
        for (index, line) in lines.enumerated() {
            let normalized = PhotoTextHints.normalize(line)
            if let label = titleLabels.first(where: { normalized.hasPrefix($0) }) {
                let rest = stripLabel(line, label: label)
                if rest.count >= 2 { return clipped(rest) }
                if index + 1 < lines.count { return clipped(lines[index + 1]) }
            }
        }
        for line in lines {
            let normalized = PhotoTextHints.normalize(line)
            guard showWords.contains(where: { normalized.contains($0) }) else { continue }
            // 只有「演唱會」三個字、或是一長串說明文字的都不算
            guard normalized.count >= 4, line.count <= 60 else { continue }
            return clipped(line)
        }
        return nil
    }

    private static func stripLabel(_ line: String, label: String) -> String {
        var rest = line
        if let range = rest.range(of: label, options: [.caseInsensitive]) { rest = String(rest[range.upperBound...]) }
        return rest.trimmingCharacters(in: CharacterSet(charactersIn: " ：:").union(.whitespaces))
    }

    private static func clipped(_ text: String) -> String {
        let cleaned = collapseSpaces(text)
        return cleaned.count > 40 ? String(cleaned.prefix(40)) + "…" : cleaned
    }

    static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - 追星足跡

struct FandomShow: Identifiable, Equatable {
    /// 場次 id（live-…）
    let id: String
    let date: Date
    /// concert / theater_show
    let kindNodeId: String
    let venue: String?
    let city: String?
    let latitude: Double?
    let longitude: Double?
    let coverAssetId: String
    let assetIds: [String]
    var title: String? = nil
    var seat: String? = nil
    var ticketAssetId: String? = nil
}

struct NamedCount: Equatable, Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

struct FandomYearSummary: Equatable {
    let year: Int
    /// 新到舊
    let shows: [FandomShow]
    /// 場館與場次數（多到少）；不知道場館名稱的場次不算
    let venues: [NamedCount]
    /// 城市與場次數（多到少）
    let cities: [NamedCount]

    var showCount: Int { shows.count }
}

enum FandomFootprint {

    /// 有場次的年份（新到舊）
    static func years(of shows: [FandomShow], calendar: Calendar) -> [Int] {
        Array(Set(shows.map { calendar.component(.year, from: $0.date) })).sorted(by: >)
    }

    static func summary(year: Int, shows: [FandomShow], calendar: Calendar) -> FandomYearSummary {
        let inYear = shows
            .filter { calendar.component(.year, from: $0.date) == year }
            .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
        return FandomYearSummary(year: year, shows: inYear,
                                 venues: counts(inYear.compactMap(\.venue)),
                                 cities: counts(inYear.compactMap(\.city)))
    }

    private static func counts(_ names: [String]) -> [NamedCount] {
        var tally: [String: Int] = [:]
        for name in names where !name.isEmpty { tally[name, default: 0] += 1 }
        return tally.map { NamedCount(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// 替每一場找票券：同一場裡的票券照片優先，其次是票上日期和演出當天相同的照片（例如事先截圖的電子票券）。
    /// - Parameter texts: 照片 id → 照片文字（原文，保留換行）
    static func attachTickets(to shows: [FandomShow], texts: [String: String], calendar: Calendar) -> [FandomShow] {
        // 先把看起來像演出票券的照片讀一次
        var tickets: [String: ConcertTicketInfo] = [:]
        let reference = (shows.map(\.date).min() ?? Date()).addingTimeInterval(-200 * 86_400)
        for (assetId, text) in texts where ConcertTicketReader.looksLikeTicket(PhotoTextHints.normalize(text)) {
            tickets[assetId] = ConcertTicketReader.read(text, reference: reference, calendar: calendar)
        }
        guard !tickets.isEmpty else { return shows }
        var usedTickets = Set<String>()
        return shows.map { show in
            var show = show
            let day = calendar.startOfDay(for: show.date)
            let own = show.assetIds.filter { tickets[$0] != nil }
            let byDate = tickets.keys.sorted().filter { id in
                !show.assetIds.contains(id) && tickets[id]!.dates.contains(day)
            }
            // 有演出名稱的票優先；同一張票只配給一場
            let candidates = (own + byDate).filter { !usedTickets.contains($0) }
            guard let best = candidates.first(where: { tickets[$0]?.title != nil }) ?? candidates.first,
                  let info = tickets[best] else { return show }
            usedTickets.insert(best)
            show.title = show.title ?? info.title
            show.seat = show.seat ?? info.seat
            show.ticketAssetId = best
            return show
        }
    }
}

// MARK: - 讀取照片文字

extension PersonalizationStore {

    /// 文字含有任一關鍵字的照片（原文，保留換行），新辨識的在前。只讀取 App 自己的辨識結果。
    func photoTexts(containingAny keywords: [String], limit: Int = 3000) throws -> [String: String] {
        let needles = Array(Set(keywords.map(PhotoTextHints.normalize).filter { !$0.isEmpty }))
        guard !needles.isEmpty, limit > 0 else { return [:] }
        let escape: (String) -> String = {
            $0.replacingOccurrences(of: "!", with: "!!")
                .replacingOccurrences(of: "%", with: "!%")
                .replacingOccurrences(of: "_", with: "!_")
        }
        let conditions = Array(repeating: "t.normalized LIKE ? ESCAPE '!'", count: needles.count).joined(separator: " OR ")
        let sql = """
        SELECT t.asset_id, t.text FROM PhotoText t
        LEFT JOIN PhotoFeatures f ON f.asset_id = t.asset_id
        WHERE f.ai_removed_at IS NULL AND t.normalized <> '' AND (\(conditions))
        ORDER BY t.recognized_at DESC
        LIMIT ?
        """
        var args: [Binding?] = needles.map { "%" + escape($0) + "%" }
        args.append(Int64(limit))
        var result: [String: String] = [:]
        for row in try db.prepare(sql).run(args) {
            if let id = row[0] as? String, let text = row[1] as? String { result[id] = text }
        }
        return result
    }

    /// 多張照片的原文（保留換行）
    func photoTexts(assetIds: [String]) throws -> [String: String] {
        guard !assetIds.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for start in stride(from: 0, to: assetIds.count, by: 400) {
            let chunk = Array(assetIds[start..<min(start + 400, assetIds.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let args: [Binding?] = chunk
            for row in try db.prepare("SELECT asset_id, text FROM PhotoText WHERE text <> '' AND asset_id IN (\(placeholders))").run(args) {
                if let id = row[0] as? String, let text = row[1] as? String { result[id] = text }
            }
        }
        return result
    }
}

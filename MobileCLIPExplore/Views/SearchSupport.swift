// SearchSupport.swift
//
// 首頁搜尋的小工具：找到的原因（顯示在縮圖上）、結果篩選、最近搜尋（只存在這支手機的 App 設定）。

import Foundation

/// 照片為什麼出現在搜尋結果（依顯示優先順序排列）
enum SearchReason: String, CaseIterable, Hashable {
    case text      // 照片中的文字符合
    case tag       // tag 名稱符合
    case scene     // 智慧搜尋（Apple Intelligence 場景描述）

    var title: String {
        switch self {
        case .text: return "文字"
        case .tag: return "tag"
        case .scene: return "智慧"
        }
    }

    var icon: String {
        switch self {
        case .text: return "text.viewfinder"
        case .tag: return "tag"
        case .scene: return "eye"
        }
    }
}

enum SearchFilter: Hashable {
    case all, photos, notes, text
}

enum RecentSearches {
    private static let key = "recentSearches"
    private static let limit = 8

    /// 還沒搜尋過時的建議
    static let suggestions = ["演唱會", "拉麵", "海邊的夕陽", "夜景", "小卡", "生日蛋糕", "截圖"]

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = load().filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - 依你的照片產生的搜尋建議

/// 照片頁搜尋列、Agent 開場共用。用你最常拍的分類與照片裡的地名組成問法（見 SearchSuggestionBuilder），
/// 只讀 App 自己的分類與地區資料；一小時內重用上次的結果。
@MainActor
enum PhotoSearchSuggestions {
    private static var cached: (date: Date, items: [String])?

    static func load() async -> [String] {
        if let cached, Date().timeIntervalSince(cached.date) < 3600 { return cached.items }
        let items = await Task.detached(priority: .utility) { () -> [String] in
            var categories: [(name: String, count: Int)] = []
            if let data = try? PersonalizationService.shared.loadBrowseData() {
                var seen = Set<String>()
                for section in data.enabledSections + data.otherSections {
                    for item in section.items where seen.insert(item.node.id).inserted {
                        categories.append((name: item.node.nameZh, count: item.photoCount))
                    }
                }
            }
            let places = DatabaseManager.shared.knownSearchPlaces().compactMap { place -> String? in
                if case .region(let name) = place.filter { return name }
                return nil
            }
            return SearchSuggestionBuilder.build(categories: categories, places: places)
        }.value
        cached = (Date(), items)
        return items
    }
}

// MARK: - 照片依天分組

/// 「照片」頁每天一組（日期貼紙）。日期來自掃描時存的拍攝時間；讀不到的跟著前一張。
struct PhotoDaySection: Identifiable {
    let id: String
    let title: String
    let items: [PhotoListItem]

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    static func parseDate(_ text: String) -> Date? {
        guard text.count >= 19 else { return nil }
        if let date = parser.date(from: text) { return date }
        // 只有日期的舊資料
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: String(text.prefix(10)))
    }

    static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let weekdays = ["週日", "週一", "週二", "週三", "週四", "週五", "週六"]
        let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let md = "\(comps.month ?? 0)/\(comps.day ?? 0)"
        if calendar.isDateInToday(date) { return "今天・\(md)" }
        if calendar.isDateInYesterday(date) { return "昨天・\(md)" }
        let weekday = weekdays[((comps.weekday ?? 1) - 1) % 7]
        if comps.year == calendar.component(.year, from: now) { return "\(md) \(weekday)" }
        return "\(comps.year ?? 0)/\(md) \(weekday)"
    }

    /// 依天分組（保持原本順序）；也算出今天拍了幾張
    static func group(_ photos: [PhotoListItem], calendar: Calendar = .current) -> (sections: [PhotoDaySection], todayCount: Int) {
        var sections: [PhotoDaySection] = []
        var currentKey: String?
        var currentTitle = "更早的照片"
        var bucket: [PhotoListItem] = []
        var todayCount = 0
        let keyFormatter = DateFormatter()
        keyFormatter.locale = Locale(identifier: "en_US_POSIX")
        keyFormatter.calendar = calendar
        keyFormatter.dateFormat = "yyyy-MM-dd"

        func flush() {
            guard let key = currentKey, !bucket.isEmpty else { return }
            // 同一天的照片被別天隔開時（很少見），用不同 id 避免重複
            let id = sections.contains { $0.id == key } ? "\(key)-\(sections.count)" : key
            sections.append(PhotoDaySection(id: id, title: currentTitle, items: bucket))
            bucket = []
        }

        for photo in photos {
            if let date = parseDate(photo.date) {
                let key = keyFormatter.string(from: date)
                if calendar.isDateInToday(date) { todayCount += 1 }
                if key != currentKey {
                    flush()
                    currentKey = key
                    currentTitle = title(for: date, calendar: calendar)
                }
            } else if currentKey == nil {
                currentKey = "unknown"
            }
            bucket.append(photo)
        }
        flush()
        return (sections, todayCount)
    }
}

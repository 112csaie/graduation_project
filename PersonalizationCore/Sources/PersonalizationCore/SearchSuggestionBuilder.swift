// SearchSuggestionBuilder.swift
//
// 依你的照片產生搜尋建議（照片頁搜尋列下面、Agent 開場的建議問題）：
// 用你最常拍的分類、照片裡出現過的地方、現在的季節，組成「上個月的拉麵」「東京的美食」「去年秋天的夜景」這種問法。
// 只用分類名稱與地名（都是 App 自己的資料），不讀照片內容，也不送到任何地方。
// 產生的句子都是搜尋看得懂的寫法（時間、地點由 SearchQueryParser 拆出來）。
//
// 本檔案只依賴 Foundation，可在 macOS 用 swift test 驗證。

import Foundation

enum SearchSuggestionBuilder {
    /// 還沒有分類資料時的建議
    static let fallback = ["海邊的夕陽", "夜景", "拉麵", "演唱會", "生日蛋糕", "截圖"]

    /// - categories: 分類名稱與張數（不必排序）
    /// - places: 照片裡出現過的地名（越常出現的放越前面）
    static func build(categories: [(name: String, count: Int)], places: [String],
                      now: Date = Date(), calendar: Calendar = .current, limit: Int = 6) -> [String] {
        let names = categories
            .filter { $0.count >= 3 && !$0.name.isEmpty }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .map(\.name)
        let placeNames = places.filter { !$0.isEmpty }
        guard !names.isEmpty else {
            return Array((placeNames.prefix(2) + fallback).prefix(limit))
        }

        func category(_ index: Int) -> String { names[index % names.count] }
        var result: [String] = []
        func add(_ text: String) {
            if !result.contains(text) { result.append(text) }
        }

        add("上個月的\(category(0))")
        if let place = placeNames.first { add("\(place)的\(category(1))") }
        if names.count > 2 { add(category(2)) }
        add("去年\(season(of: now, calendar: calendar))的\(category(names.count > 3 ? 3 : 0))")
        // 只有地名：搜尋會列出在那裡拍的全部照片
        if placeNames.count > 1 { add(placeNames[1]) }
        for index in 0..<names.count where result.count < limit {
            add(names[index])
        }
        return Array(result.prefix(limit))
    }

    static func season(of date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.month, from: date) {
        case 3...5: return "春天"
        case 6...8: return "夏天"
        case 9...11: return "秋天"
        default: return "冬天"
        }
    }
}

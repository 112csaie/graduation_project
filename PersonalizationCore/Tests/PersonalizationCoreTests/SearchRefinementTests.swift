import XCTest
@testable import PersonalizationCore

/// 搜尋結果篩選與「看懂句子裡的時間和地點」
final class SearchRefinementTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private var now: Date { date(2026, 10, 21) }

    private var places: [SearchKnownPlace] {
        [SearchKnownPlace(name: "日本", filter: .country(code: "JP", name: "日本")),
         SearchKnownPlace(name: "東京都", filter: .region(name: "東京都")),
         SearchKnownPlace(name: "京都府", filter: .region(name: "京都府")),
         SearchKnownPlace(name: "臺北市", filter: .region(name: "臺北市"))]
    }

    private func parse(_ text: String) -> ParsedSearchQuery {
        SearchQueryParser.parse(text, now: now, calendar: calendar, places: places)
    }

    // MARK: 句子解析

    func testSeasonYearAndPlace() {
        let q = parse("去年夏天在日本的拉麵")
        XCTAssertEqual(q.text, "拉麵")
        XCTAssertEqual(q.dateRange?.start, date(2025, 6, 1, 0))
        XCTAssertEqual(q.dateRange?.end, date(2025, 9, 1, 0))
        XCTAssertEqual(q.dateRange?.label, "去年夏天")
        XCTAssertEqual(q.place, .country(code: "JP", name: "日本"))
    }

    func testYearAndMonth() {
        let q = parse("2025年3月的櫻花")
        XCTAssertEqual(q.text, "櫻花")
        XCTAssertEqual(q.dateRange?.start, date(2025, 3, 1, 0))
        XCTAssertEqual(q.dateRange?.end, date(2025, 4, 1, 0))
    }

    /// 數字日期：2026/8、2026-08、2026.8、2026/8/15
    func testNumericDates() {
        for text in ["2026/8", "2026-08", "2026.8", "2026／8", "2026 / 8 泰國"] {
            let q = parse(text)
            XCTAssertEqual(q.dateRange?.start, date(2026, 8, 1, 0), text)
            XCTAssertEqual(q.dateRange?.end, date(2026, 9, 1, 0), text)
            XCTAssertEqual(q.dateRange?.label, "2026 年 8 月", text)
        }
        XCTAssertEqual(parse("2026/8 泰國").text, "泰國")
        let day = parse("2026/8/15 煙火")
        XCTAssertEqual(day.dateRange?.start, date(2026, 8, 15, 0))
        XCTAssertEqual(day.dateRange?.end, date(2026, 8, 16, 0))
        XCTAssertEqual(day.text, "煙火")
        XCTAssertEqual(parse("2026/13").dateRange?.label, "2026 年", "沒有 13 月：只算年份")
    }

    func testMonthWithoutYearUsesMostRecent() {
        XCTAssertEqual(parse("十二月 東京").dateRange?.start, date(2025, 12, 1, 0), "還沒到的月份算去年")
        XCTAssertEqual(parse("三月").dateRange?.start, date(2026, 3, 1, 0))
        XCTAssertEqual(parse("10月").dateRange?.start, date(2026, 10, 1, 0), "這個月算今年")
    }

    func testSeasonWithoutYearUsesMostRecentStarted() {
        XCTAssertEqual(parse("夏天").dateRange?.start, date(2026, 6, 1, 0))
        XCTAssertEqual(parse("冬天").dateRange?.start, date(2025, 12, 1, 0), "今年的冬天還沒開始")
        XCTAssertEqual(parse("冬天").dateRange?.end, date(2026, 3, 1, 0))
        XCTAssertEqual(parse("聖誕節").dateRange?.start, date(2025, 12, 20, 0))
    }

    func testRelativeDays() {
        XCTAssertEqual(parse("昨天的晚餐").dateRange?.start, date(2026, 10, 20, 0))
        XCTAssertEqual(parse("昨天的晚餐").text, "晚餐")
        XCTAssertEqual(parse("上個月").dateRange?.start, date(2026, 9, 1, 0))
        XCTAssertEqual(parse("今年的生日").dateRange?.start, date(2026, 1, 1, 0))
        XCTAssertEqual(parse("今年的生日").text, "生日")
    }

    func testPlaceVariants() {
        XCTAssertEqual(parse("東京的拉麵").place, .region(name: "東京都"), "東京都也認東京")
        XCTAssertEqual(parse("京都的楓葉").place, .region(name: "京都府"))
        XCTAssertEqual(parse("京都的楓葉").text, "楓葉")
        XCTAssertEqual(parse("台北夜景").place, .region(name: "臺北市"), "臺／台都認得")
        XCTAssertEqual(parse("日本").text, "", "只有地點時，搜尋文字是空的")
    }

    func testNothingToParseKeepsQuery() {
        let q = parse("五月天演唱會")
        XCTAssertEqual(q.text, "五月天演唱會", "五月天是樂團，不是五月")
        XCTAssertNil(q.dateRange)
        XCTAssertFalse(q.hasFilters)
        XCTAssertEqual(parse("海邊的夕陽").text, "海邊的夕陽")
        XCTAssertNil(SearchQueryParser.parse("大阪城", now: now, calendar: calendar, places: places).place,
                     "照片裡沒有的地名不會被拆掉")
    }

    // MARK: 篩選

    private var facts: [String: PhotoSearchFacts] {
        ["tokyo25": PhotoSearchFacts(date: date(2025, 7, 1), region: "東京都", country: "日本", countryCode: "JP"),
         "kyoto25": PhotoSearchFacts(date: date(2025, 11, 3), region: "京都府", country: "日本", countryCode: "jp"),
         "taipei26": PhotoSearchFacts(date: date(2026, 2, 1), region: "臺北市", country: "臺灣", countryCode: "TW"),
         "shot": PhotoSearchFacts(date: date(2026, 3, 1), isScreenshot: true)]
    }

    func testApplyFilters() {
        let ids = ["tokyo25", "kyoto25", "taipei26", "shot", "unscanned"]
        XCTAssertEqual(SearchRefinement().apply(ids, facts: facts), ids, "沒有篩選時全部保留")
        var r = SearchRefinement()
        r.excludeScreenshots = true
        XCTAssertEqual(r.apply(ids, facts: facts), ["tokyo25", "kyoto25", "taipei26", "unscanned"])
        r.place = .country(code: "JP", name: "日本")
        XCTAssertEqual(r.apply(ids, facts: facts), ["tokyo25", "kyoto25"], "國家代碼不分大小寫；沒資料的照片不符合地點")
        r.dateRange = SearchDates.year(2025, calendar: calendar)
        r.place = .region(name: "京都府")
        XCTAssertEqual(r.apply(ids, facts: facts), ["kyoto25"])
    }

    func testFacetOptions() {
        let ids = ["tokyo25", "kyoto25", "taipei26", "shot"]
        let places = SearchFacets.placeOptions(ids: ids, facts: facts)
        XCTAssertEqual(places.first?.label, "日本")
        XCTAssertEqual(places.first?.count, 2)
        XCTAssertTrue(places.contains { $0.value == .region(name: "臺北市") })
        XCTAssertEqual(SearchFacets.unlocatedCount(ids: ids, facts: facts), 1)
        XCTAssertEqual(SearchFacets.screenshotCount(ids: ids, facts: facts), 1)
        let years = SearchFacets.dateOptions(ids: ids, facts: facts, calendar: calendar)
        XCTAssertEqual(years.first?.label, "2026 年")
        XCTAssertTrue(years.contains { $0.label == "2025 年" && $0.count == 2 })
    }

    /// 選了時間，地點選項只列那段時間拍過的地方；選的時間沒有照片時，列出最接近的月份
    func testFacetsFollowOtherFilters() {
        let ids = ["tokyo25", "kyoto25", "taipei26", "shot"]
        var r = SearchRefinement()
        r.dateRange = SearchDates.month(7, year: 2025, calendar: calendar)
        let places = SearchFacets.placeOptions(ids: r.ignoringPlace.apply(ids, facts: facts), facts: facts)
        XCTAssertEqual(places.map(\.label), ["東京都"], "7 月只去過東京")
        r.place = .region(name: "京都府")
        XCTAssertTrue(r.apply(ids, facts: facts).isEmpty)
        let years = SearchFacets.dateOptions(ids: r.ignoringDate.apply(ids, facts: facts), facts: facts, calendar: calendar)
        XCTAssertEqual(years.map(\.label), ["2025 年"], "京都只在 2025 年拍過")

        let august = SearchDates.month(8, year: 2026, calendar: calendar)!
        let nearest = SearchFacets.nearestMonths(to: august, ids: ids, facts: facts, calendar: calendar, limit: 2)
        XCTAssertEqual(nearest.map(\.label), ["2026 年 3 月", "2026 年 2 月"])
    }

    /// 泰國的照片有些地區是「曼谷」、有些沒有更細的地區（地區名稱就是「泰國」）：搜尋「泰國」要用整個國家
    func testCountryNamedRegionUsesWholeCountry() {
        let thai: [String: PhotoSearchFacts] = [
            "bkk": PhotoSearchFacts(date: date(2026, 8, 3), region: "曼谷", country: "泰國", countryCode: "TH"),
            "beach": PhotoSearchFacts(date: date(2026, 8, 5), region: "泰國", country: "泰國", countryCode: "TH"),
            "tw": PhotoSearchFacts(date: date(2026, 8, 9), region: "臺北市", country: "臺灣", countryCode: "TW"),
        ]
        let ids = ["bkk", "beach", "tw"]
        let place = SearchFacets.queryPlace("泰國", ids: ids, facts: thai)
        XCTAssertEqual(place, .country(code: "TH", name: "泰國"))
        var r = SearchRefinement()
        r.place = place
        XCTAssertEqual(r.apply(ids, facts: thai), ["bkk", "beach"], "在曼谷拍的也算")
        let options = SearchFacets.placeOptions(ids: ids, facts: thai)
        XCTAssertEqual(options.filter { $0.label == "泰國" }.count, 1, "國家和「地區叫泰國」不重複列")
    }

    // MARK: 依照片產生的搜尋建議

    func testSuggestionsFromPhotos() {
        let suggestions = SearchSuggestionBuilder.build(
            categories: [("拉麵", 40), ("夜景", 25), ("貓", 60), ("小卡", 12), ("很少", 1)],
            places: ["東京都", "臺北市"], now: now, calendar: calendar)
        XCTAssertEqual(suggestions, ["上個月的貓", "東京都的拉麵", "夜景", "去年秋天的小卡", "臺北市", "貓"])
        XCTAssertFalse(suggestions.contains { $0.contains("很少") }, "太少照片的分類不當建議")

        // 產生的句子搜尋看得懂：時間、地點拆得出來，剩下的是分類名稱
        let first = parse(suggestions[0])
        XCTAssertEqual(first.text, "貓")
        XCTAssertEqual(first.dateRange?.label, "上個月")
        let second = parse(suggestions[1])
        XCTAssertEqual(second.text, "拉麵")
        XCTAssertEqual(second.place, .region(name: "東京都"))
        XCTAssertEqual(parse(suggestions[3]).text, "小卡")
        XCTAssertEqual(parse(suggestions[3]).dateRange?.label, "去年秋天")
    }

    func testSuggestionsFallbackWithoutCategories() {
        let suggestions = SearchSuggestionBuilder.build(categories: [], places: ["京都府"], now: now, calendar: calendar)
        XCTAssertEqual(suggestions.first, "京都府")
        XCTAssertEqual(suggestions.count, 6)
    }

    /// 搜尋「桃園市」：只留下在桃園拍的照片，地點選單不再出現其他地區
    func testQueryPlace() {
        let facts: [String: PhotoSearchFacts] = [
            "a": PhotoSearchFacts(date: nil, region: "桃園市", country: "台灣", countryCode: "TW"),
            "b": PhotoSearchFacts(date: nil, region: "臺北市", country: "台灣", countryCode: "TW"),
            "c": PhotoSearchFacts(date: nil, region: "新北市", country: "台灣", countryCode: "TW"),
            "d": PhotoSearchFacts(date: nil, region: "東京都", country: "日本", countryCode: "JP"),
        ]
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(SearchFacets.queryPlace("桃園市", ids: ids, facts: facts), .region(name: "桃園市"))
        XCTAssertEqual(SearchFacets.queryPlace("桃園 夜景", ids: ids, facts: facts), .region(name: "桃園市"))
        XCTAssertEqual(SearchFacets.queryPlace("台北", ids: ids, facts: facts), .region(name: "臺北市"))
        XCTAssertEqual(SearchFacets.queryPlace("新北市", ids: ids, facts: facts), .region(name: "新北市"))
        XCTAssertEqual(SearchFacets.queryPlace("東京", ids: ids, facts: facts), .region(name: "東京都"))
        XCTAssertEqual(SearchFacets.queryPlace("日本", ids: ids, facts: facts), .country(code: "JP", name: "日本"))
        XCTAssertNil(SearchFacets.queryPlace("貓", ids: ids, facts: facts))
        XCTAssertNil(SearchFacets.queryPlace("高雄", ids: ids, facts: facts), "結果裡沒有的地區不篩")
    }

    func testVectorSearchHidesResultsWhenNothingStandsOut() {
        // 相簿裡沒有的東西：分數都差不多（最高 0.23），沒有照片突出 → 不列出
        var flat: [(id: String, score: Float)] = (0..<500).map { ("p\($0)", 0.17 + Float($0 % 25) * 0.0025) }
        flat.append(("q", 0.23))
        XCTAssertTrue(VectorSearchCutoff.filter(flat).isEmpty)

        // 相簿裡有：幾張照片明顯比其他高 → 只留下那幾張
        var present: [(id: String, score: Float)] = (0..<500).map { ("p\($0)", 0.17 + Float($0 % 25) * 0.001) }
        present += [("cat1", 0.30), ("cat2", 0.29), ("cat3", 0.28)]
        XCTAssertEqual(VectorSearchCutoff.filter(present).map(\.id), ["cat1", "cat2", "cat3"])

        // 相簿裡很多照片都符合（分數普遍偏高、沒有單張突出）：分數夠高的照常列出
        var common: [(id: String, score: Float)] = (0..<300).map { ("x\($0)", 0.15 + Float($0 % 10) * 0.002) }
        common += (0..<300).map { ("food\($0)", 0.26 + Float($0 % 5) * 0.004) }
        XCTAssertEqual(VectorSearchCutoff.filter(common).count, 300)

        // 照片很少：用固定門檻
        XCTAssertEqual(VectorSearchCutoff.filter([("a", 0.25), ("b", 0.22)]).map(\.id), ["a"])
    }

    func testChineseQueriesNeedTranslation() {
        XCTAssertTrue(SearchQueryLanguage.needsTranslation("海邊的夕陽"))
        XCTAssertTrue(SearchQueryLanguage.needsTranslation("ラーメン"))
        XCTAssertTrue(SearchQueryLanguage.needsTranslation("치킨"))
        XCTAssertFalse(SearchQueryLanguage.needsTranslation("a cat on the sofa"))
        let catalog = TaxonomyCatalog.builtIn
        XCTAssertNotNil(SearchQueryLanguage.dictionaryEnglish("睡覺的貓", catalog: catalog))
        XCTAssertNotNil(SearchQueryLanguage.dictionaryEnglish("壽司", catalog: catalog), "「壽司與生魚片」拆開比對")
        XCTAssertNil(SearchQueryLanguage.dictionaryEnglish("花蓮", catalog: catalog), "地名裡的「花」不算花")
        XCTAssertNil(SearchQueryLanguage.dictionaryEnglish("火星上的企鵝", catalog: catalog))
    }

    func testSmartSearchResultsMustBePlausible() {
        // 相簿 500 張，分數大多 0.15～0.19；智慧搜尋找到 a（明顯較像）和 b（和平均差不多）
        var scores: [(id: String, score: Float)] = (0..<500).map { ("p\($0)", 0.15 + Float($0 % 20) * 0.002) }
        scores += [("a", 0.26), ("b", 0.17)]
        XCTAssertEqual(VectorSearchCutoff.plausible(["a", "b"], among: scores), ["a"])
        XCTAssertTrue(VectorSearchCutoff.plausible([], among: scores).isEmpty)
    }
}

import XCTest
@testable import PersonalizationCore

/// 追星足跡：場次依年份整理、票券補上演出名稱與座位、照片文字上的日期。
final class FandomFootprintTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func startOfDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.startOfDay(for: day(y, m, d))
    }

    // MARK: 日期

    func testReadsDatesWithAndWithoutYear() {
        let text = """
        使用期限：2026/12/31
        活動時間 115年11月20日
        11月5日 開賣
        兌換日期 1/10
        比數 3/2
        """
        let dates = TextDateReader.dates(in: text, reference: day(2026, 10, 1), calendar: calendar).map(\.date)
        XCTAssertTrue(dates.contains(startOfDay(2026, 12, 31)))
        XCTAssertTrue(dates.contains(startOfDay(2026, 11, 20)), "民國年")
        XCTAssertTrue(dates.contains(startOfDay(2026, 11, 5)), "沒有年份：今年")
        XCTAssertTrue(dates.contains(startOfDay(2027, 1, 10)), "沒有年份、已經過了：明年")
        XCTAssertFalse(dates.contains(startOfDay(2027, 3, 2)), "沒有日期相關的字，「3/2」不算日期")
        XCTAssertEqual(dates.filter { $0 == startOfDay(2026, 12, 31) }.count, 1, "同一個日期不重複算")
    }

    func testInvalidDatesAreIgnored() {
        let dates = TextDateReader.dates(in: "日期 2026/2/30、2026/13/01", reference: day(2026, 1, 1), calendar: calendar)
        XCTAssertTrue(dates.isEmpty)
    }

    // MARK: 票券

    func testReadsConcertTicket() {
        let text = """
        tixCraft 拓元售票
        活動名稱：ABC 2026 WORLD TOUR IN TAIPEI
        演出日期 2026/11/15 19:30
        特A區 12排 5號
        票價 NT$4,800
        """
        XCTAssertTrue(ConcertTicketReader.looksLikeTicket(PhotoTextHints.normalize(text)))
        let info = ConcertTicketReader.read(text, reference: day(2026, 6, 1), calendar: calendar)
        XCTAssertEqual(info.title, "ABC 2026 WORLD TOUR IN TAIPEI")
        XCTAssertEqual(info.seat, "特A區 12排 5號")
        XCTAssertEqual(info.dates, [startOfDay(2026, 11, 15)])
    }

    func testMovieTicketIsNotConcertTicket() {
        let movie = PhotoTextHints.normalize("威秀影城 放映日期 2026/11/15 影廳 7 座位 F12 票價 330")
        XCTAssertFalse(ConcertTicketReader.looksLikeTicket(movie))
    }

    func testEntryNumberCountsAsSeat() {
        let info = ConcertTicketReader.read("XYZ LIVE TOUR\n入場序號：128\n門票", reference: day(2026, 1, 1), calendar: calendar)
        XCTAssertEqual(info.seat, "入場序號:128", "全形冒號會轉成半形")
        XCTAssertEqual(info.title, "XYZ LIVE TOUR")
    }

    // MARK: 追星足跡

    private func show(_ id: String, _ date: Date, venue: String?, city: String?, assets: [String] = []) -> FandomShow {
        FandomShow(id: id, date: date, kindNodeId: "concert", venue: venue, city: city,
                   latitude: nil, longitude: nil, coverAssetId: assets.first ?? id, assetIds: assets.isEmpty ? [id] : assets)
    }

    func testYearSummaryCountsVenuesAndCities() {
        let shows = [
            show("live-a", day(2026, 3, 1, hour: 20), venue: "臺北小巨蛋", city: "臺北市"),
            show("live-b", day(2026, 8, 9, hour: 20), venue: "臺北小巨蛋", city: "臺北市"),
            show("live-c", day(2026, 9, 20, hour: 19), venue: "高雄巨蛋", city: "高雄市"),
            show("live-d", day(2026, 10, 2, hour: 19), venue: nil, city: nil),
            show("live-e", day(2025, 12, 24, hour: 19), venue: "東京巨蛋", city: "東京都"),
        ]
        XCTAssertEqual(FandomFootprint.years(of: shows, calendar: calendar), [2026, 2025])
        let summary = FandomFootprint.summary(year: 2026, shows: shows, calendar: calendar)
        XCTAssertEqual(summary.showCount, 4)
        XCTAssertEqual(summary.shows.first?.id, "live-d", "新到舊")
        XCTAssertEqual(summary.venues, [NamedCount(name: "臺北小巨蛋", count: 2), NamedCount(name: "高雄巨蛋", count: 1)])
        XCTAssertEqual(summary.cities.map(\.name), ["臺北市", "高雄市"])
    }

    func testTicketsAttachByShowPhotosOrByDate() {
        let shows = [
            show("live-a", day(2026, 11, 15, hour: 20), venue: "臺北小巨蛋", city: "臺北市", assets: ["stage1", "stub"]),
            show("live-b", day(2026, 12, 6, hour: 19), venue: "高雄巨蛋", city: "高雄市", assets: ["stage2"]),
            show("live-c", day(2026, 12, 20, hour: 19), venue: nil, city: nil, assets: ["stage3"]),
        ]
        let texts = [
            "stub": "ABC WORLD TOUR\n門票 入場\n2026/11/15\n特A區 12排 5號",
            "eticket": "KKTIX 電子票券\nDEF 演唱會 IN KAOHSIUNG\n12月6日 18:00 入場\nROW C SEAT 12",
            "chat": "明天要不要吃火鍋",
        ]
        let result = FandomFootprint.attachTickets(to: shows, texts: texts, calendar: calendar)
        XCTAssertEqual(result[0].title, "ABC WORLD TOUR")
        XCTAssertEqual(result[0].seat, "特A區 12排 5號")
        XCTAssertEqual(result[0].ticketAssetId, "stub", "同一場拍到的票根")
        XCTAssertEqual(result[1].title, "DEF 演唱會 IN KAOHSIUNG")
        XCTAssertEqual(result[1].seat, "ROW C SEAT 12")
        XCTAssertEqual(result[1].ticketAssetId, "eticket", "不在同一場，但票上的日期是演出當天")
        XCTAssertNil(result[2].ticketAssetId)
    }

    func testPhotoTextQueries() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "fan@example.com", displayName: nil)
        try TestDatabase.insertPhoto(store.db, assetId: "coupon", owner: userId)
        try TestDatabase.insertPhoto(store.db, assetId: "chat", owner: userId)
        try store.savePhotoText(assetId: "coupon", text: "優惠券\n使用期限 2026/11/30")
        try store.savePhotoText(assetId: "chat", text: "晚餐吃什麼")
        XCTAssertEqual(Array(try store.photoTexts(containingAny: ["使用期限", "100%"]).keys), ["coupon"])
        XCTAssertEqual(try store.photoTexts(assetIds: ["coupon", "chat", "none"]).count, 2)
        XCTAssertEqual(try store.photoTexts(assetIds: ["coupon"])["coupon"], "優惠券\n使用期限 2026/11/30", "保留換行")
    }
}

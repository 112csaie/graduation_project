import XCTest
@testable import PersonalizationCore

/// Time & Place：旅遊相簿偵測。情境：住桃園、在長庚大學上課、在台北打工的學生。
final class TripDetectorTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private let taoyuan = GeoRegion(name: "桃園市", country: "台灣", countryCode: "TW")
    private let taipei = GeoRegion(name: "臺北市", country: "台灣", countryCode: "TW")
    private let taichung = GeoRegion(name: "臺中市", country: "台灣", countryCode: "TW")
    private let tokyo = GeoRegion(name: "東京都", country: "日本", countryCode: "JP")
    private let kanagawa = GeoRegion(name: "神奈川縣", country: "日本", countryCode: "JP")

    private let home = (lat: 25.0100, lon: 121.3000)        // 住家（桃園）
    private let school = (lat: 25.0330, lon: 121.3890)      // 學校（長庚大學）
    private let job = (lat: 25.0420, lon: 121.5600)         // 打工（台北）
    private let tokyoPoint = (lat: 35.6800, lon: 139.7600)
    private let yokohama = (lat: 35.4440, lon: 139.6380)
    private let taichungPoint = (lat: 24.1500, lon: 120.6700)

    private var counter = 0

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func photo(_ date: Date, _ point: (lat: Double, lon: Double)?, _ region: GeoRegion?, screenshot: Bool = false) -> GeoPhoto {
        counter += 1
        return GeoPhoto(id: "p\(counter)", date: date, latitude: point?.lat, longitude: point?.lon,
                        region: region, isScreenshot: screenshot)
    }

    /// 一整年的日常：住家（晚上）、學校（平日）、打工（週末），每週都有照片。
    /// - Parameter away: 出門旅行的日期（這些天不產生日常照片）。
    private func routineYear(_ year: Int = 2026, away: [(Date, Int)] = []) -> [GeoPhoto] {
        let awayDays = Set(away.flatMap { start, days in
            (0..<days).map { calendar.startOfDay(for: calendar.date(byAdding: .day, value: $0, to: start)!) }
        })
        var photos: [GeoPhoto] = []
        var day = date(year, 1, 5)
        let end = date(year, 12, 20)
        while day < end {
            if awayDays.contains(calendar.startOfDay(for: day)) {
                day = calendar.date(byAdding: .day, value: 1, to: day)!
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            photos.append(photo(day.addingTimeInterval(9 * 3600), home, taoyuan))                 // 每天晚上在家
            if (2...6).contains(weekday), weekday % 2 == 0 {
                photos.append(photo(day.addingTimeInterval(2 * 3600), school, taoyuan))           // 平日在學校
            }
            if weekday == 7 {
                photos.append(photo(day.addingTimeInterval(4 * 3600), job, taipei))               // 週六打工
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return photos
    }

    private func trip(from start: Date, days: Int, perDay: Int, at point: (lat: Double, lon: Double), _ region: GeoRegion) -> [GeoPhoto] {
        var photos: [GeoPhoto] = []
        for d in 0..<days {
            for i in 0..<perDay {
                let t = calendar.date(byAdding: .day, value: d, to: start)!.addingTimeInterval(Double(i) * 1800)
                photos.append(photo(t, (point.lat + Double(i) * 0.002, point.lon), region))
            }
        }
        return photos
    }

    // MARK: -

    func testHomeSchoolAndWorkAreDetectedAsRoutineAndNeverBecomeTrips() {
        let result = TripDetector.detect(photos: routineYear(), calendar: calendar)
        XCTAssertFalse(result.insufficientHistory)
        XCTAssertGreaterThanOrEqual(result.anchors.count, 3, "住家、學校、打工地點都應被辨識為常去地點")
        XCTAssertEqual(result.homeRegion?.name, "桃園市")
        XCTAssertTrue(result.trips.isEmpty, "只有日常照片時不應產生任何旅遊相簿")
    }

    func testTokyoTripBecomesOneAlbumWithoutHomePhotos() {
        let routine = routineYear(away: [(date(2026, 8, 22), 4)])
        let tokyoPhotos = trip(from: date(2026, 8, 22, 10), days: 4, perDay: 8, at: tokyoPoint, tokyo)
        let result = TripDetector.detect(photos: routine + tokyoPhotos, calendar: calendar)

        XCTAssertEqual(result.trips.count, 1)
        let detected = result.trips[0]
        XCTAssertEqual(detected.title, "東京")
        XCTAssertEqual(detected.country, "日本")
        XCTAssertEqual(detected.dayCount, 4)
        XCTAssertEqual(Set(detected.primaryAssetIds), Set(tokyoPhotos.map(\.id)), "只包含東京的照片，不含住家、學校、公司")
        XCTAssertEqual(calendar.component(.day, from: detected.startDate), 22)
        XCTAssertEqual(calendar.component(.day, from: detected.endDate), 25)
    }

    func testRepeatTripsToSameCityAreSeparateAlbumsAndNotMistakenForHome() {
        var photos = routineYear(away: [(date(2026, 3, 10), 4), (date(2026, 8, 22), 4), (date(2026, 12, 1), 3)])
        photos += trip(from: date(2026, 3, 10, 10), days: 4, perDay: 6, at: tokyoPoint, tokyo)
        photos += trip(from: date(2026, 8, 22, 10), days: 4, perDay: 6, at: tokyoPoint, tokyo)
        photos += trip(from: date(2026, 12, 1, 10), days: 3, perDay: 6, at: tokyoPoint, tokyo)
        let result = TripDetector.detect(photos: photos, calendar: calendar)
        XCTAssertEqual(result.trips.count, 3, "去了三次東京 → 三本相簿；東京不會被當成常去地點")
        XCTAssertTrue(result.trips.allSatisfy { $0.title == "東京" })
    }

    func testMultiRegionTripNamesFirstLevelRegions() {
        var photos = routineYear(away: [(date(2026, 8, 22), 4)])
        photos += trip(from: date(2026, 8, 22, 10), days: 3, perDay: 8, at: tokyoPoint, tokyo)
        photos += trip(from: date(2026, 8, 25, 10), days: 1, perDay: 4, at: yokohama, kanagawa)
        let result = TripDetector.detect(photos: photos, calendar: calendar)
        XCTAssertEqual(result.trips.count, 1)
        XCTAssertEqual(result.trips[0].title, "東京、神奈川", "地區只到第一級行政區")
    }

    func testBigDayTripCountsButSmallOutingDoesNot() {
        var photos = routineYear(away: [(date(2026, 5, 2), 1), (date(2026, 6, 6), 1)])
        photos += trip(from: date(2026, 5, 2, 9), days: 1, perDay: 20, at: taichungPoint, taichung)     // 台中一日遊 20 張
        photos += trip(from: date(2026, 6, 6, 14), days: 1, perDay: 5, at: taichungPoint, taichung)     // 只拍 5 張
        let result = TripDetector.detect(photos: photos, calendar: calendar)
        XCTAssertEqual(result.trips.count, 1)
        XCTAssertEqual(result.trips[0].title, "臺中")
    }

    func testReturningHomeSplitsTrips() {
        // 7/3 在家（有住家照片），其餘旅行日沒有日常照片
        var photos = routineYear(away: [(date(2026, 7, 1), 2), (date(2026, 7, 4), 2)])
        photos += trip(from: date(2026, 7, 1, 10), days: 2, perDay: 6, at: tokyoPoint, tokyo)
        // 7/3 回到住家（routineYear 每天晚上都有住家照片），7/4 再出發
        photos += trip(from: date(2026, 7, 4, 10), days: 2, perDay: 6, at: tokyoPoint, tokyo)
        let result = TripDetector.detect(photos: photos, calendar: calendar)
        XCTAssertEqual(result.trips.count, 2, "中間回到常去地點就切成兩趟")
    }

    func testScreenshotsExcludedAndUnlocatedPhotosOnlyWithinTrip() {
        var photos = routineYear(away: [(date(2026, 8, 22), 4)])
        let tokyoPhotos = trip(from: date(2026, 8, 22, 10), days: 4, perDay: 8, at: tokyoPoint, tokyo)
        photos += tokyoPhotos
        let unlocatedDuring = photo(date(2026, 8, 23, 15), nil, nil)
        let screenshotDuring = photo(date(2026, 8, 23, 16), nil, nil, screenshot: true)
        let unlocatedBefore = photo(date(2026, 8, 21, 20), nil, nil)
        photos += [unlocatedDuring, screenshotDuring, unlocatedBefore]

        let detected = TripDetector.detect(photos: photos, calendar: calendar).trips[0]
        XCTAssertEqual(detected.otherAssetIds, [unlocatedDuring.id])
        XCTAssertFalse(detected.allAssetIds.contains(screenshotDuring.id), "螢幕截圖不放進旅遊相簿")
        XCTAssertFalse(detected.allAssetIds.contains(unlocatedBefore.id), "出發前的照片不放進旅遊相簿")
    }

    func testLongStayIsNotATrip() {
        var photos = routineYear(2025)
        // 2026 年去東京交換一個學期（每天都有照片，超過 30 天）
        photos += trip(from: date(2026, 2, 1, 10), days: 60, perDay: 2, at: tokyoPoint, tokyo)
        let result = TripDetector.detect(photos: photos, calendar: calendar)
        XCTAssertTrue(result.trips.allSatisfy { $0.dayCount <= 30 }, "長住（交換、搬家）不產生旅遊相簿")
    }

    func testInsufficientHistoryProducesNoTrips() {
        let onlyTrip = trip(from: date(2026, 8, 22, 10), days: 4, perDay: 8, at: tokyoPoint, tokyo)
        let result = TripDetector.detect(photos: onlyTrip, calendar: calendar)
        XCTAssertTrue(result.insufficientHistory, "只有旅行照片時無法判斷住家，旅行地點也不能被當成住家")
        XCTAssertTrue(result.trips.isEmpty)
    }

    func testRegionShortNames() {
        XCTAssertEqual(RegionNaming.shortName("東京都"), "東京")
        XCTAssertEqual(RegionNaming.shortName("首爾特別市"), "首爾")
        XCTAssertEqual(RegionNaming.shortName("釜山廣域市"), "釜山")
        XCTAssertEqual(RegionNaming.shortName("高雄市"), "高雄")
        XCTAssertEqual(RegionNaming.shortName("京都府"), "京都")
        XCTAssertEqual(RegionNaming.shortName("沖繩縣"), "沖繩")
        XCTAssertEqual(RegionNaming.shortName("北海道"), "北海道")
        XCTAssertEqual(RegionNaming.shortName("香港"), "香港")
        XCTAssertEqual(RegionNaming.gridKey(latitude: 35.681, longitude: 139.767), RegionNaming.gridKey(latitude: 35.689, longitude: 139.761))
    }

    // MARK: 標題規則

    private func titled(_ regions: [(String, String, String, Int)], home: String? = "TW") -> String? {
        DetectedTrip(id: "t", startDate: Date(), endDate: Date(), primaryAssetIds: ["a"], otherAssetIds: [],
                     regions: regions.map { RegionCount(region: GeoRegion(name: $0.0, country: $0.1, countryCode: $0.2), count: $0.3) },
                     dayCount: 2, maxDistanceKm: 100, homeCountryCode: home).title
    }

    func testSameShortNameIsMergedNotRepeated() {
        XCTAssertEqual(titled([("嘉義市", "台灣", "TW", 30), ("嘉義縣", "台灣", "TW", 12)]), "嘉義")
    }

    func testCountryOnlyFallbackIsNotListedNextToItsRegions() {
        XCTAssertEqual(titled([("曼谷", "泰國", "TH", 50), ("泰國", "泰國", "TH", 10), ("北欖府", "泰國", "TH", 8),
                               ("桃園市", "台灣", "TW", 3)]), "曼谷、北欖", "不會出現「泰國、曼谷」，機場零星照片略過")
        XCTAssertEqual(titled([("泰國", "泰國", "TH", 10)]), "泰國")
    }

    func testAbroadManyRegionsUsesCountryName() {
        XCTAssertEqual(titled([("京都府", "日本", "JP", 20), ("大阪府", "日本", "JP", 15), ("奈良縣", "日本", "JP", 8)]), "日本")
        XCTAssertEqual(titled([("首爾特別市", "南韓", "KR", 30), ("東京都", "日本", "JP", 20)]), "南韓、日本")
    }

    func testDomesticManyRegionsListsTwoAndMore() {
        XCTAssertEqual(titled([("花蓮縣", "台灣", "TW", 20), ("臺東縣", "台灣", "TW", 15), ("屏東縣", "台灣", "TW", 10)]), "花蓮、臺東等地")
    }
}

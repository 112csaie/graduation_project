import XCTest
@testable import PersonalizationCore

/// 興趣紀錄（健身日曆、觀影與看展…）：要算哪些分類、顯示哪些紀錄、日曆天數與連續週數。
final class InterestTrackerTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        calendar.firstWeekday = 2   // 週一開始
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private var sports: InterestTracker { InterestTrackers.tracker(forInterest: "sports_outdoor")! }

    func testTrackersAreValid() {
        XCTAssertEqual(InterestTrackers.validationErrors(), [])
        for interest in TaxonomyCatalog.builtIn.interests where interest.id != "general" {
            XCTAssertNotNil(InterestTrackers.tracker(forInterest: interest.id), "每個興趣都有對應的紀錄：\(interest.id)")
        }
        XCTAssertEqual(TaxonomyCatalog.builtIn.node("weight_training")?.parentId, "gym")
        XCTAssertEqual(TaxonomyCatalog.builtIn.topLevelId(of: "body_composition"), "sports_outdoor")
    }

    func testSelectedInterestsDecideTrackers() {
        let trackers = InterestTrackers.trackers(selectedInterestIds: ["film_arts", "sports_outdoor", "general"], photoCounts: [:])
        XCTAssertEqual(trackers.map(\.id), ["sports_outdoor", "film_arts"], "依興趣的目錄順序")
    }

    func testWithoutInterestsUsesCategoriesWithMostPhotos() {
        let counts = ["pets": 50, "meals": 10, "outdoor": 0]
        XCTAssertEqual(InterestTrackers.trackers(selectedInterestIds: [], photoCounts: counts).map(\.id),
                       ["pets_animals", "food_cafe"])
        XCTAssertEqual(InterestTrackers.trackers(selectedInterestIds: ["general"], photoCounts: counts).map(\.id),
                       ["pets_animals", "food_cafe"], "只選「一般」等於沒選")
        XCTAssertTrue(InterestTrackers.trackers(selectedInterestIds: [], photoCounts: [:]).isEmpty)
    }

    func testTrackerPhotosIncludeSubcategoriesAndFlagBodyPhotos() {
        let tagMap: [String: Set<String>] = [
            "lift": ["weight_training"],
            "inbody": ["body_composition"],
            "run": ["running"],
            "cat": ["cat"],
        ]
        XCTAssertEqual(InterestTrackers.assetIds(tagMap: tagMap, tracker: sports), ["lift", "inbody", "run"])
        XCTAssertEqual(InterestTrackers.sensitiveAssetIds(tagMap: tagMap, tracker: sports), ["inbody"])
        let film = InterestTrackers.tracker(forInterest: "film_arts")!
        XCTAssertTrue(InterestTrackers.sensitiveAssetIds(tagMap: tagMap, tracker: film).isEmpty)
    }

    /// 有拍到不代表做了這件事：看球賽不算去運動、在家拍專輯不算看演出、證件不算學習
    func testTrackersExcludeNonActivityCategories() {
        let tagMap: [String: Set<String>] = [
            "game": ["sports_game"], "gear": ["sports_gear"], "ball": ["ball_sports"],
            "album": ["merch"], "live": ["concert"], "id": ["id_card"], "notes": ["handwritten_notes"],
        ]
        XCTAssertEqual(InterestTrackers.assetIds(tagMap: tagMap, tracker: sports), ["ball"])
        let music = InterestTrackers.tracker(forInterest: "music_live")!
        XCTAssertEqual(InterestTrackers.assetIds(tagMap: tagMap, tracker: music), ["live"])
        let study = InterestTrackers.tracker(forInterest: "study_work")!
        XCTAssertEqual(InterestTrackers.assetIds(tagMap: tagMap, tracker: study), ["notes"])
        XCTAssertTrue(InterestTrackers.tracker(forInterest: "cafe_hopping")!.skipsRoutinePlaces)
    }

    /// 觀影與看展只算出門去看的照片：課本、書、海報不算
    func testFilmTrackerOnlyCountsOutings() {
        let film = InterestTrackers.tracker(forInterest: "film_arts")!
        let tagMap: [String: Set<String>] = [
            "ticket": ["movie"], "cinema": ["movie"], "museum": ["museum"],
            "textbook": ["textbook"], "novel": ["books"], "poster": ["poster"],
        ]
        XCTAssertEqual(InterestTrackers.assetIds(tagMap: tagMap, tracker: film), ["ticket", "cinema", "museum"])
        let study = InterestTrackers.tracker(forInterest: "study_work")!
        XCTAssertEqual(InterestTrackers.assetIds(tagMap: tagMap, tracker: study), ["textbook"], "課本算在學習日曆")
    }

    func testCalendarCountsDaysNotPhotos() {
        let photos: [String: Date] = [
            "a2": date(10, 1, 18), "a1": date(10, 1, 9), "b": date(10, 3), "c": date(10, 20), "old": date(9, 30),
        ]
        let activity = ActivityCalendar(photoDates: photos, calendar: calendar)
        XCTAssertEqual(activity.activeDays(inMonthOf: date(10, 15)).count, 3, "同一天兩張照片只算一天")
        XCTAssertEqual(activity.assetIds(inMonthOf: date(10, 15)), ["a1", "a2", "b", "c"], "依拍攝時間排序")
        XCTAssertEqual(activity.months.map { calendar.component(.month, from: $0) }, [10, 9])
    }

    func testWeekStreak() {
        var photos: [String: Date] = ["w1": date(9, 30), "w4": date(10, 20)]
        XCTAssertEqual(ActivityCalendar(photoDates: photos, calendar: calendar).weekStreak(asOf: date(10, 21)), 1,
                       "中間有一週沒紀錄就中斷")

        photos["w2"] = date(10, 7)
        photos["w3"] = date(10, 14)
        let activity = ActivityCalendar(photoDates: photos, calendar: calendar)
        XCTAssertEqual(activity.weekStreak(asOf: date(10, 21)), 4)
        XCTAssertEqual(activity.weekStreak(asOf: date(10, 26)), 4, "本週還沒紀錄時從上週算，週一不會歸零")
        XCTAssertEqual(activity.weekStreak(asOf: date(11, 9)), 0)
    }

    func testSummaryAndReportTitle() {
        XCTAssertEqual(sports.summary(month: 10, days: 12), "10 月有 12 天去運動")
        XCTAssertEqual(sports.summary(month: 10, days: 0), "10 月還沒有紀錄")
        XCTAssertEqual(sports.reportTitle(month: 10), "10月健身月報")
        for tracker in InterestTrackers.builtIn {
            XCTAssertLessThanOrEqual(tracker.reportTitle(month: 12).count, 10, "筆記標題上限 10 個字：\(tracker.id)")
        }
    }

    /// 探店不算住家、學校附近；旅行足跡改用旅程
    func testFoodSkipsRoutinePlacesAndTravelUsesTrips() {
        XCTAssertTrue(InterestTrackers.tracker(forInterest: "food_cafe")!.skipsRoutinePlaces)
        XCTAssertTrue(InterestTrackers.tracker(forInterest: "travel_photo")!.usesTrips)

        // 長庚大學附近當作常去地點
        let school = PlaceAnchor(latitude: 25.0335, longitude: 121.3896, distinctDays: 80, distinctWeeks: 30, visits: 60, isFallback: false)
        XCTAssertTrue(RoutinePlaces.isNear(latitude: 25.0340, longitude: 121.3905, anchors: [school]), "學餐（幾百公尺內）")
        XCTAssertFalse(RoutinePlaces.isNear(latitude: 25.0478, longitude: 121.5170, anchors: [school]), "台北車站附近的餐廳")
        XCTAssertFalse(RoutinePlaces.isNear(latitude: 25.0340, longitude: 121.3905, anchors: []), "還沒有常去地點時都算")
    }
}

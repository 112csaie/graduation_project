import XCTest
@testable import PersonalizationCore

/// 演唱會依場次整理：同一個晚上、同一個場館。
final class LiveEventDetectorTests: XCTestCase {

    private let venue = (lat: 25.0514, lon: 121.5497)     // 場館
    private let home = (lat: 25.0330, lon: 121.5654)      // 約 2.6 公里外
    private let night = Date(timeIntervalSince1970: 1_786_788_000)   // 某天 19:00（台北）

    private func photo(_ id: String, minutes: Double, at place: (lat: Double, lon: Double)?,
                       seed: String? = nil, score: Float = 0.25, screenshot: Bool = false, base: Date? = nil) -> EventPhoto {
        EventPhoto(id: id, date: (base ?? night).addingTimeInterval(minutes * 60),
                   latitude: place?.lat, longitude: place?.lon, isScreenshot: screenshot,
                   seedNodeId: seed, seedScore: seed == nil ? 0 : score)
    }

    func testOneNightAtOneVenueBecomesOneEvent() {
        var photos: [EventPhoto] = []
        photos.append(photo("queue1", minutes: -60, at: venue))                       // 排隊
        photos.append(photo("queue2", minutes: -50, at: venue))
        photos.append(photo("merch", minutes: -40, at: venue))                        // 周邊攤位
        for i in 0..<5 { photos.append(photo("stage\(i)", minutes: Double(i) * 30, at: venue, seed: "concert", score: 0.24 + Float(i) * 0.01)) }
        photos.append(photo("stick", minutes: 45, at: venue, seed: "cheering_goods"))
        photos.append(photo("noGPS", minutes: 70, at: nil))                           // 沒有定位，演出期間
        photos.append(photo("ticket", minutes: 20, at: nil, screenshot: true))        // 截圖不收
        photos.append(photo("homeLate", minutes: 240, at: home))                      // 回家後
        photos.append(photo("dinnerFar", minutes: -100, at: home))                    // 開演前在別處

        let events = LiveEventDetector.detect(photos: photos)
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(Set(event.assetIds),
                       Set(["queue1", "queue2", "merch", "stage0", "stage1", "stage2", "stage3", "stage4", "stick", "noGPS"]))
        XCTAssertEqual(event.kindNodeId, "concert")
        XCTAssertEqual(event.coverAssetId, "stage4", "封面用最像演唱會的照片")
        XCTAssertEqual(event.id, "live-stage0")
        XCTAssertEqual(event.latitude ?? 0, venue.lat, accuracy: 1e-6)
    }

    func testCheeringGoodsAloneIsNotAConcert() {
        let photos = (0..<6).map { photo("stick\($0)", minutes: Double($0) * 10, at: home, seed: "cheering_goods") }
        XCTAssertTrue(LiveEventDetector.detect(photos: photos).isEmpty, "在家拍手燈不算一場")
    }

    func testTooFewSeedsIsNotAnEvent() {
        let photos = [photo("s0", minutes: 0, at: venue, seed: "concert"),
                      photo("s1", minutes: 20, at: venue, seed: "concert"),
                      photo("x", minutes: 30, at: venue)]
        XCTAssertTrue(LiveEventDetector.detect(photos: photos).isEmpty)
    }

    func testTwoNightsAreTwoEventsNewestFirst() {
        let nextNight = night.addingTimeInterval(86_400)
        var photos: [EventPhoto] = []
        for i in 0..<3 { photos.append(photo("a\(i)", minutes: Double(i) * 30, at: venue, seed: "concert")) }
        for i in 0..<3 { photos.append(photo("b\(i)", minutes: Double(i) * 30, at: venue, seed: "concert", base: nextNight)) }
        let events = LiveEventDetector.detect(photos: photos)
        XCTAssertEqual(events.map(\.id), ["live-b0", "live-a0"])
    }

    func testDifferentVenuesSameEveningAreSeparated() {
        let other = (lat: 25.0800, lon: 121.5700)   // 約 3.7 公里外
        var photos: [EventPhoto] = []
        for i in 0..<3 { photos.append(photo("v\(i)", minutes: Double(i) * 20, at: venue, seed: "concert")) }
        for i in 0..<3 { photos.append(photo("w\(i)", minutes: 70 + Double(i) * 20, at: other, seed: "theater_show")) }
        let events = LiveEventDetector.detect(photos: photos)
        XCTAssertEqual(Set(events.map(\.kindNodeId)), ["concert", "theater_show"])
        XCTAssertEqual(events.count, 2)
    }

    func testSeedScoring() {
        let dims = 8
        func axis(_ i: Int) -> [Float] { var v = [Float](repeating: 0, count: dims); v[i] = 1; return v }
        let prompts: [String: [[Float]]] = ["concert": [axis(0)], "night_view": [axis(1)], "cat": [axis(2)]]
        // 最像演唱會
        let stage = MultiLabelTagger.normalized([0.5, 0.3, 0, 0, 0, 0, 0, 0.8])
        XCTAssertEqual(LiveEventDetector.seed(for: stage, prompts: prompts)?.nodeId, "concert")
        // 演唱會分數夠高，但明顯比較像夜景 → 不算
        let nightView = MultiLabelTagger.normalized([0.3, 0.6, 0, 0, 0, 0, 0, 0.7])
        XCTAssertNil(LiveEventDetector.seed(for: nightView, prompts: prompts))
        // 分數太低 → 不算
        let weak = MultiLabelTagger.normalized([0.1, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertNil(LiveEventDetector.seed(for: weak, prompts: prompts))
    }

    /// 主題樂園也整理成場次：同一天、同一個樂園（樂園很大，2 公里外的另一區也算同一次）
    func testThemeParkDayBecomesOneVisit() {
        let park = (lat: 35.6329, lon: 139.8804)
        let otherArea = (lat: 35.6260, lon: 139.8900)    // 同一個樂園的另一區，約 1.2 公里
        let morning = night.addingTimeInterval(-10 * 3600)
        var photos: [EventPhoto] = []
        photos.append(photo("gate", minutes: -20, at: park, base: morning))
        for i in 0..<4 {
            photos.append(photo("ride\(i)", minutes: Double(i) * 120, at: i % 2 == 0 ? park : otherArea,
                                seed: "theme_park", base: morning))
        }
        photos.append(photo("hotel", minutes: 900, at: home, base: morning))
        // 演唱會的規則不會把樂園照片當成一場
        XCTAssertTrue(LiveEventDetector.detect(photos: photos).isEmpty)
        let visits = LiveEventDetector.detect(photos: photos, profile: .themePark)
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.id, "park-ride0")
        XCTAssertEqual(visits.first?.kindNodeId, "theme_park")
        XCTAssertEqual(Set(visits.first?.assetIds ?? []), ["gate", "ride0", "ride1", "ride2", "ride3"])
        XCTAssertEqual(LiveEventProfile.profile(forEventId: "park-x"), .themePark)
        XCTAssertTrue(LiveEventDetector.allStageNodeIds.contains("theme_park"))
    }

    /// 截圖、存下來的別人照片：不能湊成一場，也不會被收進自己去的那一場
    func testScreenshotsAndSavedPhotosDoNotMakeOrJoinAnEvent() {
        // 晚上在家存了一堆別人拍的演唱會照片和截圖 → 不是一場
        var saved: [EventPhoto] = []
        for i in 0..<4 {
            var p = photo("saved\(i)", minutes: Double(i) * 10, at: nil, seed: "concert")
            p.isSaved = true
            saved.append(p)
        }
        for i in 0..<3 { saved.append(photo("shot\(i)", minutes: Double(i) * 10 + 5, at: nil, seed: "concert", screenshot: true)) }
        XCTAssertTrue(LiveEventDetector.detect(photos: saved).isEmpty)

        // 真的去了一場：自己拍的照片成立；演出期間存下來的照片不收進去
        var photos: [EventPhoto] = []
        for i in 0..<3 { photos.append(photo("stage\(i)", minutes: Double(i) * 30, at: venue, seed: "concert")) }
        var downloaded = photo("downloaded", minutes: 40, at: nil)
        downloaded.isSaved = true
        photos.append(downloaded)
        photos.append(photo("ownNoGPS", minutes: 50, at: nil))
        let events = LiveEventDetector.detect(photos: photos)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(Set(events.first?.assetIds ?? []), ["stage0", "stage1", "stage2", "ownNoGPS"])
    }

    func testSavedPhotoHeuristic() {
        // 社群存下來的：沒有定位、尺寸小
        XCTAssertTrue(PhotoOrigin.looksSaved(pixelWidth: 1080, pixelHeight: 1350, hasLocation: false, isLivePhoto: false, isScreenshot: false))
        // 相機拍的：尺寸大，或有定位，或是原況照片
        XCTAssertFalse(PhotoOrigin.looksSaved(pixelWidth: 4032, pixelHeight: 3024, hasLocation: false, isLivePhoto: false, isScreenshot: false))
        XCTAssertFalse(PhotoOrigin.looksSaved(pixelWidth: 1080, pixelHeight: 1350, hasLocation: true, isLivePhoto: false, isScreenshot: false))
        XCTAssertFalse(PhotoOrigin.looksSaved(pixelWidth: 1440, pixelHeight: 1080, hasLocation: false, isLivePhoto: true, isScreenshot: false))
        // 截圖另外處理
        XCTAssertFalse(PhotoOrigin.looksSaved(pixelWidth: 1290, pixelHeight: 2796, hasLocation: false, isLivePhoto: false, isScreenshot: true))
    }
}

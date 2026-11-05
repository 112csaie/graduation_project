import XCTest
@testable import PersonalizationCore

/// 想去清單：加入（同名不重複）、標記去過、刪除、到訪比對。
final class WishListStoreTests: XCTestCase {

    private var store: PersonalizationStore!
    private var userId: String!

    override func setUpWithError() throws {
        store = try TestDatabase.makeStore()
        userId = try store.resolveUser(email: "wish@example.com", displayName: nil)
    }

    override func tearDown() { store = nil }

    func testAddDedupesByName() throws {
        XCTAssertTrue(try store.addWishPlace(userId: userId, id: "p1", name: "鹿角咖啡", address: "台南市中西區", area: "台南",
                                             category: "咖啡廳", note: "巴斯克", latitude: 22.99, longitude: 120.2,
                                             sourceAssetId: "S1"))
        XCTAssertFalse(try store.addWishPlace(userId: userId, id: "p2", name: " 鹿角 咖啡", address: "", area: "",
                                              category: "其他", note: "", latitude: nil, longitude: nil, sourceAssetId: "S2"),
                       "同名（忽略空白）不重複加入")
        let other = try store.resolveUser(email: "other@example.com", displayName: nil)
        XCTAssertTrue(try store.addWishPlace(userId: other, id: "p3", name: "鹿角咖啡", address: "", area: "",
                                             category: "其他", note: "", latitude: nil, longitude: nil, sourceAssetId: nil),
                      "不同帳號各自一份清單")
        let places = try store.wishPlaces(userId: userId)
        XCTAssertEqual(places.map(\.name), ["鹿角咖啡"])
        XCTAssertEqual(places.first?.latitude ?? 0, 22.99, accuracy: 1e-9)
        XCTAssertEqual(places.first?.sourceAssetId, "S1")
    }

    /// 使用者編輯文字：改名、改地區後依新地區分組；改成已有的名稱時不改
    func testUpdatePlace() throws {
        try store.addWishPlace(userId: userId, id: "p1", name: "豆豆來", address: "春日路1434巷", area: "", category: "餐廳",
                               note: "", latitude: nil, longitude: nil, sourceAssetId: "S1")
        try store.addWishPlace(userId: userId, id: "p2", name: "鼎烽菜包", address: "", area: "", category: "其他", note: "",
                               latitude: nil, longitude: nil, sourceAssetId: nil)
        XCTAssertTrue(try store.updateWishPlace(userId: userId, placeId: "p1", name: "豆豆來麻辣鴛鴦火鍋", address: "春日路1434巷",
                                                area: "桃園市", category: "餐廳", note: "12:00 開",
                                                latitude: 25.0, longitude: 121.3))
        let place = try XCTUnwrap(store.wishPlaces(userId: userId).first { $0.id == "p1" })
        XCTAssertEqual(place.name, "豆豆來麻辣鴛鴦火鍋")
        XCTAssertEqual(place.sourceAssetId, "S1", "編輯不會動到來源截圖")
        XCTAssertEqual(WishRegion.name(area: place.area, address: place.address), "桃園")
        XCTAssertFalse(try store.updateWishPlace(userId: userId, placeId: "p1", name: "鼎烽 菜包", address: "", area: "",
                                                 category: "其他", note: "", latitude: nil, longitude: nil),
                       "改成清單裡已有的名稱：不改")
    }

    func testVisitedAndDelete() throws {
        try store.addWishPlace(userId: userId, id: "p1", name: "A", address: "", area: "", category: "其他", note: "",
                               latitude: nil, longitude: nil, sourceAssetId: nil)
        try store.addWishPlace(userId: userId, id: "p2", name: "B", address: "", area: "", category: "其他", note: "",
                               latitude: nil, longitude: nil, sourceAssetId: nil)
        try store.setWishVisited(userId: userId, placeId: "p1", visited: true, assetId: "V1", visitedAt: "2026-10-20")
        var places = try store.wishPlaces(userId: userId)
        XCTAssertEqual(places.map(\.id), ["p2", "p1"], "想去的在前、去過的在後")
        XCTAssertEqual(places.last?.visitedAssetId, "V1")
        try store.setWishVisited(userId: userId, placeId: "p1", visited: false, assetId: nil, visitedAt: nil)
        XCTAssertFalse(try store.wishPlaces(userId: userId).contains { $0.isVisited })
        try store.deleteWishPlace(userId: userId, placeId: "p2")
        places = try store.wishPlaces(userId: userId)
        XCTAssertEqual(places.map(\.id), ["p1"])
    }

    func testVisitMatcher() {
        let added = Date(timeIntervalSince1970: 1_000)
        let place = (id: "p1", latitude: 22.9900, longitude: 120.2000, addedAt: added)
        let photos = [
            WishVisitMatcher.Photo(assetId: "before", date: Date(timeIntervalSince1970: 500), latitude: 22.9900, longitude: 120.2000),
            WishVisitMatcher.Photo(assetId: "far", date: Date(timeIntervalSince1970: 2_000), latitude: 23.0100, longitude: 120.2000),
            WishVisitMatcher.Photo(assetId: "near2", date: Date(timeIntervalSince1970: 4_000), latitude: 22.9905, longitude: 120.2003),
            WishVisitMatcher.Photo(assetId: "near1", date: Date(timeIntervalSince1970: 3_000), latitude: 22.9901, longitude: 120.2001),
        ]
        let visits = WishVisitMatcher.visits(places: [place], photos: photos)
        XCTAssertEqual(visits, [WishVisitMatcher.Visit(placeId: "p1", assetId: "near1", date: Date(timeIntervalSince1970: 3_000))],
                       "加入之後、200 公尺內的第一張")
        XCTAssertEqual(WishVisitMatcher.distance(22.99, 120.2, 23.01, 120.2), 2224, accuracy: 5)
    }

    /// 地圖截圖：只加入選取的那一家，地圖上其他店名的標籤不算
    func testMapScreenshotKeepsOnlySelectedPlace() {
        let text = """
        12:30
        勤眾興業股份有限公司
        Hitte 咖啡館_桃周细羊
        豆豆來麻辣鴛鴦火鍋
        騰之雞排專門
        店-桃園龜山店
        豆豆來麻辣鴛鴦火鍋
        最近查看過
        鼎烽菜包
        868小館
        巧合珍牛肉麵
        豆豆來麻辣鴛鴦火鍋
        4.5 ★★★★★ (406) · 1小時3分鐘
        火鍋餐廳 · $400-1,000
        已打烊 · 開始營業時間：12:00
        路線
        開始
        致電
        分享
        """
        XCTAssertTrue(MapScreenshotFocus.isMapScreenshot(text))
        XCTAssertEqual(MapScreenshotFocus.focusNames(text), ["豆豆來麻辣鴛鴦火鍋"])
        let found = ["Hitte 咖啡館", "豆豆來麻辣鴛鴦火鍋", "騰之雞排專門店-桃園龜山店", "鼎烽菜包", "868小館", "巧合珍牛肉麵"]
        XCTAssertEqual(MapScreenshotFocus.filter(found, text: text) { $0 }, ["豆豆來麻辣鴛鴦火鍋"])

        // 不是地圖截圖（IG 貼文列了好幾家）：全部保留
        let post = "台北咖啡廳推薦\n1. 鹿角咖啡\n2. 好丘\n3. 晨間咖啡\n#咖啡 #台北"
        XCTAssertEqual(MapScreenshotFocus.filter(["鹿角咖啡", "好丘", "晨間咖啡"], text: post) { $0 },
                       ["鹿角咖啡", "好丘", "晨間咖啡"])
        // 地圖截圖但沒有選取任何一家（只是地圖畫面）：全部保留
        let plain = "路線\n開始\n鼎烽菜包\n868小館"
        XCTAssertEqual(MapScreenshotFocus.filter(["鼎烽菜包", "868小館"], text: plain) { $0 }, ["鼎烽菜包", "868小館"])
    }

    /// 依地區分組：縣市別名、地址補判斷、地方多的地區排前面、認不出的放最後
    func testWishRegionGrouping() {
        XCTAssertEqual(WishRegion.name(area: "桃園龜山", address: ""), "桃園")
        XCTAssertEqual(WishRegion.name(area: "", address: "臺南市中西區民族路"), "台南")
        XCTAssertEqual(WishRegion.name(area: "澀谷", address: ""), "東京")
        XCTAssertEqual(WishRegion.name(area: "", address: "台北市信義區（近新北）"), "台北")
        XCTAssertEqual(WishRegion.name(area: "某個小鎮", address: ""), "某個小鎮")
        XCTAssertEqual(WishRegion.name(area: "", address: ""), WishRegion.other)

        func place(_ name: String, _ area: String) -> WishPlace {
            WishPlace(id: name, name: name, address: "", area: area, category: "餐廳", note: "", latitude: nil, longitude: nil,
                      sourceAssetId: nil, isVisited: false, visitedAssetId: nil, visitedAt: nil, createdAt: nil)
        }
        let groups = WishRegion.group([place("A", ""), place("B", "台南"), place("C", "桃園龜山"), place("D", "台南中西區")])
        XCTAssertEqual(groups.map(\.region), ["台南", "桃園", WishRegion.other])
        XCTAssertEqual(groups[0].places.map(\.name), ["B", "D"])

        // 地址只有路名：用座標查到的行政區判斷縣市
        XCTAssertEqual(WishRegion.name(area: "", address: "春日路1434巷"), WishRegion.other)
        XCTAssertEqual(WishRegion.name(area: "", address: "春日路1434巷", hint: "桃園市桃園區"), "桃園")
        let hinted = WishRegion.group([place("E", "")], hints: ["E": "桃園市桃園區"])
        XCTAssertEqual(hinted.map(\.region), ["桃園"])
    }
}

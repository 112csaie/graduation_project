import XCTest
@testable import PersonalizationCore

/// 購物清單：國家判斷、加入（同國家同名不重複）、改國家、買到了、提醒規則。
final class ShoppingListStoreTests: XCTestCase {

    private var store: PersonalizationStore!
    private var userId: String!

    override func setUpWithError() throws {
        store = try TestDatabase.makeStore()
        userId = try store.resolveUser(email: "shop@example.com", displayName: nil)
    }

    override func tearDown() { store = nil }

    private func add(_ id: String, _ name: String, country: String, store shop: String = "") throws -> Bool {
        try store.addShoppingItem(userId: userId, id: id, name: name, brand: "", price: "", store: shop,
                                  countryCode: country, note: "", sourceAssetId: "S-\(id)")
    }

    private func item(_ name: String, country: String, store: String = "", bought: Bool = false) -> ShoppingItem {
        ShoppingItem(id: name, name: name, brand: "", price: "", store: store, countryCode: country, note: "",
                     sourceAssetId: nil, isBought: bought, boughtAt: nil, createdAt: nil)
    }

    // MARK: 國家

    func testGuessCountryFromScript() {
        XCTAssertEqual(ShoppingCountry.guess(text: "キャンメイク マシュマロフィニッシュパウダー ¥1,034"), "JP")
        XCTAssertEqual(ShoppingCountry.guess(text: "올리브영 추천템 토너패드"), "KR")
        XCTAssertEqual(ShoppingCountry.guess(text: "ยาดมโป๊ยเซียน"), "TH")
        XCTAssertNil(ShoppingCountry.guess(text: "小林製藥 退熱貼 NT$199"), "只有中文字分不出國家")
        XCTAssertNil(ShoppingCountry.guess(text: "の"), "一兩個字不夠")
        XCTAssertEqual(ShoppingCountry.guess(text: "日本必買 ロイズ 生巧克力 の"), "JP", "中文標題夾日文")
        // 沒有韓文字，但文字寫了國家、城市或幣別
        XCTAssertEqual(ShoppingCountry.guess(text: "韓國必買清單 護手霜"), "KR")
        XCTAssertEqual(ShoppingCountry.guess(text: "首爾 Olive Young 推薦 精華液 ₩25,000"), "KR")
        XCTAssertEqual(ShoppingCountry.guess(text: "包裝上是韓文，一條粉紅色的護手霜"), "KR", "看圖描述")
        XCTAssertEqual(ShoppingCountry.guess(text: "曼谷 7-11 必買 ฿39"), "TH")
    }

    func testCountryNames() {
        XCTAssertEqual(ShoppingCountry.name(for: "jp"), "日本")
        XCTAssertEqual(ShoppingCountry.name(for: ""), "未指定國家")
        XCTAssertEqual(ShoppingCountry.code(forName: "韓國"), "KR")
        XCTAssertEqual(ShoppingCountry.code(forName: "Japan"), "JP")
        XCTAssertEqual(ShoppingCountry.code(forName: "United States"), "US")
        XCTAssertNil(ShoppingCountry.code(forName: "火星"))
        for code in ShoppingCountry.common { XCTAssertNotNil(ShoppingCountry.names[code], code) }
    }

    // MARK: 資料庫

    func testAddDedupesPerCountry() throws {
        XCTAssertTrue(try add("1", "合利他命 EX Plus", country: "jp"))
        XCTAssertFalse(try add("2", "合利他命ex plus", country: "JP"), "同國家同名（忽略空白、大小寫）不重複")
        XCTAssertTrue(try add("3", "合利他命 EX Plus", country: "TW"), "不同國家可以各有一份")
        XCTAssertFalse(try add("4", "  ", country: "JP"), "沒有名稱不加入")
        let other = try store.resolveUser(email: "other@example.com", displayName: nil)
        XCTAssertTrue(try store.addShoppingItem(userId: other, id: "5", name: "合利他命 EX Plus", brand: "", price: "",
                                                store: "", countryCode: "JP", note: "", sourceAssetId: nil),
                      "不同帳號各自一份清單")

        let items = try store.shoppingItems(userId: userId)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.countryCode)), ["JP", "TW"], "國家代碼存成大寫")
        XCTAssertEqual(items.first { $0.countryCode == "JP" }?.sourceAssetId, "S-1")
    }

    func testBoughtSetCountryAndDelete() throws {
        XCTAssertTrue(try add("1", "Royce 生巧克力", country: "JP"))
        XCTAssertTrue(try add("2", "Royce 生巧克力", country: ""))
        XCTAssertTrue(try add("3", "東京香蕉", country: "JP"))

        XCTAssertFalse(try store.setShoppingCountry(userId: userId, itemId: "2", countryCode: "jp"),
                       "日本清單已有同名商品，不改")
        XCTAssertTrue(try store.setShoppingCountry(userId: userId, itemId: "2", countryCode: "kr"))
        XCTAssertEqual(try store.shoppingItems(userId: userId).first { $0.id == "2" }?.countryCode, "KR")

        try store.setShoppingBought(userId: userId, itemId: "3", bought: true, boughtAt: "2026/10/21 15:00")
        var items = try store.shoppingItems(userId: userId)
        XCTAssertEqual(items.last?.id, "3", "買到的排在最後")
        XCTAssertEqual(items.last?.boughtAt, "2026/10/21 15:00")
        XCTAssertTrue(items.last?.isBought ?? false)

        try store.setShoppingBought(userId: userId, itemId: "3", bought: false, boughtAt: "ignored")
        items = try store.shoppingItems(userId: userId)
        XCTAssertFalse(items.first { $0.id == "3" }?.isBought ?? true)
        XCTAssertNil(items.first { $0.id == "3" }?.boughtAt, "取消打勾時清掉購買時間")

        try store.deleteShoppingItem(userId: userId, itemId: "1")
        XCTAssertEqual(Set(try store.shoppingItems(userId: userId).map(\.id)), ["2", "3"])
    }

    /// 刪除清單項目只動 ShoppingItems，不碰照片資料
    func testUpdateItemText() throws {
        try store.addShoppingItem(userId: userId, id: "u1", name: "護髮油", brand: "", price: "", store: "",
                                  countryCode: "JP", note: "名稱待確認", sourceAssetId: "S1")
        try store.addShoppingItem(userId: userId, id: "u2", name: "眼藥水", brand: "", price: "", store: "",
                                  countryCode: "JP", note: "", sourceAssetId: nil)
        XCTAssertTrue(try store.updateShoppingItem(userId: userId, itemId: "u1", name: "無印良品 護髮油", brand: "無印良品",
                                                   price: "¥1,290", store: "", note: ""))
        let item = try XCTUnwrap(store.shoppingItems(userId: userId).first { $0.id == "u1" })
        XCTAssertEqual(item.name, "無印良品 護髮油")
        XCTAssertEqual(item.countryCode, "JP", "編輯文字不改國家")
        XCTAssertEqual(item.sourceAssetId, "S1")
        XCTAssertFalse(try store.updateShoppingItem(userId: userId, itemId: "u1", name: "眼藥水", brand: "", price: "",
                                                    store: "", note: ""), "同一個國家已有同名商品：不改")
    }

    func testDeleteDoesNotTouchPhotos() throws {
        try TestDatabase.insertPhoto(store.db, assetId: "S-1", owner: userId, embedding: TestDatabase.vector(1))
        XCTAssertTrue(try add("1", "東京香蕉", country: "JP"))
        let before = try store.db.scalar("SELECT COUNT(*) FROM PhotoFeatures") as? Int64
        try store.deleteShoppingItem(userId: userId, itemId: "1")
        XCTAssertEqual(try store.db.scalar("SELECT COUNT(*) FROM PhotoFeatures") as? Int64, before)
    }

    // MARK: 提醒規則

    func testPendingOnlyUnboughtInCountry() {
        let items = [item("A", country: "JP"), item("B", country: "JP", bought: true), item("C", country: "KR"), item("D", country: "")]
        XCTAssertEqual(ShoppingReminder.pending(items, countryCode: "jp").map(\.name), ["A"])
        XCTAssertTrue(ShoppingReminder.pending(items, countryCode: "").isEmpty, "不知道在哪個國家時不提醒")
        XCTAssertTrue(ShoppingReminder.pending(items, countryCode: "TW").isEmpty)
    }

    func testCooldown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ShoppingReminder.shouldNotify(lastNotified: nil, now: now, cooldownHours: 20))
        XCTAssertFalse(ShoppingReminder.shouldNotify(lastNotified: now.addingTimeInterval(-3600), now: now, cooldownHours: 20))
        XCTAssertTrue(ShoppingReminder.shouldNotify(lastNotified: now.addingTimeInterval(-21 * 3600), now: now, cooldownHours: 20))
    }

    func testGroupByStore() {
        let items = [item("A", country: "JP", store: "唐吉訶德"), item("B", country: "JP", store: " 唐吉訶德 "),
                     item("C", country: "JP", store: "松本清"), item("D", country: "JP"),
                     item("E", country: "JP", store: "松本清", bought: true)]
        let groups = ShoppingReminder.byStore(items)
        XCTAssertEqual(groups.map(\.store), ["唐吉訶德", "松本清"], "商品多的店在前；沒寫店名、已買的不算")
        XCTAssertEqual(groups.first?.items.map(\.name), ["A", "B"])
    }

    func testMessages() {
        let items = (1...6).map { item("商品\($0)", country: "JP") }
        let country = ShoppingReminder.countryMessage(countryCode: "JP", items: items)
        XCTAssertEqual(country.title, "你在日本！")
        XCTAssertEqual(country.body, "購物清單還有 6 樣沒買：商品1、商品2、商品3、商品4…")
        let shop = ShoppingReminder.storeMessage(store: "松本清", items: Array(items.prefix(2)))
        XCTAssertEqual(shop.title, "附近有松本清")
        XCTAssertEqual(shop.body, "購物清單上有 2 樣可以在這裡買：商品1、商品2")
    }
}

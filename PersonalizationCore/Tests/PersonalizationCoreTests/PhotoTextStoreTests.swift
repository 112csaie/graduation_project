import XCTest
import SQLite
@testable import PersonalizationCore

/// 照片中的文字（OCR）：儲存、搜尋、分類線索，以及「移除 AI 分析資料」時一併刪除。
final class PhotoTextStoreTests: XCTestCase {

    private var store: PersonalizationStore!
    private var userId: String!

    override func setUpWithError() throws {
        store = try TestDatabase.makeStore()
        userId = try store.resolveUser(email: "ocr@example.com", displayName: nil)
        try TestDatabase.insertPhoto(store.db, assetId: "A", owner: userId, embedding: TestDatabase.vector(1))
        try TestDatabase.insertPhoto(store.db, assetId: "B", owner: userId, embedding: TestDatabase.vector(2))
        try TestDatabase.insertPhoto(store.db, assetId: "C", owner: userId, embedding: TestDatabase.vector(3))
    }

    override func tearDown() { store = nil }

    func testNormalize() {
        XCTAssertEqual(PhotoTextHints.normalize("亞尼克 生乳捲\nＡＢＣ 123"), "亞尼克生乳捲abc123")
    }

    func testSaveSearchAndPending() throws {
        XCTAssertEqual(Set(try store.assetsPendingOCR(limit: 10)), ["A", "B", "C"])
        try store.savePhotoText(assetId: "A", text: "亞尼克 原味 生乳捲")
        try store.savePhotoText(assetId: "B", text: "生乳捲 生乳捲 第二件六折")
        try store.savePhotoText(assetId: "C", text: "")   // 沒有文字也記錄，避免重複辨識

        XCTAssertTrue(try store.assetsPendingOCR(limit: 10).isEmpty)
        XCTAssertEqual(try store.photoText(assetId: "A"), "亞尼克 原味 生乳捲")
        // 出現次數多的在前；查詢中的空白不影響
        XCTAssertEqual(try store.assetIds(matchingPhotoText: "生乳 捲"), ["B", "A"])
        XCTAssertEqual(try store.assetIds(matchingPhotoText: "%"), [], "LIKE 萬用字元當一般文字")

        let stats = try store.photoTextStats()
        XCTAssertEqual(stats, PhotoTextStats(recognized: 3, withText: 2, pending: 0))
        XCTAssertEqual(try store.normalizedPhotoTexts(assetIds: ["A", "C"]), ["A": "亞尼克原味生乳捲"])
    }

    func testPhotoNotScannedYetCanStillBeRecognized() throws {
        // 使用者在照片頁按「辨識」時，照片可能還沒被掃描（沒有 PhotoFeatures）
        XCTAssertTrue(try store.savePhotoText(assetId: "Z", text: "亞尼克"))
        XCTAssertEqual(try store.assetIds(matchingPhotoText: "亞尼克"), ["Z"])
    }

    func testRemovingAIAnalysisDeletesTextAndBlocksRewrite() throws {
        try store.savePhotoText(assetId: "A", text: "演唱會")
        _ = try store.removeAIAnalysis(userId: userId, assetId: "A")
        XCTAssertNil(try store.photoText(assetId: "A"))
        XCTAssertFalse(try store.savePhotoText(assetId: "A", text: "演唱會"), "移除後辨識結果不寫回")
        XCTAssertFalse(try store.assetsPendingOCR(limit: 10).contains("A"))

        try store.prepareReanalysis(userId: userId, assetId: "A")
        XCTAssertTrue(try store.savePhotoText(assetId: "A", text: "演唱會"))
    }

    func testHintsFromText() {
        let terms = PhotoTextHints.terms(for: .builtIn)
        let text = PhotoTextHints.normalize("2026 WORLD TOUR 演唱會 電子發票")
        let ids = PhotoTextHints.nodeIds(in: text, terms: terms)
        XCTAssertTrue(ids.contains("concert"))
        XCTAssertTrue(ids.contains("receipt"))
        let ticket = PhotoTextHints.nodeIds(in: PhotoTextHints.normalize("威秀影城 電影票"), terms: terms)
        XCTAssertTrue(ticket.contains("movie"))
        XCTAssertFalse(PhotoTextHints.nodeIds(in: PhotoTextHints.normalize("推薦一部好看的電影"), terms: terms).contains("movie"),
                       "「電影」兩個字不夠")
        XCTAssertTrue(PhotoTextHints.nodeIds(in: PhotoTextHints.normalize("今天的日常"), terms: terms).isEmpty,
                      "籠統的分類名稱不比對")
    }

    func testMergeHints() {
        let suggestions = [
            TagSuggestion(nodeId: "concert", score: 0.21, status: .candidate),
            TagSuggestion(nodeId: "cake", score: 0.3, status: .accepted),
        ]
        let merged = PhotoTextHints.merge(suggestions, hintNodeIds: ["concert", "receipt", "movie", "museum"])
        XCTAssertEqual(merged.first { $0.nodeId == "concert" }?.status, .accepted, "向量與文字一致 → 確認")
        XCTAssertEqual(merged.first { $0.nodeId == "cake" }?.status, .accepted)
        XCTAssertEqual(merged.filter { $0.status == .candidate }.map(\.nodeId), ["receipt", "movie"], "只有文字 → 待確認，最多 2 個")
    }

    // MARK: 紙張與卡片：文字決定分類

    func testPaperDecisionByText() {
        func decide(_ text: String) -> String? { PhotoTextHints.paperDecision(in: PhotoTextHints.normalize(text)) }
        XCTAssertEqual(decide("威秀影城 第 5 廳 影廳 座位 F12 統一編號 12345678"), "movie", "電影票印有統編也算票根")
        XCTAssertEqual(decide("(4DX 3D)蜘蛛人：重生日 放映影城 林口三井威秀影城 放映時間 22:15 級數 保護級 1廳 F排 8號 票種 儲值金會員 票價 530"),
                       "movie", "威秀電影票")
        XCTAssertEqual(decide("威秀影城 販賣部 電子發票 合計 150"), "receipt", "影城販賣部的發票不算票根")
        // v21：票根併入「電影」：演唱會、展覽的門票不算電影
        XCTAssertNil(decide("拓元售票 2026 WORLD TOUR 票種 全票 票價 3800 座位 A區 12排"), "演唱會門票不是電影")
        XCTAssertEqual(decide("電子發票證明聯 合計 120"), "receipt")
        XCTAssertEqual(decide("長庚大學 學生證 Student ID"), "id_card")
        XCTAssertEqual(decide("MENU 套餐 A 180"), "menu")
        XCTAssertEqual(decide("InBody 體脂肪 骨骼肌"), "body_composition")
        XCTAssertNil(decide("今天天氣很好"))
    }

    func testPaperDecisionReplacesOtherPaperGuesses() {
        let terms = PhotoTextHints.terms(for: .builtIn)
        let suggestions = [
            TagSuggestion(nodeId: "receipt", score: 0.3, status: .accepted),
            TagSuggestion(nodeId: "cake", score: 0.3, status: .accepted),
        ]
        let text = PhotoTextHints.normalize("影廳 座位 場次")
        let paper = PhotoTextHints.combine(suggestions, normalizedText: text, terms: terms, looksLikePaper: true)
        XCTAssertEqual(Set(paper.filter { $0.status == .accepted }.map(\.nodeId)), ["movie", "cake"])

        // 不像紙張（例如風景照裡的招牌）：只當作線索，不直接確認
        let photo = PhotoTextHints.combine(suggestions, normalizedText: text, terms: terms, looksLikePaper: false)
        XCTAssertEqual(photo.first { $0.nodeId == "receipt" }?.status, .accepted)
        XCTAssertNotEqual(photo.first { $0.nodeId == "movie" }?.status, .accepted)
    }

    func testLooksLikePaperUsesClosestCategories() {
        var v = [Float](repeating: 0, count: 16)
        func image(_ weights: [Int: Float]) -> [Float] {
            v = [Float](repeating: 0, count: 16)
            for (axis, weight) in weights { v[axis] = weight }
            return MultiLabelTagger.normalized(v)
        }
        let tagger = MultiLabelTagger(catalog: .builtIn, promptEmbeddings: [
            "receipt": [TestDatabase.vector(0)],
            "cat": [TestDatabase.vector(1)],
        ])
        XCTAssertTrue(tagger.looksLikePaper(image([0: 1, 1: 0.5])))
        XCTAssertFalse(tagger.looksLikePaper(image([1: 1, 0: 0.3])), "最像的是貓，不算紙張")
    }

    /// 收據要有收據的格式：公告、公文寫到「收據」「統一編號」不算
    func testReceiptNeedsReceiptFormat() {
        let decide = { PhotoTextHints.paperDecision(in: PhotoTextHints.normalize($0)) }
        XCTAssertEqual(decide("電子發票證明聯 115年09-10月 FR-12772916 總計 21"), "receipt")
        XCTAssertEqual(decide("CherryJill 收據 FT - 35803942"), "receipt", "發票號碼")
        XCTAssertEqual(decide("收據 午餐 合計 120 現金 200 找零 80"), "receipt")
        XCTAssertNil(decide("請於期限內繳交收據影本，費用 500 元"), "學校公告")
        XCTAssertNil(decide("廠商名稱 統一編號 12345678 收據 以上資料請確認"), "公文")
        // v19：電話、文件編號不是發票號碼；只有金額、沒有收據字樣的表格也不算
        XCTAssertNil(decide("收據 聯絡電話 TEL 02 1234 5678"), "電話號碼不是發票號碼")
        XCTAssertNil(decide("文件編號 AB123456789 合計 3 頁"), "後面還接數字的編號不是發票號碼")
        XCTAssertNil(decide("報名表 合計 500 小計 300 總計 800"), "沒有發票、收據字樣的金額表格")
        XCTAssertEqual(decide("交易明細 小計 80 總計 80"), "receipt")
        let terms = PhotoTextHints.terms(for: .builtIn)
        let notice = PhotoTextHints.combine([], normalizedText: PhotoTextHints.normalize("請繳交收據 發票"), terms: terms,
                                            looksLikePaper: false)
        XCTAssertFalse(notice.contains { $0.nodeId == "receipt" }, "只有「收據」兩個字不當作線索")
    }

    // MARK: 人像（自拍用系統相簿）

    func testSelfieComesFromSystemAlbum() {
        let clip = [TagSuggestion(nodeId: "portrait", score: 0.26, status: .accepted),
                    TagSuggestion(nodeId: "selfie", score: 0.25, status: .accepted),
                    TagSuggestion(nodeId: "cafe", score: 0.27, status: .accepted),
                    TagSuggestion(nodeId: "coffee", score: 0.24, status: .accepted),
                    TagSuggestion(nodeId: "concert", score: 0.26, status: .candidate)]
        // 在系統「自拍」相簿：標自拍、拿掉人物照；最多 3 個確認
        let selfie = PeopleHints.combine(clip, isSelfie: true, selfieAllowed: true, maxAccepted: 3)
        XCTAssertEqual(selfie.filter { $0.status == .accepted }.map(\.nodeId), ["selfie", "cafe", "coffee"])
        XCTAssertTrue(selfie.contains { $0.nodeId == "concert" && $0.status == .candidate }, "待確認的不受影響")
        // 不在自拍相簿：照片向量給的自拍拿掉，人物照保留
        let other = PeopleHints.combine(clip, isSelfie: false, selfieAllowed: true, maxAccepted: 3)
        XCTAssertFalse(other.contains { $0.nodeId == "selfie" })
        XCTAssertTrue(other.contains { $0.nodeId == "portrait" })
        // 自拍分類關閉：不標
        XCTAssertFalse(PeopleHints.combine(clip, isSelfie: true, selfieAllowed: false, maxAccepted: 3).contains { $0.nodeId == "selfie" })
    }

    /// v24：「手機截圖」小分類移除（照片分頁有「截圖」切換），手動標過的移到「螢幕截圖」
    func testScreenshotCategoryRemoved() {
        XCTAssertNil(TaxonomyCatalog.builtIn.node("screenshot"))
        XCTAssertEqual(TaxonomyCatalog.builtIn.nodeRedirects["screenshot"], "screens")
        XCTAssertNotNil(TaxonomyCatalog.builtIn.node("chat_screenshot"), "聊天截圖保留")
    }

    func testClearOldFaceData() throws {
        XCTAssertGreaterThanOrEqual(try store.clearFaceData(), 0)
    }

    // MARK: 機票與登機證

    func testBoardingPassDecision() {
        let pass = PhotoTextHints.normalize("EVA AIR BOARDING PASS 登機證 Flight BR198 Gate C5 Seat 32A Boarding Time 07:10")
        XCTAssertEqual(PhotoTextHints.paperDecision(in: pass), "boarding_pass", "登機證排在票根前面（也有座位）")
        let movie = PhotoTextHints.normalize("威秀影城 電影票 放映時間 19:30 影廳 5 座位 F12 票種 全票")
        XCTAssertEqual(PhotoTextHints.paperDecision(in: movie), "movie")
        XCTAssertNil(PhotoTextHints.paperDecision(in: PhotoTextHints.normalize("Gate 3 往台北")), "只有一個弱關鍵字不算")

        let catalog = TaxonomyCatalog.builtIn
        let terms = PhotoTextHints.terms(for: catalog)
        // 手機錢包的登機證截圖：截圖也會判斷成登機證；電影票截圖（訂票頁面）不算票根
        let fromScreenshot = PhotoTextHints.combine([], normalizedText: pass, terms: terms, looksLikePaper: false, isScreenshot: true)
        XCTAssertTrue(fromScreenshot.contains { $0.nodeId == "boarding_pass" && $0.status == .accepted })
        let movieScreenshot = PhotoTextHints.combine([], normalizedText: movie, terms: terms, looksLikePaper: false, isScreenshot: true)
        XCTAssertFalse(movieScreenshot.contains { $0.nodeId == "movie" && $0.status == .accepted })
        XCTAssertNotNil(catalog.node("boarding_pass"))
    }

    /// 截圖的文字（手動辨識時）：聊天、網頁上提到的演唱會、拉麵不會變成分類線索
    func testScreenshotTextOnlyHintsChatAndBoardingPass() {
        let catalog = TaxonomyCatalog.builtIn
        let terms = PhotoTextHints.terms(for: catalog)
        let chat = PhotoTextHints.normalize("已讀 明天的演唱會要不要先去吃拉麵")
        let fromScreenshot = PhotoTextHints.combine([], normalizedText: chat, terms: terms, looksLikePaper: false, isScreenshot: true)
        XCTAssertFalse(fromScreenshot.contains { $0.nodeId == "concert" })
        XCTAssertTrue(fromScreenshot.allSatisfy { PhotoTextHints.screenshotHintNodeIds.contains($0.nodeId) })
        let fromPhoto = PhotoTextHints.combine([], normalizedText: chat, terms: terms, looksLikePaper: false, isScreenshot: false)
        XCTAssertTrue(fromPhoto.contains { $0.nodeId == "concert" }, "一般照片照舊當作線索")
    }

    func testDishNamesOnMenuOrNotesAreNotFoodHints() {
        let catalog = TaxonomyCatalog.builtIn
        let terms = PhotoTextHints.terms(for: catalog)
        let dish = PhotoTextHints.dishNodeIds(for: catalog)
        XCTAssertTrue(dish.contains("noodle_dish"))
        XCTAssertFalse(dish.contains("menu"))
        let text = PhotoTextHints.normalize("牛肉麵 120元 陽春麵 50元")
        // 菜單、筆記（看起來像紙張）：菜名不算麵食
        let paper = PhotoTextHints.combine([], normalizedText: text, terms: terms, looksLikePaper: true, dishNodeIds: dish)
        XCTAssertFalse(paper.contains { $0.nodeId == "noodle_dish" })
        // 貼在玻璃上的菜單（不一定像紙張）：文字有「菜單」也不算
        let poster = PhotoTextHints.combine([], normalizedText: PhotoTextHints.normalize("菜單 牛肉麵"), terms: terms,
                                            looksLikePaper: false, dishNodeIds: dish)
        XCTAssertFalse(poster.contains { $0.nodeId == "noodle_dish" })
        // 一般照片（例如麵店招牌）：仍當作待確認的線索
        let photo = PhotoTextHints.combine([], normalizedText: text, terms: terms, looksLikePaper: false, dishNodeIds: dish)
        XCTAssertTrue(photo.contains { $0.nodeId == "noodle_dish" && $0.status == .candidate })
    }
}

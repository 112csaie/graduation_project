import XCTest
@testable import PersonalizationCore

/// 容易誤認的畫面（v8）：照片比較像「單腳站著擺姿勢」時不算跑步；比較像「店門口合照」時不算 Live House。
final class ConfuserTests: XCTestCase {

    private func image(_ weights: [Int: Float]) -> [Float] {
        var v = [Float](repeating: 0, count: 16)
        for (axis, weight) in weights { v[axis] = weight }
        return MultiLabelTagger.normalized(v)
    }

    private func accepted(_ suggestions: [TagSuggestion]) -> Set<String> {
        Set(suggestions.filter { $0.status == .accepted }.map(\.nodeId))
    }

    func testCatalogDefinesConfusersForProblemCategories() {
        let catalog = TaxonomyCatalog.builtIn
        XCTAssertEqual(catalog.validationErrors(), [])
        for id in ["running", "ball_sports", "concert", "theater_show", "merch"] {
            XCTAssertFalse(catalog.node(id)?.confusers.isEmpty ?? true, id)
        }
        XCTAssertEqual(TaxonomyNode.confuserKey("running"), "running#not")
    }

    func testPosingPhotoIsNotRunning() {
        let tagger = MultiLabelTagger(catalog: .builtIn, promptEmbeddings: [
            "running": [TestDatabase.vector(0)],
            TaxonomyNode.confuserKey("running"): [TestDatabase.vector(1)],
        ])
        XCTAssertEqual(accepted(tagger.suggestTags(for: image([0: 1, 1: 1]))), [], "和擺姿勢一樣像 → 不算跑步")
        XCTAssertEqual(accepted(tagger.suggestTags(for: image([0: 1, 1: 0.3]))), ["running"], "明顯在跑 → 跑步")
        XCTAssertTrue(tagger.topGuesses(for: image([0: 1, 1: 1])).isEmpty, "也不當成回憶草稿的線索")
    }

    /// 課本不算休閒閱讀；專輯與周邊一樣像時不算拍貼
    func testBooksStandeesAndAlbumsNeedToBeatLookalikes() {
        let tagger = MultiLabelTagger(catalog: .builtIn, promptEmbeddings: [
            "photo_sticker": [TestDatabase.vector(0), TestDatabase.vector(5)],
            "merch": [TestDatabase.vector(1)],
            "books": [TestDatabase.vector(2)],
            "textbook": [TestDatabase.vector(3)],
        ])
        XCTAssertEqual(accepted(tagger.suggestTags(for: image([0: 1, 1: 1]))), ["merch"])
        XCTAssertEqual(accepted(tagger.suggestTags(for: image([0: 1, 1: 0.3]))), ["photo_sticker"])
        XCTAssertEqual(accepted(tagger.suggestTags(for: image([2: 1, 3: 1]))), ["textbook"])
        XCTAssertEqual(TaxonomyCatalog.builtIn.topLevelId(of: "textbook"), "study_work")
    }

    /// v10：鏡前照不再自動歸進健身；體組成只靠照片文字；票根只會是待確認；證件、菜單不算收據
    func testPaperCardsAndMirrorSelfies() {
        let catalog = TaxonomyCatalog.builtIn
        XCTAssertNil(catalog.node("gym_selfie"))
        XCTAssertEqual(catalog.nodeRedirects["gym_selfie"], "workout")
        XCTAssertEqual(catalog.node("body_composition")?.recognition, .manualOnly)
        // v21：票根併入「電影」；票根的樣子寫在收據發票的描述裡（只用來觸發文字辨識，由文字決定）
        XCTAssertNil(catalog.node("ticket_stub"))
        XCTAssertEqual(catalog.nodeRedirects["ticket_stub"], "movie")
        XCTAssertEqual(catalog.node("movie")?.nameZh, "電影")
        XCTAssertTrue(catalog.node("receipt")?.prompts.contains { $0.contains("ticket") } ?? false)

        let tagger = MultiLabelTagger(catalog: catalog, promptEmbeddings: [
            "receipt": [TestDatabase.vector(0)],
            "id_card": [TestDatabase.vector(1)],
            "menu": [TestDatabase.vector(2)],
        ])
        XCTAssertEqual(accepted(tagger.suggestTags(for: image([0: 1, 1: 1]))), ["id_card"], "學生證不算收據")
        XCTAssertEqual(accepted(tagger.suggestTags(for: image([0: 1, 2: 1]))), ["menu"], "菜單不算收據")
    }

    /// v14：有 QR code 的東西都很像電子發票，所以收據發票只靠畫面不會標上；要照片文字也說是發票才算
    func testReceiptNeedsTextEvidence() {
        let catalog = TaxonomyCatalog.builtIn
        XCTAssertEqual(catalog.node("receipt")?.requiresText, true)
        let tagger = MultiLabelTagger(catalog: catalog, promptEmbeddings: ["receipt": [TestDatabase.vector(0)]])
        let qrPoster = image([0: 1])
        let byVision = tagger.suggestTags(for: qrPoster)
        XCTAssertTrue(byVision.isEmpty, "畫面像收據不會直接標上")
        XCTAssertTrue(tagger.looksLikePaper(qrPoster), "但會去辨識照片文字")
        let withText = PhotoTextHints.combine(byVision, normalizedText: PhotoTextHints.normalize("電子發票證明聯 統一編號 合計 120"),
                                              terms: [], looksLikePaper: true)
        XCTAssertEqual(withText.first { $0.nodeId == "receipt" }?.status, .accepted, "文字是發票才標上")
        let menuQR = PhotoTextHints.combine(byVision, normalizedText: PhotoTextHints.normalize("掃描點餐 QR code"),
                                            terms: [], looksLikePaper: true)
        XCTAssertNil(menuQR.first { $0.nodeId == "receipt" })
    }

    /// v14：拍到貓狗不一定是寵物，分類名稱不叫「寵物」
    func testNoPetCategoryName() {
        let catalog = TaxonomyCatalog.builtIn
        XCTAssertFalse(catalog.nodes.contains { $0.nameZh == "寵物" || $0.nameZh.contains("寵物") })
        XCTAssertEqual(catalog.node("animals_pets")?.nameZh, "動物")
        XCTAssertEqual(catalog.node("cat")?.parentId, "pets", "id 不變，標籤不用搬移")
    }

    /// 貓狗一眼看得出來：沒選「動物與寵物」、或畫面裡同時有更像的東西（沙發、咖啡廳），也照樣標上
    func testPetsAreTaggedEvenWhenNotPreferredOrNotTheBestMatch() {
        let tagger = MultiLabelTagger(catalog: .builtIn, promptEmbeddings: [
            "cat": [TestDatabase.vector(0)],
            "cafe": [TestDatabase.vector(1)],
        ])
        var v = [Float](repeating: 0, count: 16)
        v[0] = 0.26; v[1] = 0.30; v[2] = (1 - 0.26 * 0.26 - 0.30 * 0.30).squareRoot()
        let tags = accepted(tagger.suggestTags(for: v, preferredTopLevelIds: ["food_drink"]))
        XCTAssertTrue(tags.contains("cat"), "沒選動物、貓比咖啡廳低 0.04，仍要標上貓")
        XCTAssertTrue(tags.contains("cafe"))
    }

    /// 畢業典禮不算演唱會（v21、v22 移除畢業、婚禮後，改由演唱會的容易誤認畫面擋掉；v25 Live House 併入演唱會）；展覽不算舞台劇
    func testCeremoniesAndExhibitionsAreNotShows() {
        let tagger = MultiLabelTagger(catalog: .builtIn, promptEmbeddings: [
            "concert": [TestDatabase.vector(0)],
            TaxonomyNode.confuserKey("concert"): [TestDatabase.vector(1)],
            "theater_show": [TestDatabase.vector(2)],
            "exhibition": [TestDatabase.vector(3)],
        ])
        XCTAssertNil(tagger.suggestTags(for: image([0: 1, 1: 1])).first { $0.nodeId == "concert" })
        XCTAssertNil(tagger.suggestTags(for: image([2: 1, 3: 1])).first { $0.nodeId == "theater_show" })
    }

    func testConfuserAlsoBlocksContextQuestion() {
        let tagger = MultiLabelTagger(catalog: .builtIn, promptEmbeddings: [
            "concert": [TestDatabase.vector(0)],
            TaxonomyNode.confuserKey("concert"): [TestDatabase.vector(1)],
        ])
        XCTAssertNil(tagger.suggestTags(for: image([0: 1, 1: 1])).first { $0.nodeId == "concert" },
                     "店門口合照不會被問「這是演唱會嗎？」")
        XCTAssertEqual(tagger.suggestTags(for: image([0: 1, 1: 0.2])).first { $0.nodeId == "concert" }?.status, .candidate)
    }

    func testConfuserBlocksLiveEventSeed() {
        let prompts: [String: [[Float]]] = [
            "concert": [TestDatabase.vector(0)],
            TaxonomyNode.confuserKey("concert"): [TestDatabase.vector(1)],
            "cat": [TestDatabase.vector(2)],
        ]
        XCTAssertNil(LiveEventDetector.seed(for: image([0: 1, 1: 1]), prompts: prompts))
        XCTAssertEqual(LiveEventDetector.seed(for: image([0: 1, 1: 0.2]), prompts: prompts)?.nodeId, "concert")
        // 容易誤認的畫面不算「這張照片最像的分類」，不會反過來擋掉其他演唱會照片
        XCTAssertEqual(LiveEventDetector.seed(for: image([0: 1, 3: 0.5]), prompts: prompts)?.nodeId, "concert")
    }

    /// 動漫特展的角色看板：至少一樣像「展覽」或「周邊」時不算演唱會的起點（v25）
    func testExhibitionPhotosAreNotConcertSeeds() {
        let prompts: [String: [[Float]]] = [
            "concert": [TestDatabase.vector(0)],
            "exhibition": [TestDatabase.vector(2)],
            "cat": [TestDatabase.vector(3)],
        ]
        XCTAssertNil(LiveEventDetector.seed(for: image([0: 1, 2: 1]), prompts: prompts))
        XCTAssertEqual(LiveEventDetector.seed(for: image([0: 1, 2: 0.2]), prompts: prompts)?.nodeId, "concert")
        let matrix = PromptMatrix(prompts)
        XCTAssertTrue(LiveEventDetector.isRival(image([0: 1, 2: 1]), matrix: matrix, profile: .concert))
        XCTAssertFalse(LiveEventDetector.isRival(image([0: 1, 2: 0.2]), matrix: matrix, profile: .concert))
        XCTAssertFalse(LiveEventDetector.isRival(image([0: 1, 2: 1]), matrix: matrix, profile: .themePark), "主題樂園沒有對手分類")
    }

    func testStoreKeepsConfuserPromptsSeparateFromCategories() throws {
        let store = try TestDatabase.makeStore()
        let pending = try store.promptsNeedingEmbedding()
        let confuser = try XCTUnwrap(pending.first { $0.nodeId == TaxonomyNode.confuserKey("running") })
        let real = try XCTUnwrap(pending.first { $0.nodeId == "running" })
        try store.savePromptEmbedding(nodeId: confuser.nodeId, prompt: confuser.prompt, embedding: TestDatabase.vector(1))
        try store.savePromptEmbedding(nodeId: real.nodeId, prompt: real.prompt, embedding: TestDatabase.vector(0))

        let loaded = try store.loadPromptEmbeddings()
        XCTAssertNotNil(loaded["running"])
        XCTAssertNotNil(loaded["running#not"])
        XCTAssertNil(TaxonomyCatalog.builtIn.node("running#not"), "混淆畫面不是分類，不會被標到照片上")
    }
}

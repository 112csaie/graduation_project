import XCTest
import SQLite
@testable import PersonalizationCore

/// 驗收 6–8：多標籤、跨分類、主題相簿、未選取分類照樣辨識；以及標記器不誇大模型能力。
final class MultiLabelTaggingTests: XCTestCase {

    /// 以正交單位向量模擬文字向量：照片向量 = 幾個概念向量的組合。
    private func makeTagger(_ mapping: [String: Int], thresholds: TaggingThresholds = .default) -> MultiLabelTagger {
        var embeddings: [String: [[Float]]] = [:]
        for (nodeId, axis) in mapping { embeddings[nodeId] = [TestDatabase.vector(axis)] }
        return MultiLabelTagger(catalog: .builtIn, promptEmbeddings: embeddings, thresholds: thresholds)
    }

    private func image(_ weights: [Int: Float]) -> [Float] {
        var v = [Float](repeating: 0, count: 16)
        for (axis, weight) in weights { v[axis] = weight }
        return MultiLabelTagger.normalized(v)
    }

    // 7. 一張照片可以有多個內容標籤（不只保留最高分）
    func testPhotoGetsMultipleAcceptedTags() {
        let tagger = makeTagger(["stuffed_toy": 0, "cake": 1, "cafe": 2, "cat": 3])
        let suggestions = tagger.suggestTags(for: image([0: 1, 1: 1, 2: 1]))   // 玩偶 + 蛋糕 + 咖啡廳
        let accepted = Set(suggestions.filter { $0.status == .accepted }.map(\.nodeId))
        XCTAssertEqual(accepted, ["stuffed_toy", "cake", "cafe"])
        XCTAssertFalse(suggestions.contains { $0.nodeId == "cat" })
    }

    /// 動物種類只標最像的一種：狗的照片「貓」分數也很接近時，不會兩個都標
    func testOnlyOneAnimalSpeciesPerPhoto() {
        let tagger = makeTagger(["dog": 0, "cat": 1, "cafe": 2])
        let suggestions = tagger.suggestTags(for: image([0: 1, 1: 0.95, 2: 0.9]))
        let accepted = Set(suggestions.filter { $0.status == .accepted }.map(\.nodeId))
        XCTAssertTrue(accepted.contains("dog"))
        XCTAssertFalse(accepted.contains("cat"))
        XCTAssertTrue(accepted.contains("cafe"))   // 其他分類不受影響
    }

    /// 訓練過的判斷器：很確定是 → 標上（不看文字描述）；一定不是 → 擋掉；中間 → 照舊用文字描述比對
    func testLearnedClassifierAcceptsRejectsOrDefers() {
        var embeddings: [String: [[Float]]] = [:]
        embeddings["cake"] = [TestDatabase.vector(0)]
        embeddings["cafe"] = [TestDatabase.vector(1)]
        // 判斷器只看第 2 軸：照片在第 2 軸越大越像蛋糕
        var w = [Float](repeating: 0, count: 16); w[2] = 20
        let cake = LearnedTagClassifier(nodeId: "cake", weights: w, bias: -10, threshold: 0.9, rejectBelow: 0.05)
        let tagger = MultiLabelTagger(catalog: .builtIn, promptEmbeddings: embeddings, classifiers: ["cake": cake])
        let accepted = { (v: [Float]) in Set(tagger.suggestTags(for: v).filter { $0.status == .accepted }.map(\.nodeId)) }
        // 判斷器很確定（文字描述不太像也標上）
        XCTAssertTrue(accepted(image([2: 1, 1: 0.6])).contains("cake"))
        // 文字描述很像，但判斷器說一定不是 → 不標
        XCTAssertFalse(accepted(image([0: 1, 3: 0.2])).contains("cake"))
        // 判斷器沒把握（機率約 0.5）→ 交給文字描述比對：很像就標
        XCTAssertTrue(accepted(image([0: 1, 2: 0.55])).contains("cake"))
    }

    func testLowConfidenceVisualTagIsDroppedNotSentForReview() {
        let tagger = makeTagger(["noodle_dish": 0, "sushi": 1])
        // 麵食 ≈ 0.97 → 已確認；壽司 ≈ 0.23 → 分數不夠，直接略過（不再丟給使用者確認）
        let suggestions = tagger.suggestTags(for: image([0: 1, 1: 0.24]))
        XCTAssertEqual(suggestions.first { $0.nodeId == "noodle_dish" }?.status, .accepted)
        XCTAssertNil(suggestions.first { $0.nodeId == "sushi" })
    }

    /// 4,000 張照片不應產生上千個待確認：每張最多 1 個，且只問模型真的無法判斷的情境。
    func testAtMostOneQuestionPerPhoto() {
        let tagger = makeTagger(["concert": 0, "cheering_goods": 1, "cosplay": 2, "stuffed_toy": 3, "cake": 4])
        let suggestions = tagger.suggestTags(for: image([0: 1, 1: 1, 2: 1, 3: 1, 4: 1]))
        XCTAssertLessThanOrEqual(suggestions.filter { $0.status == .candidate }.count, 1)
    }

    func testDerivedSceneNeedsAcceptedComponents() {
        let tagger = makeTagger(["portrait": 0, "landmark": 1])
        // 地標分數不足（未確認）→ 不推論「旅行合照」
        let suggestions = tagger.suggestTags(for: image([0: 1, 1: 0.22]))
        XCTAssertNil(suggestions.first { $0.nodeId == "travel_group_photo" })
    }

    func testContextQuestionsOnlyForPreferredCategories() {
        let tagger = makeTagger(["concert": 0, "noodle_dish": 1])
        let photo = image([0: 1, 1: 1])
        // 沒選「音樂與表演」→ 不會問「這是演唱會嗎？」
        let foodOnly = tagger.suggestTags(for: photo, preferredTopLevelIds: ["food_drink"])
        XCTAssertNil(foodOnly.first { $0.nodeId == "concert" })
        // 喜歡音樂演出（興趣相關細分類包含演唱會）→ 會問
        let fan = tagger.suggestTags(for: photo, preferredTopLevelIds: ["music_shows"], boostedNodeIds: ["concert"])
        XCTAssertEqual(fan.first { $0.nodeId == "concert" }?.status, .candidate)
    }

    func testScoresBelowCandidateThresholdAreDropped() {
        let tagger = makeTagger(["noodle_dish": 0, "cat": 1])
        let suggestions = tagger.suggestTags(for: image([0: 1, 1: 0.1]))
        XCTAssertFalse(suggestions.contains { $0.nodeId == "cat" }, "低於 0.21 的結果不應被當成標籤")
    }

    func testAcceptedTagsAreCapped() {
        var mapping: [String: Int] = [:]
        let ids = ["noodle_dish", "sushi", "bbq", "cake", "ice_cream", "coffee"]
        for (index, id) in ids.enumerated() { mapping[id] = index }
        let tagger = makeTagger(mapping)
        let suggestions = tagger.suggestTags(for: image(Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, Float(1)) })))
        XCTAssertLessThanOrEqual(suggestions.filter { $0.status == .accepted }.count, TaggingThresholds.default.maxAccepted)
    }

    func testContextualCategoriesAreNeverAutoConfirmed() {
        // 演唱會（assisted）即使分數很高也只會是候選；簽名會（manualOnly）永遠不會自動出現。
        let tagger = makeTagger(["concert": 0, "fansign": 1])
        let suggestions = tagger.suggestTags(for: image([0: 1, 1: 1]))
        XCTAssertEqual(suggestions.first { $0.nodeId == "concert" }?.status, .candidate)
        XCTAssertNil(suggestions.first { $0.nodeId == "fansign" })
    }

    func testDerivedSceneIsOnlyACandidate() {
        let tagger = makeTagger(["portrait": 0, "landmark": 1, "cake": 2])
        let trip = tagger.suggestTags(for: image([0: 1, 1: 1]))
        XCTAssertEqual(trip.first { $0.nodeId == "travel_group_photo" }?.status, .candidate,
                       "合照 + 地標 只能推論為「待確認」，不能當成確定事實")
        let party = tagger.suggestTags(for: image([0: 1, 2: 1]))
        XCTAssertNil(party.first { $0.nodeId == "travel_group_photo" }, "沒有地點線索時不應推論旅行合照")
    }

    // 6. 未選取的分類仍可辨識與搜尋；8. 一張照片屬於多個分類與主題相簿
    func testUnselectedCategoriesStillRecognizedAndPhotoBelongsToManyCategories() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "multi@example.com", displayName: nil)
        try store.saveTopLevelSelection(userId: userId, topLevelIds: ["food_drink"])   // 沒有選「動物與寵物」
        try TestDatabase.insertPhoto(store.db, assetId: "photo-1", owner: userId, embedding: image([0: 1, 1: 1, 2: 1]))

        let tagger = makeTagger(["cat": 0, "cake": 1, "stuffed_toy": 2])
        let version = MultiLabelTagger.version(catalog: .builtIn)
        let pending = try store.assetsPendingTagging(userId: userId, taggerVersion: version, limit: 10)
        XCTAssertEqual(pending.map(\.assetId), ["photo-1"])
        try store.applyAutoTags(userId: userId, assetId: "photo-1", suggestions: tagger.suggestTags(for: pending[0].embedding), taggerVersion: version)

        XCTAssertEqual(try store.assetIds(userId: userId, matchingAll: ["cat"]), ["photo-1"], "未選取的分類仍可辨識")
        XCTAssertEqual(try store.assetIds(userId: userId, matchingAll: ["animals_pets"]), ["photo-1"])
        XCTAssertEqual(try store.assetIds(userId: userId, matchingAll: ["food_drink"]), ["photo-1"])
        XCTAssertEqual(try store.assetIds(userId: userId, matchingAll: ["items_collections"]), ["photo-1"])
        XCTAssertEqual(try store.assetIds(userId: userId, matchingAll: ["cake", "stuffed_toy"]), ["photo-1"], "跨分類搜尋（AND）")
        XCTAssertEqual(try store.assetIds(userId: userId, matchingAll: ["cake", "noodle_dish"]), [])

        let counts = try store.photoCountsByNode(userId: userId)
        XCTAssertEqual(counts["food_drink"], 1)
        XCTAssertEqual(counts["animals_pets"], 1)
        XCTAssertEqual(counts["items_collections"], 1)

        // 同一張照片加入兩本主題相簿（只存參照，不複製檔案）
        try store.db.run("INSERT INTO UserAlbums (album_id, title, owner_user_id) VALUES ('a1', '我的收藏', ?), ('a2', '2026 日本旅行', ?)", userId, userId)
        try store.db.run("INSERT INTO UserAlbumPhotos (album_id, asset_id, position) VALUES ('a1', 'photo-1', 0), ('a2', 'photo-1', 0)")
        XCTAssertEqual(Set(try store.themeAlbums(containing: "photo-1", userId: userId).map(\.title)), ["我的收藏", "2026 日本旅行"])

        // 已標記的照片不會在同版本再次被處理（避免重複計算）
        XCTAssertTrue(try store.assetsPendingTagging(userId: userId, taggerVersion: version, limit: 10).isEmpty)
    }

    /// 使用者沒選的大分類：仍會辨識，但自動確認需要更高分數（減少不相關分類的誤判）。
    func testUnpreferredCategoriesNeedHigherConfidence() {
        let tagger = makeTagger(["noodle_dish": 0, "cat": 1])
        var v = [Float](repeating: 0, count: 16)
        v[0] = 0.26; v[1] = 0.26; v[2] = (1 - 2 * 0.26 * 0.26).squareRoot()   // 麵食與貓分數都 ≈ 0.26
        let noPreference = tagger.suggestTags(for: v)
        XCTAssertEqual(noPreference.first { $0.nodeId == "cat" }?.status, .accepted)

        let foodLover = tagger.suggestTags(for: v, preferredTopLevelIds: ["food_drink"])
        XCTAssertEqual(foodLover.first { $0.nodeId == "noodle_dish" }?.status, .accepted, "選取的分類門檻 0.24")
        XCTAssertNil(foodLover.first { $0.nodeId == "cat" }, "沒選的分類需要 0.28 才會自動加入，也不會丟給使用者確認")

        var strong = [Float](repeating: 0, count: 16)
        strong[1] = 0.9; strong[2] = (1 - 0.81).squareRoot()
        XCTAssertEqual(tagger.suggestTags(for: strong, preferredTopLevelIds: ["food_drink"]).first { $0.nodeId == "cat" }?.status,
                       .accepted, "沒選的分類仍會辨識（分數夠高時）")
    }

    func testManualTagsWinOverAutomaticRetagging() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "manual@example.com", displayName: nil)
        try TestDatabase.insertPhoto(store.db, assetId: "p", owner: userId)
        let version = MultiLabelTagger.version(catalog: .builtIn)

        try store.applyAutoTags(userId: userId, assetId: "p", suggestions: [
            TagSuggestion(nodeId: "cat", score: 0.3, status: .accepted),
            TagSuggestion(nodeId: "concert", score: 0.22, status: .candidate),
        ], taggerVersion: version)
        try store.rejectTag(userId: userId, assetId: "p", nodeId: "cat")
        try store.addOrConfirmTag(userId: userId, assetId: "p", nodeId: "fansign")   // 只能手動

        // 再次自動標記：使用者拒絕過的 cat 不會被加回；手動加入的簽名會保留
        try store.applyAutoTags(userId: userId, assetId: "p", suggestions: [
            TagSuggestion(nodeId: "cat", score: 0.31, status: .accepted),
        ], taggerVersion: version + "-next")

        let tags = Dictionary(uniqueKeysWithValues: try store.tags(userId: userId, assetId: "p").map { ($0.nodeId, $0) })
        XCTAssertEqual(tags["cat"]?.status, .rejected)
        XCTAssertEqual(tags["cat"]?.source, .manual)
        XCTAssertEqual(tags["fansign"]?.status, .accepted)
        XCTAssertNil(tags["concert"], "舊的自動候選會被新結果取代")
    }

    func testTaggingIsScopedPerUser() throws {
        let store = try TestDatabase.makeStore()
        let alice = try store.resolveUser(email: "alice@example.com", displayName: nil)
        let bob = try store.resolveUser(email: "bob@example.com", displayName: nil)
        XCTAssertNotEqual(alice, bob)
        try TestDatabase.insertPhoto(store.db, assetId: "shared", owner: alice)
        try store.addOrConfirmTag(userId: alice, assetId: "shared", nodeId: "cat")
        XCTAssertEqual(try store.assetIds(userId: alice, matchingAll: ["cat"]), ["shared"])
        XCTAssertEqual(try store.assetIds(userId: bob, matchingAll: ["cat"]), [])
    }

    func testEmbeddingCodecMatchesExistingBlobFormat() {
        let vector: [Float] = [0.25, -1.5, 3.0, 0]
        let bytes = EmbeddingCodec.encode(vector)
        XCTAssertEqual(bytes.count, vector.count * 4, "與既有 PhotoFeatures.image_embedding 相同：連續 Float32")
        XCTAssertEqual(EmbeddingCodec.decode(bytes), vector)
    }

    /// 聊天截圖（例如吉伊卡哇主題的 LINE）和漫畫截圖一樣像時，不算漫畫截圖；真正的漫畫截圖不受影響。
    func testChatScreenshotSuppressesMangaScreenshot() {
        let tagger = makeTagger(["manga": 0, "chat_screenshot": 1])
        let chat = Set(tagger.suggestTags(for: image([0: 1, 1: 1])).filter { $0.status == .accepted }.map(\.nodeId))
        XCTAssertEqual(chat, ["chat_screenshot"])

        let manga = Set(tagger.suggestTags(for: image([0: 1, 1: 0.3])).filter { $0.status == .accepted }.map(\.nodeId))
        XCTAssertEqual(manga, ["manga"])
    }

    func testOtherMerchOptionRemoved() {
        XCTAssertNil(TaxonomyCatalog.builtIn.node("anime_merch"))
        XCTAssertEqual(TaxonomyCatalog.builtIn.nodeRedirects["anime_merch"], "collectibles")
        XCTAssertEqual(TaxonomyCatalog.builtIn.node("figure")?.parentId, "collectibles")
    }

    /// 具體料理（火鍋、麵食…）要比一般「餐點」明顯更像才自動標記，避免複雜的菜都被當成火鍋。
    func testSpecificDishMustBeatGenericMeal() {
        let tagger = makeTagger(["restaurant_meal": 0, "hotpot": 1])
        let ambiguous = Set(tagger.suggestTags(for: image([0: 1, 1: 1])).filter { $0.status == .accepted }.map(\.nodeId))
        XCTAssertEqual(ambiguous, ["restaurant_meal"], "和一般餐點一樣像 → 只標「餐點」")

        let clear = Set(tagger.suggestTags(for: image([0: 0.5, 1: 1])).filter { $0.status == .accepted }.map(\.nodeId))
        XCTAssertEqual(clear, ["hotpot"], "明顯更像火鍋 → 標「火鍋」")
    }
}

/// 預先計算的分類文字向量：從另一個 SQLite 檔（App 內附的 PhotoAI.sqlite）唯讀匯入。
final class PrecomputedPromptEmbeddingTests: XCTestCase {
    func testImportsOnlyMissingPromptsFromBundledDatabase() throws {
        let store = try TestDatabase.makeStore()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bundled = try Connection(path)
        try bundled.execute("""
        CREATE TABLE PrecomputedPromptEmbeddings (prompt TEXT PRIMARY KEY, embedding BLOB NOT NULL, template TEXT NOT NULL, model TEXT NOT NULL);
        """)
        let vector = [Float](repeating: 1 / Float(512).squareRoot(), count: 512)
        try bundled.run("INSERT INTO PrecomputedPromptEmbeddings VALUES (?, ?, 'a photo of', 'test')",
                        "sushi", Blob(bytes: EmbeddingCodec.encode(vector)))
        try bundled.run("INSERT INTO PrecomputedPromptEmbeddings VALUES (?, ?, 'a photo of', 'test')",
                        "a bad vector", Blob(bytes: [1, 2, 3]))

        let before = try store.promptsNeedingEmbedding().count
        XCTAssertEqual(try store.importPrecomputedPromptEmbeddings(fromDatabaseAt: path), 1)
        XCTAssertEqual(try store.promptsNeedingEmbedding().count, before - 1)
        XCTAssertFalse(try store.promptsNeedingEmbedding().contains { $0.prompt == "sushi" })
        XCTAssertEqual(try store.importPrecomputedPromptEmbeddings(fromDatabaseAt: path), 0, "已有向量的不重複匯入")
        XCTAssertEqual(try store.importPrecomputedPromptEmbeddings(fromDatabaseAt: "/no/such/file.sqlite"), 0)
    }
}

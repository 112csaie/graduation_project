import XCTest
@testable import PersonalizationCore

/// 個人 Wiki 筆記存在手機資料庫：儲存、主題命名、搜尋計分、照片連結。
final class WikiStoreTests: XCTestCase {

    private var store: PersonalizationStore!
    private var userId: String!
    private let model = "test-model"

    override func setUpWithError() throws {
        store = try TestDatabase.makeStore()
        userId = try store.resolveUser(email: "wiki@example.com", displayName: nil)
    }

    override func tearDown() { store = nil }

    func testTokenizeMatchesBackend() {
        XCTAssertEqual(WikiText.tokenize("東京自由行 Day1"), ["東京", "京自", "自由", "由行", "day1"])
        XCTAssertEqual(WikiText.tokenize("貓"), ["貓"])
        XCTAssertEqual(WikiText.tokenize("KFC優惠"), ["kfc", "優惠"])
    }

    func testSaveUpdateAndDelete() throws {
        try store.saveWikiNote(userId: userId, topic: "拉麵", summary: "s1", content: "c1", embedding: [1, 0], embeddingModel: model)
        try store.saveWikiNote(userId: userId, topic: "拉麵", summary: "s2", content: "c2", embedding: [0, 1], embeddingModel: model)
        let notes = try store.wikiNotes(userId: userId)
        XCTAssertEqual(notes.map(\.topic), ["拉麵"])
        XCTAssertEqual(notes.first?.summary, "s2", "同一個主題是更新，不是新增")
        XCTAssertNotNil(notes.first?.createdAt)

        try store.linkWikiPhotos(userId: userId, topic: "拉麵", assetIds: ["A", "B", "A"])
        XCTAssertEqual(try store.wikiPhotoAssetIds(userId: userId, topic: "拉麵"), ["A", "B"])
        XCTAssertEqual(try store.wikiTopics(containing: "B", userId: userId), ["拉麵"])

        XCTAssertTrue(try store.deleteWikiNote(userId: userId, topic: "拉麵"))
        XCTAssertTrue(try store.wikiNotes(userId: userId).isEmpty)
        XCTAssertTrue(try store.wikiPhotoAssetIds(userId: userId, topic: "拉麵").isEmpty, "照片連結一起刪除")
        XCTAssertFalse(try store.deleteWikiNote(userId: userId, topic: "拉麵"))
    }

    func testNotesAreSeparatedByUser() throws {
        let other = try store.resolveUser(email: "other@example.com", displayName: nil)
        try store.saveWikiNote(userId: userId, topic: "我的", summary: "", content: "x", embedding: nil, embeddingModel: nil)
        XCTAssertTrue(try store.wikiNotes(userId: other).isEmpty)
    }

    func testUniqueTopicLimitsLengthAndAvoidsOverwrite() throws {
        XCTAssertEqual(try store.uniqueWikiTopic(userId: userId, proposed: "一二三四五六七八九十十一", preserveExisting: false), "一二三四五六七八九十")
        try store.saveWikiNote(userId: userId, topic: "台北美食", summary: "", content: "x", embedding: nil, embeddingModel: nil)
        XCTAssertEqual(try store.uniqueWikiTopic(userId: userId, proposed: "台北美食", preserveExisting: false), "台北美食(2)")
        XCTAssertEqual(try store.uniqueWikiTopic(userId: userId, proposed: "台北美食", preserveExisting: true), "台北美食", "更新既有筆記沿用原主題")
    }

    func testNotesNeedingEmbedding() throws {
        try store.saveWikiNote(userId: userId, topic: "a", summary: "", content: "x", embedding: nil, embeddingModel: nil)
        try store.saveWikiNote(userId: userId, topic: "b", summary: "", content: "x", embedding: [1], embeddingModel: "old")
        try store.saveWikiNote(userId: userId, topic: "c", summary: "", content: "x", embedding: [1], embeddingModel: model)
        XCTAssertEqual(Set(try store.wikiNotesNeedingEmbedding(userId: userId, model: model).map(\.topic)), ["a", "b"])
        try store.updateWikiEmbedding(userId: userId, topic: "a", embedding: [1], model: model)
        XCTAssertEqual(Set(try store.wikiNotesNeedingEmbedding(userId: userId, model: model).map(\.topic)), ["b"])
    }

    func testSearchScoringAndPenaltyAppliedOnce() throws {
        try store.saveWikiNote(userId: userId, topic: "東京自由行", summary: "五天四夜行程", content: "淺草、澀谷",
                               embedding: [1, 0], embeddingModel: model)
        try store.saveWikiNote(userId: userId, topic: "航班票價", summary: "比價", content: "路線查詢",
                               embedding: [1, 0], embeddingModel: model)
        let identity: (Float) -> Double = { Double($0) }

        let result = try store.searchWikiNotes(userId: userId, query: "東京自由行", queryVector: [1, 0], model: model,
                                               minScore: 0.45, calibrate: identity)
        XCTAssertEqual(result.status, "exact")
        XCTAssertEqual(result.exact?.note.topic, "東京自由行")
        XCTAssertEqual(result.candidates.map(\.note.topic), ["東京自由行", "航班票價"],
                       "語意一樣像時，有共同字詞（而且主題相同）的筆記排前面")
        // 沒有共同字詞：1.0 × 0.6 = 0.6（扣一次；以前扣兩次會變 0.36）
        XCTAssertEqual(result.candidates.last?.score ?? -1, 0.6, accuracy: 1e-6)
        XCTAssertEqual(result.candidates.first?.score ?? -1, 1.0, accuracy: 1e-6)

        // 語意普通、又沒有共同字詞 → 低於門檻
        let weak = try store.searchWikiNotes(userId: userId, query: "健身菜單", queryVector: [0.6, 0.8], model: model,
                                             minScore: 0.45, calibrate: identity)
        XCTAssertEqual(weak.status, "none")
    }

    func testPartialKeywordFindsNote() throws {
        try store.saveWikiNote(userId: userId, topic: "亞尼克原味生乳捲", summary: "一盒生乳捲", content: "保存期限三天",
                               embedding: [1, 0], embeddingModel: model)
        let identity: (Float) -> Double = { Double($0) }
        // 語意分數很低（向量幾乎正交），但關鍵字出現在主題裡
        let byTopic = try store.searchWikiNotes(userId: userId, query: "生乳捲", queryVector: [0.05, 1], model: model,
                                                minScore: 0.35, calibrate: identity)
        XCTAssertEqual(byTopic.candidates.first?.note.topic, "亞尼克原味生乳捲")
        XCTAssertGreaterThanOrEqual(byTopic.candidates.first?.score ?? 0, 0.8)
        // 只出現在內文
        let byContent = try store.searchWikiNotes(userId: userId, query: "保存期限", queryVector: [0.05, 1], model: model,
                                                  minScore: 0.35, calibrate: identity)
        XCTAssertEqual(byContent.candidates.first?.note.topic, "亞尼克原味生乳捲")
        // 單一字不比對內文，避免太多雜訊
        let single = try store.searchWikiNotes(userId: userId, query: "期", queryVector: [0.05, 1], model: model,
                                               minScore: 0.35, calibrate: identity)
        XCTAssertEqual(single.status, "none")
    }

    func testEditRenameAndUnlink() throws {
        try store.saveWikiNote(userId: userId, topic: "東京", summary: "s", content: "c", embedding: nil, embeddingModel: nil)
        try store.saveWikiNote(userId: userId, topic: "大阪", summary: "s", content: "c", embedding: nil, embeddingModel: nil)
        try store.linkWikiPhotos(userId: userId, topic: "東京", assetIds: ["A", "B"])

        try store.editWikiNote(userId: userId, oldTopic: "東京", newTopic: "東京八日遊", summary: "新摘要", content: "新內容",
                               embedding: [1], embeddingModel: model)
        XCTAssertNil(try store.wikiNote(userId: userId, topic: "東京"))
        XCTAssertEqual(try store.wikiNote(userId: userId, topic: "東京八日遊")?.summary, "新摘要")
        XCTAssertEqual(try store.wikiPhotoAssetIds(userId: userId, topic: "東京八日遊"), ["A", "B"], "照片連結跟著改名")

        XCTAssertThrowsError(try store.editWikiNote(userId: userId, oldTopic: "東京八日遊", newTopic: "大阪", summary: "", content: "x",
                                                    embedding: nil, embeddingModel: nil), "不能改成別篇的名字")
        XCTAssertThrowsError(try store.editWikiNote(userId: userId, oldTopic: "東京八日遊", newTopic: "一二三四五六七八九十十一",
                                                    summary: "", content: "x", embedding: nil, embeddingModel: nil), "主題最多 10 字")

        try store.unlinkWikiPhoto(userId: userId, topic: "東京八日遊", assetId: "A")
        XCTAssertEqual(try store.wikiPhotoAssetIds(userId: userId, topic: "東京八日遊"), ["B"])
    }

    func testCompactHelpers() {
        XCTAssertEqual(WikiText.compactContent("a\n a \nb\n\nb"), "a\nb")
        XCTAssertTrue(WikiText.needsRewrite("TODO"))
        XCTAssertTrue(WikiText.needsRewrite("  "))
        XCTAssertFalse(WikiText.needsRewrite("內容"))
        XCTAssertEqual(WikiText.compactSummary("一  二\n三").count, 5)
    }
}

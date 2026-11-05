import XCTest
import SQLite
@testable import PersonalizationCore

/// 我的 IP：用範例照片比對、回答會成為範例／反例、資料只影響 App 自己的分類。
final class CustomCategoryTests: XCTestCase {

    /// 與 e0 的相似度為 cos 的單位向量（落在 e0–e(axis) 平面上）。
    private func vector(similarTo cos: Float, axis: Int = 1, dims: Int = 16) -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        v[0] = cos
        v[axis] = (1 - cos * cos).squareRoot()
        return v
    }

    // MARK: 比對規則

    func testMatcherAcceptsNearDuplicatesAsksForSimilarAndIgnoresUnrelated() {
        let positives = [TestDatabase.vector(0)]
        let photos: [(assetId: String, embedding: [Float])] = [
            ("same", vector(similarTo: 0.93)),       // 幾乎同一件周邊 → 自動加入
            ("similar", vector(similarTo: 0.78)),    // 有點像 → 待確認
            ("unrelated", vector(similarTo: 0.40)),  // 不像 → 不處理
            ("example", TestDatabase.vector(0)),     // 範例本身 → 不重複判斷
        ]
        let result = ReferenceMatcher.match(positives: positives, negatives: [], photos: photos, excluded: ["example"])
        XCTAssertEqual(result.map(\.assetId), ["same", "similar"])
        XCTAssertEqual(result.map(\.status), [.accepted, .candidate])
    }

    func testRejectedPhotosActAsCounterExamples() {
        let positives = [TestDatabase.vector(0)]
        let negative = vector(similarTo: 0.80, axis: 2)
        // 與範例 0.78，但與使用者說過「不是」的照片更像 → 不再詢問
        let lookalike = MultiLabelTagger.normalized(zip(vector(similarTo: 0.78, axis: 2), negative).map { $0 + $1 })
        let result = ReferenceMatcher.match(positives: positives, negatives: [negative],
                                            photos: [("lookalike", lookalike)], excluded: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testCandidatesAreCapped() {
        var thresholds = ReferenceMatchThresholds.default
        thresholds.maxCandidates = 2
        let photos = (0..<5).map { (assetId: "p\($0)", embedding: vector(similarTo: 0.75 + Float($0) * 0.01)) }
        let result = ReferenceMatcher.match(positives: [TestDatabase.vector(0)], negatives: [], photos: photos,
                                            excluded: [], thresholds: thresholds)
        XCTAssertEqual(result.map(\.assetId), ["p4", "p3"], "只保留分數最高的待確認")
    }

    func testNodeIdRoundTrip() {
        let category = CustomCategory(id: "ABC", kind: .ip, name: "咒術迴戰")
        XCTAssertEqual(category.nodeId, "ip:ABC")
        XCTAssertEqual(CustomCategory.parse(nodeId: "ip:ABC")?.id, "ABC")
        XCTAssertNil(CustomCategory.parse(nodeId: "ramen"))
        XCTAssertNil(CustomCategory.parse(nodeId: "ip:"))
    }

    // MARK: 資料庫

    private func makeStoreWithPhotos() throws -> (PersonalizationStore, String) {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "ip@example.com", displayName: nil)
        try TestDatabase.insertPhoto(store.db, assetId: "ex1", owner: userId, embedding: TestDatabase.vector(0))
        try TestDatabase.insertPhoto(store.db, assetId: "same", owner: userId, embedding: vector(similarTo: 0.93))
        try TestDatabase.insertPhoto(store.db, assetId: "maybe", owner: userId, embedding: vector(similarTo: 0.78))
        try TestDatabase.insertPhoto(store.db, assetId: "noVector", owner: userId, embedding: nil)
        return (store, userId)
    }

    func testSearchFindsPhotosByIPName() throws {
        let (store, userId) = try makeStoreWithPhotos()
        let series = try store.createCustomCategory(userId: userId, kind: .ip, name: "咒術迴戰", exampleAssetIds: ["ex1"])
        _ = try store.createCustomCategory(userId: userId, kind: .ip, name: "五條悟", exampleAssetIds: ["same"], parentId: series.id)
        XCTAssertEqual(try store.assetIds(userId: userId, matchingTagText: "五條悟的立牌"), ["same"], "搜尋字包含角色名稱")
        XCTAssertEqual(try store.assetIds(userId: userId, matchingTagText: "五條"), ["same"], "搜尋字是名稱的一部分")
        XCTAssertEqual(try store.assetIds(userId: userId, matchingTagText: "咒術迴戰"), ["ex1", "same"], "作品包含底下的角色")
        XCTAssertEqual(try store.assetIds(userId: userId, matchingTagText: "火影忍者"), [])
        XCTAssertEqual(try store.assetIds(userId: userId, matchingTagText: "悟"), [], "只有 1 個字時不比對名稱的一部分")
    }

    func testCreateRequiresNameAndScannedExamples() throws {
        let (store, userId) = try makeStoreWithPhotos()
        XCTAssertThrowsError(try store.createCustomCategory(userId: userId, kind: .ip, name: "  ", exampleAssetIds: ["ex1"]))
        XCTAssertThrowsError(try store.createCustomCategory(userId: userId, kind: .ip, name: "咒術迴戰", exampleAssetIds: ["noVector"]))
        let created = try store.createCustomCategory(userId: userId, kind: .ip, name: " 咒術迴戰 ", exampleAssetIds: ["ex1", "noVector"])
        XCTAssertEqual(created.name, "咒術迴戰")
        XCTAssertEqual(try store.customExamples(userId: userId, nodeId: created.nodeId).positives, ["ex1"])
        XCTAssertThrowsError(try store.createCustomCategory(userId: userId, kind: .ip, name: "咒術迴戰", exampleAssetIds: ["ex1"]),
                             "同名不可重複")
    }

    func testAnswersBecomeExamplesAndManualAnswersSurviveRematch() throws {
        let (store, userId) = try makeStoreWithPhotos()
        let ip = try store.createCustomCategory(userId: userId, kind: .ip, name: "寶可夢", exampleAssetIds: ["ex1"])
        try store.replaceAutoMatches(userId: userId, nodeId: ip.nodeId, matches: [
            ReferenceMatch(assetId: "same", score: 0.93, status: .accepted),
            ReferenceMatch(assetId: "maybe", score: 0.78, status: .candidate),
            ReferenceMatch(assetId: "ex1", score: 1, status: .accepted),   // 範例：手動資料優先，不會被覆蓋
        ])
        XCTAssertEqual(try store.candidateTags(userId: userId).map(\.nodeId), [ip.nodeId], "待確認出現在同一個清單")

        try store.rejectTag(userId: userId, assetId: "maybe", nodeId: ip.nodeId)   // 「不是」→ 反例
        try store.addOrConfirmTag(userId: userId, assetId: "same", nodeId: ip.nodeId) // 「是」→ 範例
        let examples = try store.customExamples(userId: userId, nodeId: ip.nodeId)
        XCTAssertEqual(Set(examples.positives), ["ex1", "same"])
        XCTAssertEqual(examples.negatives, ["maybe"])

        // 重新比對只取代自動結果
        try store.replaceAutoMatches(userId: userId, nodeId: ip.nodeId, matches: [])
        XCTAssertEqual(try store.customCategoryCounts(userId: userId)[ip.nodeId], 2)
        XCTAssertEqual(try store.tags(userId: userId, assetId: "maybe").first?.status, .rejected)
    }

    func testTaxonomyRetaggingDoesNotEraseIPMatchesButAIRemovalDoes() throws {
        let (store, userId) = try makeStoreWithPhotos()
        let ip = try store.createCustomCategory(userId: userId, kind: .ip, name: "排球少年", exampleAssetIds: ["ex1"])
        try store.replaceAutoMatches(userId: userId, nodeId: ip.nodeId, matches: [ReferenceMatch(assetId: "same", score: 0.93, status: .accepted)])

        try store.applyAutoTags(userId: userId, assetId: "same", suggestions: [TagSuggestion(nodeId: "cake", score: 0.3, status: .accepted)],
                                taggerVersion: "t")
        XCTAssertEqual(Set(try store.tags(userId: userId, assetId: "same").map(\.nodeId)), ["cake", ip.nodeId])

        _ = try store.removeAIAnalysis(userId: userId, assetId: "same")
        XCTAssertTrue(try store.tags(userId: userId, assetId: "same").isEmpty, "移除 AI 分析資料也會移除 IP 的自動比對結果")
        _ = try store.removeAIAnalysis(userId: userId, assetId: "ex1")
        XCTAssertEqual(try store.tags(userId: userId, assetId: "ex1").map(\.nodeId), [ip.nodeId], "使用者挑的範例（手動）保留")
    }

    func testDeleteOnlyRemovesThisCategoryAndOnlyForOwner() throws {
        let (store, userId) = try makeStoreWithPhotos()
        let other = try store.resolveUser(email: "other@example.com", displayName: nil)
        let a = try store.createCustomCategory(userId: userId, kind: .ip, name: "A", exampleAssetIds: ["ex1"])
        let b = try store.createCustomCategory(userId: userId, kind: .ip, name: "B", exampleAssetIds: ["ex1"])
        try store.addOrConfirmTag(userId: userId, assetId: "ex1", nodeId: "cake")

        XCTAssertThrowsError(try store.deleteCustomCategory(userId: other, categoryId: a.id), "其他帳號不能刪除")
        try store.deleteCustomCategory(userId: userId, categoryId: a.id)

        XCTAssertEqual(try store.customCategories(userId: userId).map(\.name), ["B"])
        XCTAssertEqual(Set(try store.tags(userId: userId, assetId: "ex1").map(\.nodeId)), ["cake", b.nodeId])
        XCTAssertNotNil(try TestDatabase.embeddingBytes(store.db, "ex1"), "照片向量不受影響")
        XCTAssertThrowsError(try store.addOrConfirmTag(userId: userId, assetId: "ex1", nodeId: a.nodeId), "已刪除的分類不能再加標籤")
    }

    // MARK: 作品／角色與封面

    func testCharacterBelongsToWorkAndOnlyTwoLevels() throws {
        let (store, userId) = try makeStoreWithPhotos()
        let work = try store.createCustomCategory(userId: userId, kind: .ip, name: "咒術迴戰", exampleAssetIds: ["ex1"])
        let character = try store.createCustomCategory(userId: userId, kind: .ip, name: "五條悟", exampleAssetIds: ["ex1"], parentId: work.id)
        XCTAssertEqual(try store.customCategories(userId: userId).first { $0.id == character.id }?.parentId, work.id)
        XCTAssertThrowsError(try store.createCustomCategory(userId: userId, kind: .ip, name: "第三層", exampleAssetIds: ["ex1"],
                                                           parentId: character.id), "最多兩層")

        // 刪除作品：角色保留，變成最上層
        try store.deleteCustomCategory(userId: userId, categoryId: work.id)
        let remaining = try store.customCategories(userId: userId)
        XCTAssertEqual(remaining.map(\.name), ["五條悟"])
        XCTAssertNil(remaining.first?.parentId)
    }

    func testCoverCanBeSetAndClearedOnlyByOwner() throws {
        let (store, userId) = try makeStoreWithPhotos()
        let other = try store.resolveUser(email: "cover@example.com", displayName: nil)
        let ip = try store.createCustomCategory(userId: userId, kind: .ip, name: "吉伊卡哇", exampleAssetIds: ["ex1"])
        try store.setCustomCategoryCover(userId: userId, categoryId: ip.id, assetId: "same")
        XCTAssertEqual(try store.customCategories(userId: userId).first?.coverAssetId, "same")
        XCTAssertThrowsError(try store.setCustomCategoryCover(userId: other, categoryId: ip.id, assetId: "ex1"))
        try store.setCustomCategoryCover(userId: userId, categoryId: ip.id, assetId: nil)
        XCTAssertNil(try store.customCategories(userId: userId).first?.coverAssetId)
    }

    // MARK: 同作品角色互為反例

    func testSiblingsAreCharactersOfTheSameWorkOnly() {
        let work = CustomCategory(id: "W", kind: .ip, name: "咒術迴戰")
        let gojo = CustomCategory(id: "G", kind: .ip, name: "五條悟", parentId: "W")
        let itadori = CustomCategory(id: "I", kind: .ip, name: "虎杖悠仁", parentId: "W")
        let pikachu = CustomCategory(id: "P", kind: .ip, name: "皮卡丘")
        let all = [work, gojo, itadori, pikachu]
        XCTAssertEqual(gojo.siblings(in: all).map(\.id), ["I"])
        XCTAssertTrue(work.siblings(in: all).isEmpty)
        XCTAssertTrue(pikachu.siblings(in: all).isEmpty)
    }

    func testSiblingExamplesKeepLookalikesOutOfTheQuestion() {
        let gojoExample = TestDatabase.vector(0)
        let itadoriExample = vector(similarTo: 0.80, axis: 2)
        // 與五條悟範例 0.78（會被問），但更像虎杖的範例 → 加上兄弟反例後不再出題
        let lookalike = MultiLabelTagger.normalized(zip(vector(similarTo: 0.78, axis: 2), itadoriExample).map { $0 + $1 })
        let alone = ReferenceMatcher.match(positives: [gojoExample], negatives: [], photos: [("p", lookalike)], excluded: [])
        XCTAssertEqual(alone.map(\.status), [.candidate])
        let withSiblings = ReferenceMatcher.match(positives: [gojoExample], negatives: [itadoriExample],
                                                  photos: [("p", lookalike)], excluded: [])
        XCTAssertTrue(withSiblings.isEmpty)
    }
}

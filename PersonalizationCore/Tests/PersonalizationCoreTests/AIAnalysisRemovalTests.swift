import XCTest
import SQLite
@testable import PersonalizationCore

/// 驗收 10–14：移除 AI 分析資料、權限、重新分析，以及原始照片不受影響。
final class AIAnalysisRemovalTests: XCTestCase {

    private var store: PersonalizationStore!
    private var alice: String!
    private var bob: String!
    private var original: FakeOriginalPhoto!

    override func setUpWithError() throws {
        store = try TestDatabase.makeStore()
        alice = try store.resolveUser(email: "alice@example.com", displayName: "Alice")
        bob = try store.resolveUser(email: "bob@example.com", displayName: "Bob")
        original = try FakeOriginalPhoto()

        let db = store.db
        try TestDatabase.insertPhoto(db, assetId: "A", owner: alice, embedding: TestDatabase.vector(1), clusterId: 1, favorite: true,
                                     metadata: "{\"date\":\"2026-05-01\",\"tripLocality\":\"Tokyo\"}")
        try TestDatabase.insertPhoto(db, assetId: "B", owner: alice, embedding: TestDatabase.vector(2))
        try TestDatabase.insertPhoto(db, assetId: "C", owner: bob, embedding: TestDatabase.vector(3))
        try db.run("INSERT INTO UserAlbums (album_id, title, owner_user_id) VALUES ('al1', '我的收藏', ?), ('al2', '某次演唱會', ?)", alice, alice)
        try db.run("INSERT INTO UserAlbumPhotos (album_id, asset_id, position) VALUES ('al1', 'A', 0), ('al2', 'A', 0), ('al1', 'B', 1)")

        let version = MultiLabelTagger.version(catalog: .builtIn)
        for asset in ["A", "B"] {
            try store.applyAutoTags(userId: alice, assetId: asset, suggestions: [
                TagSuggestion(nodeId: "stuffed_toy", score: 0.3, status: .accepted),
                TagSuggestion(nodeId: "cake", score: 0.22, status: .candidate),
            ], taggerVersion: version)
        }
        try store.addOrConfirmTag(userId: alice, assetId: "A", nodeId: "couple")   // 手動標籤
        try store.applyAutoTags(userId: bob, assetId: "C", suggestions: [
            TagSuggestion(nodeId: "cat", score: 0.3, status: .accepted),
        ], taggerVersion: version)
    }

    override func tearDown() {
        original = nil
        store = nil
    }

    // 10. 移除 AI 分析資料不會刪除或修改原始照片；12. 手動資料保留
    func testRemovingAIAnalysisOnlyRemovesAIData() throws {
        let db = store.db
        let report = try store.removeAIAnalysis(userId: alice, assetId: "A")

        try original.assertUnchanged()
        XCTAssertTrue(report.vectorRemoved)
        XCTAssertTrue(report.clusterCleared)
        XCTAssertEqual(report.autoTagsRemoved, 2)
        XCTAssertEqual(report.manualTagsKept, 1)
        XCTAssertEqual(report.albumMembershipsKept, 2)

        // 照片識別資訊、最愛、metadata 保留；向量、自動分類清除
        XCTAssertEqual(try TestDatabase.count(db, "SELECT COUNT(*) FROM PhotoFeatures WHERE asset_id = 'A'"), 1)
        XCTAssertNil(try TestDatabase.embeddingBytes(db, "A"))
        XCTAssertNil(try db.scalar("SELECT cluster_id FROM PhotoFeatures WHERE asset_id = 'A'"))
        XCTAssertEqual(try db.scalar("SELECT is_favorite FROM PhotoFeatures WHERE asset_id = 'A'") as? Int64, 1)
        XCTAssertEqual(try db.scalar("SELECT metadata FROM PhotoFeatures WHERE asset_id = 'A'") as? String,
                       "{\"date\":\"2026-05-01\",\"tripLocality\":\"Tokyo\"}")
        XCTAssertTrue(try store.isAIAnalysisRemoved(assetId: "A"))

        // 主題相簿與手動標籤保留
        XCTAssertEqual(Set(try store.themeAlbums(containing: "A", userId: alice).map(\.id)), ["al1", "al2"])
        let tags = try store.tags(userId: alice, assetId: "A")
        XCTAssertEqual(tags.map(\.nodeId), ["couple"])
        XCTAssertEqual(tags.first?.source, .manual)

        // 被移除的照片不會再被自動標記（等於同步流程不會自動重新分析）
        let pending = try store.assetsPendingTagging(userId: alice, taggerVersion: "new-version", limit: 10)
        XCTAssertFalse(pending.map(\.assetId).contains("A"))
        XCTAssertFalse(try store.applyAutoTags(userId: alice, assetId: "A", suggestions: [
            TagSuggestion(nodeId: "cat", score: 0.4, status: .accepted),
        ], taggerVersion: "late-write"), "處理中的舊結果不能在移除後寫回")
    }

    // 11. 移除某張照片的向量不影響其他照片
    func testRemovingOnePhotoDoesNotAffectOthers() throws {
        let db = store.db
        let beforeB = try TestDatabase.embeddingBytes(db, "B")
        let beforeC = try TestDatabase.embeddingBytes(db, "C")

        _ = try store.removeAIAnalysis(userId: alice, assetId: "A")

        XCTAssertEqual(try TestDatabase.embeddingBytes(db, "B"), beforeB)
        XCTAssertEqual(try TestDatabase.embeddingBytes(db, "C"), beforeC)
        XCTAssertEqual(try store.tags(userId: alice, assetId: "B").count, 2)
        XCTAssertEqual(try store.tags(userId: bob, assetId: "C").count, 1)
        XCTAssertEqual(try TestDatabase.count(db, "SELECT COUNT(*) FROM UserAlbumPhotos WHERE asset_id = 'B'"), 1)
        XCTAssertFalse(try store.isAIAnalysisRemoved(assetId: "B"))
    }

    // 13. 未經授權的使用者無法刪除其他使用者的向量資料
    func testOtherUserCannotRemoveVectors() throws {
        let db = store.db
        let before = try TestDatabase.embeddingBytes(db, "A")

        XCTAssertThrowsError(try store.removeAIAnalysis(userId: bob, assetId: "A")) { error in
            XCTAssertEqual(error as? PersonalizationError, .notAuthorized)
        }
        XCTAssertThrowsError(try store.removeAIAnalysis(userId: "", assetId: "A")) { error in
            XCTAssertEqual(error as? PersonalizationError, .notSignedIn)
        }
        XCTAssertThrowsError(try store.prepareReanalysis(userId: bob, assetId: "A")) { error in
            XCTAssertEqual(error as? PersonalizationError, .notAuthorized)
        }

        // 失敗的操作不留下任何變更（transaction 回滾）
        XCTAssertEqual(try TestDatabase.embeddingBytes(db, "A"), before)
        XCTAssertEqual(try store.tags(userId: alice, assetId: "A").count, 3)
        XCTAssertFalse(try store.isAIAnalysisRemoved(assetId: "A"))
    }

    func testLegacyUnownedDataCanBeClaimedAndRemovedByCurrentUser() throws {
        let db = store.db
        try TestDatabase.insertPhoto(db, assetId: "legacy", owner: nil)
        try store.claimLegacyData(for: alice)
        XCTAssertEqual(try db.scalar("SELECT owner_user_id FROM PhotoFeatures WHERE asset_id = 'legacy'") as? String, alice)
        XCTAssertThrowsError(try store.removeAIAnalysis(userId: bob, assetId: "legacy"))
        XCTAssertNoThrow(try store.removeAIAnalysis(userId: alice, assetId: "legacy"))
    }

    func testRemovingUnscannedPhotoPreventsFutureAnalysis() throws {
        let report = try store.removeAIAnalysis(userId: alice, assetId: "never-scanned")
        XCTAssertFalse(report.vectorRemoved)
        XCTAssertTrue(try store.isAIAnalysisRemoved(assetId: "never-scanned"))
        try original.assertUnchanged()
    }

    func testManualClusterIsKept() throws {
        try store.db.run("UPDATE PhotoFeatures SET cluster_source = 'manual', cluster_id = 1 WHERE asset_id = 'B'")
        let report = try store.removeAIAnalysis(userId: alice, assetId: "B")
        XCTAssertFalse(report.clusterCleared)
        XCTAssertEqual(try store.db.scalar("SELECT cluster_id FROM PhotoFeatures WHERE asset_id = 'B'") as? Int64, 1)
    }

    // 14. 重新分析不會覆寫或刪除原始照片，並保留使用者資料
    func testReanalysisKeepsUserDataAndOriginalPhoto() throws {
        let db = store.db
        _ = try store.removeAIAnalysis(userId: alice, assetId: "A")
        try store.prepareReanalysis(userId: alice, assetId: "A")
        try original.assertUnchanged()

        XCTAssertFalse(try store.isAIAnalysisRemoved(assetId: "A"))
        XCTAssertEqual(try db.scalar("SELECT is_favorite FROM PhotoFeatures WHERE asset_id = 'A'") as? Int64, 1)
        XCTAssertEqual(Set(try store.themeAlbums(containing: "A", userId: alice).map(\.id)), ["al1", "al2"])
        XCTAssertEqual(try store.tags(userId: alice, assetId: "A").map(\.nodeId), ["couple"])
        XCTAssertEqual(try store.analysisStatus(userId: alice, assetId: "A")?.status, "pending")

        // 模擬 App 重新讀取照片並寫入新向量後，照片會重新進入標記流程
        try db.run("UPDATE PhotoFeatures SET image_embedding = ? WHERE asset_id = 'A'", Blob(bytes: EmbeddingCodec.encode(TestDatabase.vector(5))))
        let pending = try store.assetsPendingTagging(userId: alice, taggerVersion: MultiLabelTagger.version(catalog: .builtIn), limit: 10)
        XCTAssertTrue(pending.map(\.assetId).contains("A"))
    }

    func testFailedReanalysisIsRecordedForRetry() throws {
        try store.prepareReanalysis(userId: alice, assetId: "B")
        try store.markAnalysisFailed(userId: alice, assetId: "B", reason: "iCloud 下載失敗")
        let status = try store.analysisStatus(userId: alice, assetId: "B")
        XCTAssertEqual(status?.status, "failed")
        XCTAssertEqual(status?.lastError, "iCloud 下載失敗")
        XCTAssertFalse(try store.isAIAnalysisRemoved(assetId: "B"), "失敗不等於移除；下次同步可重試")
    }
}

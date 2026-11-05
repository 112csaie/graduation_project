import XCTest
import SQLite
@testable import PersonalizationCore

/// 主題設定資料夾的調整：套用到分類目錄、每個分類自己的門檻、錯誤時沿用內建、內容一變就重新同步。
final class TaxonomyTuningTests: XCTestCase {

    private let sample = """
    {
      "nodes": {
        "cat": { "acceptScore": 0.3, "prompts": ["a cat", "a cat sleeping in a cardboard box"], "nameZh": "貓咪" },
        "noodle_dish": { "suppressedBy": [] }
      },
      "thresholds": { "acceptScore": 0.26 }
    }
    """

    func testNoTuningKeepsBuiltIn() {
        XCTAssertTrue(try TaxonomyTuning.parse("{}").isEmpty)
        XCTAssertEqual(TaxonomyTuning.signature(of: " {} \n"), "")
        let catalog = TaxonomyCatalog.untuned.applying(.empty, signature: "")
        XCTAssertEqual(catalog.catalogStamp, String(TaxonomyCatalog.untuned.catalogVersion))
        XCTAssertEqual(catalog.nodes, TaxonomyCatalog.untuned.nodes)
        XCTAssertEqual(TaxonomyCatalog.builtIn.catalogVersion, TaxonomyCatalog.untuned.catalogVersion)
    }

    func testApplyChangesOnlyTunedFields() throws {
        let tuning = try TaxonomyTuning.parse(sample)
        let signature = TaxonomyTuning.signature(of: sample)
        XCTAssertFalse(signature.isEmpty)
        let catalog = TaxonomyCatalog.untuned.applying(tuning, signature: signature)
        let cat = try XCTUnwrap(catalog.node("cat"))
        let original = try XCTUnwrap(TaxonomyCatalog.untuned.node("cat"))
        XCTAssertEqual(cat.nameZh, "貓咪")
        XCTAssertEqual(cat.nameEn, original.nameEn, "沒調整的欄位沿用內建")
        XCTAssertEqual(cat.prompts.last, "a cat sleeping in a cardboard box")
        XCTAssertEqual(cat.acceptScore, 0.3)
        XCTAssertTrue(cat.distinct)
        XCTAssertEqual(catalog.node("noodle_dish")?.suppressedBy, [])
        XCTAssertEqual(catalog.node("sushi"), TaxonomyCatalog.untuned.node("sushi"))
        XCTAssertEqual(catalog.catalogStamp, "\(TaxonomyCatalog.untuned.catalogVersion)+\(signature)")
        XCTAssertEqual(catalog.validationErrors(), [])

        XCTAssertEqual(tuning.apply(to: TaggingThresholds()).acceptScore, 0.26)
        XCTAssertEqual(tuning.apply(to: TaggingThresholds()).maxAccepted, 3, "沒調整的全域門檻沿用預設")
        XCTAssertNotEqual(MultiLabelTagger.version(catalog: catalog), MultiLabelTagger.version(catalog: .untuned),
                          "調整內容改變時重新比對自動標籤")
    }

    func testInvalidTuningIsIgnored() throws {
        let unknown = try TaxonomyTuning.parse(#"{"nodes": {"not_a_node": {"nameZh": "x"}}}"#)
        XCTAssertFalse(unknown.validationErrors(baseNodeIds: Set(TaxonomyCatalog.untuned.nodes.map(\.id))).isEmpty)
        XCTAssertEqual(TaxonomyCatalog.untuned.applying(unknown, signature: "x").catalogStamp, String(TaxonomyCatalog.untuned.catalogVersion), "有錯誤時沿用內建")

        let noPrompts = try TaxonomyTuning.parse(#"{"nodes": {"cat": {"prompts": []}}}"#)
        XCTAssertEqual(TaxonomyCatalog.untuned.applying(noPrompts, signature: "y").node("cat")?.prompts,
                       TaxonomyCatalog.untuned.node("cat")?.prompts, "套用後目錄檢查不通過也沿用內建")

        let tooLow = try TaxonomyTuning.parse(#"{"nodes": {"cat": {"acceptScore": 0.01}}}"#)
        XCTAssertNil(TaxonomyCatalog.untuned.applying(tooLow, signature: "z").node("cat")?.acceptScore)
        XCTAssertThrowsError(try TaxonomyTuning.parse("{ not json"))
    }

    /// 分類自己的門檻比全域高：分數 0.28 的照片，全域門檻 0.25 會標上，門檻 0.3 的分類不會
    func testPerNodeThreshold() throws {
        let tuning = try TaxonomyTuning.parse(#"{"nodes": {"cat": {"acceptScore": 0.3}}}"#)
        let catalog = TaxonomyCatalog.untuned.applying(tuning, signature: "t")
        func suggestions(_ catalog: TaxonomyCatalog) -> [TagSuggestion] {
            let tagger = MultiLabelTagger(catalog: catalog, promptEmbeddings: ["cat": [TestDatabase.vector(0)]],
                                          thresholds: TaggingThresholds())
            var photo = [Float](repeating: 0, count: 16)
            photo[0] = 0.28
            photo[1] = (1 - 0.28 * 0.28).squareRoot()
            return tagger.suggestTags(for: photo)
        }
        XCTAssertEqual(suggestions(.untuned).map(\.nodeId), ["cat"])
        XCTAssertTrue(suggestions(catalog).isEmpty)
    }

    /// 調整內容一變，資料庫裡的分類名稱與提示詞就重新同步（新提示詞等著算文字向量）
    func testSeedRunsWhenTuningChanges() throws {
        let store = try TestDatabase.makeStore(catalog: .untuned)
        XCTAssertFalse(try store.seedCatalogIfNeeded(), "同一版本不重複同步")

        let tuning = try TaxonomyTuning.parse(sample)
        let tuned = TaxonomyCatalog.untuned.applying(tuning, signature: TaxonomyTuning.signature(of: sample))
        let tunedStore = PersonalizationStore(db: store.db, catalog: tuned)
        XCTAssertTrue(try tunedStore.seedCatalogIfNeeded())
        XCTAssertEqual(try store.db.scalar("SELECT name_zh FROM TaxonomyNodes WHERE node_id = 'cat'") as? String, "貓咪")
        XCTAssertTrue(try tunedStore.promptsNeedingEmbedding().contains { $0.nodeId == "cat" && $0.prompt == "a cat sleeping in a cardboard box" })
        XCTAssertFalse(try tunedStore.seedCatalogIfNeeded())

        // 還原：名稱回到內建，多的提示詞移除
        let restored = PersonalizationStore(db: store.db, catalog: .untuned)
        XCTAssertTrue(try restored.seedCatalogIfNeeded())
        XCTAssertEqual(try store.db.scalar("SELECT name_zh FROM TaxonomyNodes WHERE node_id = 'cat'") as? String, "貓")
        XCTAssertFalse(try restored.promptsNeedingEmbedding().contains { $0.prompt == "a cat sleeping in a cardboard box" })
    }
}

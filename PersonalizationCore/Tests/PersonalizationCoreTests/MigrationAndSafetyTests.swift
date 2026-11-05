import XCTest
import SQLite
@testable import PersonalizationCore

/// 驗收 15（既有功能相容）與照片安全的靜態檢查。
final class MigrationAndSafetyTests: XCTestCase {

    private static var projectRoot: URL {
        // .../ios_app/PersonalizationCore/Tests/PersonalizationCoreTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testMigrationIsIdempotentAndKeepsExistingData() throws {
        let db = try TestDatabase.makeLegacyConnection()
        try TestDatabase.insertLegacyPhoto(db)
        let store = PersonalizationStore(db: db)

        try store.migrate()
        try store.migrate()   // 第二次不應出錯或重複
        XCTAssertEqual(try TestDatabase.count(db, "SELECT COUNT(*) FROM PersonalizationMigrations"), PersonalizationSchema.migrations.count)
        XCTAssertEqual(try TestDatabase.count(db, "SELECT COUNT(*) FROM ClusterSummary"), 1)
        XCTAssertEqual(try TestDatabase.count(db, "SELECT COUNT(*) FROM PhotoFeatures WHERE asset_id = 'legacy' AND image_embedding IS NOT NULL AND is_favorite = 1"), 1)
        XCTAssertEqual(try db.scalar("SELECT cluster_source FROM PhotoFeatures WHERE asset_id = 'legacy'") as? String, "auto")
        for column in ["owner_user_id", "cluster_source", "ai_removed_at"] {
            XCTAssertTrue(try PersonalizationSchema.columnExists(db, table: "PhotoFeatures", column: column))
        }
    }

    /// 用專案內實際的 PhotoAI.sqlite（複製到暫存檔）驗證 Migration；原檔案不會被修改。
    func testMigrationOnBundledDatabaseCopy() throws {
        let bundled = Self.projectRoot.appendingPathComponent("MobileCLIPExplore/SQLite/PhotoAI.sqlite")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: bundled.path), "找不到 PhotoAI.sqlite")
        let originalBytes = try Data(contentsOf: bundled)

        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoAI-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: bundled, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        let db = try Connection(copy.path)
        let clusterCount = try TestDatabase.count(db, "SELECT COUNT(*) FROM ClusterSummary")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS UserAlbums (album_id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS UserAlbumPhotos (album_id TEXT NOT NULL, asset_id TEXT NOT NULL, position INTEGER DEFAULT 0, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (album_id, asset_id));
        """)
        let store = PersonalizationStore(db: db)
        try store.migrate()
        XCTAssertTrue(try store.seedCatalogIfNeeded())
        XCTAssertGreaterThan(try store.reuseExistingDictionaryEmbeddings(), 0, "應沿用既有 SemanticDictionary 文字向量（例如 Ramen、Beach）")
        XCTAssertEqual(try TestDatabase.count(db, "SELECT COUNT(*) FROM ClusterSummary"), clusterCount, "既有分類字典不變")

        XCTAssertEqual(try Data(contentsOf: bundled), originalBytes, "專案內的 PhotoAI.sqlite 不應被修改")
    }

    /// 靜態檢查：個人化相關程式碼不得呼叫任何會修改 / 刪除系統相簿或照片檔案的 API。
    func testPersonalizationCodeNeverCallsPhotoDeletionAPIs() throws {
        let forbidden = [
            "PHAssetChangeRequest", "PHAssetCollectionChangeRequest", "PHAssetCreationRequest",
            "deleteAssets", "performChanges", "removeItem(", "PHContentEditingOutput",
        ]
        let directories = [
            Self.projectRoot.appendingPathComponent("PersonalizationCore/Sources"),
            Self.projectRoot.appendingPathComponent("MobileCLIPExplore/Personalization"),
        ]
        var checked = 0
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let code = try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                for token in forbidden {
                    XCTAssertFalse(code.contains(token), "\(url.lastPathComponent) 不應使用 \(token)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// 靜態檢查：整個 App 不再有從系統相簿刪除原始照片的程式碼路徑。
    func testAppNoLongerDeletesOriginalPhotos() throws {
        let appDirectory = Self.projectRoot.appendingPathComponent("MobileCLIPExplore")
        guard let enumerator = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil) else {
            throw XCTSkip("找不到 App 原始碼")
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertFalse(code.contains("deleteAssets"), "\(url.lastPathComponent) 不應刪除系統相簿照片")
            XCTAssertFalse(code.contains("PHAssetChangeRequest"), "\(url.lastPathComponent) 不應修改系統相簿照片")
        }
    }
}

extension TestDatabase {
    static func insertLegacyPhoto(_ db: Connection) throws {
        // 升級前的資料列：沒有 owner_user_id / cluster_source / ai_removed_at 欄位
        try db.run("INSERT INTO PhotoFeatures (asset_id, metadata, image_embedding, cluster_id, is_favorite) VALUES ('legacy', '{}', ?, 1, 1)",
                   Blob(bytes: EmbeddingCodec.encode(vector(0))))
    }
}

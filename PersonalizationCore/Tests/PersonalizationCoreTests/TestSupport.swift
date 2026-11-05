import Foundation
import SQLite
import XCTest
@testable import PersonalizationCore

/// 建立一個「與 App 相同結構」的記憶體資料庫：內建 PhotoAI.sqlite 的資料表 + DatabaseManager 執行期建立的資料表。
enum TestDatabase {

    static func makeLegacyConnection() throws -> Connection {
        let db = try Connection(.inMemory)
        // 與 MobileCLIPExplore/SQLite/PhotoAI.sqlite 相同
        try db.execute("""
        CREATE TABLE SemanticDictionary (keyword TEXT PRIMARY KEY, word_embedding BLOB);
        CREATE TABLE ClusterSummary (
            cluster_id INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword TEXT NOT NULL,
            parent_category TEXT NOT NULL,
            random_vector BLOB,
            FOREIGN KEY (keyword) REFERENCES SemanticDictionary(keyword)
        );
        CREATE TABLE PhotoFeatures (
            asset_id TEXT PRIMARY KEY,
            metadata TEXT,
            image_embedding BLOB,
            cluster_id INTEGER,
            is_favorite INTEGER DEFAULT 0,
            FOREIGN KEY (cluster_id) REFERENCES ClusterSummary(cluster_id)
        );
        CREATE TABLE AgentNotes (note_id TEXT PRIMARY KEY, title TEXT NOT NULL, content TEXT, is_favorite INTEGER DEFAULT 0, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
        """)
        // 與 DatabaseManager.createCustomAlbumTablesIfNeeded 相同
        try db.execute("""
        CREATE TABLE IF NOT EXISTS UserAlbums (album_id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS UserAlbumPhotos (album_id TEXT NOT NULL, asset_id TEXT NOT NULL, position INTEGER DEFAULT 0, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (album_id, asset_id));
        CREATE TABLE IF NOT EXISTS PinnedCategories (keyword TEXT PRIMARY KEY);
        ALTER TABLE UserAlbums ADD COLUMN is_pinned INTEGER DEFAULT 0;
        """)
        try db.run("INSERT INTO SemanticDictionary (keyword, word_embedding) VALUES ('Ramen', NULL)")
        try db.run("INSERT INTO ClusterSummary (keyword, parent_category) VALUES ('Ramen', 'Food')")
        return db
    }

    static func makeStore(catalog: TaxonomyCatalog = .builtIn) throws -> PersonalizationStore {
        let store = PersonalizationStore(db: try makeLegacyConnection(), catalog: catalog)
        try store.migrate()
        try store.seedCatalogIfNeeded()
        return store
    }

    static func vector(_ index: Int, dims: Int = 16) -> [Float] {
        var v = [Float](repeating: 0, count: dims)
        v[index % dims] = 1
        return v
    }

    static func insertPhoto(_ db: Connection, assetId: String, owner: String?, embedding: [Float]? = vector(0),
                            clusterId: Int64? = 1, favorite: Bool = false, metadata: String = "{\"date\":\"2026-01-01\"}") throws {
        let blob: Blob? = embedding.map { Blob(bytes: EmbeddingCodec.encode($0)) }
        try db.run("""
        INSERT INTO PhotoFeatures (asset_id, metadata, image_embedding, cluster_id, is_favorite, owner_user_id)
        VALUES (?, ?, ?, ?, ?, ?)
        """, assetId, metadata, blob, clusterId, Int64(favorite ? 1 : 0), owner)
    }

    static func embeddingBytes(_ db: Connection, _ assetId: String) throws -> [UInt8]? {
        (try db.scalar("SELECT image_embedding FROM PhotoFeatures WHERE asset_id = ?", assetId) as? Blob)?.bytes
    }

    static func count(_ db: Connection, _ sql: String, _ args: Binding?...) throws -> Int {
        Int(try db.scalar(sql, args) as? Int64 ?? 0)
    }
}

/// 模擬「原始照片檔案」：用來證明 AI 資料操作不會碰到照片內容。
final class FakeOriginalPhoto {
    let url: URL
    let originalBytes: Data

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("original-\(UUID().uuidString).jpg")
        originalBytes = Data((0..<4096).map { UInt8($0 % 251) })
        try originalBytes.write(to: url)
    }

    func assertUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "原始照片不應被刪除", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes, "原始照片內容不應被修改", file: file, line: line)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

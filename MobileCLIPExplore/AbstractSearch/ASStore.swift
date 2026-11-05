//
//  ASStore.swift
//  抽象語意搜尋模組（v10）
//
//  SQLite 儲存。表格結構與 PC 版相同：
//    images  (path, content_hash, schema_version, model, graph_json, build_error, built_at)
//    vectors (path, model, kind, ent_id, vec)
//  差別只在 path 存的是 PHAsset.localIdentifier，content_hash 存的是照片的修改時間。
//

import Foundation
import SQLite3

public enum ASStoreError: Error, LocalizedError {
    case openFailed(String)
    case sqlFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "無法開啟資料庫：\(m)"
        case .sqlFailed(let m): return "資料庫錯誤：\(m)"
        }
    }
}

struct ASBuildRecord {
    let contentHash: String
    let schemaVersion: String
    let model: String
    let buildError: String?
}

struct ASStoredImage {
    let path: String
    let graph: ASSceneGraph
    let docVec: [Float]
    let entityVecs: [String: [Float]]
}

final class ASStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw ASStoreError.openFailed(msg)
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS images (
                path TEXT PRIMARY KEY,
                content_hash TEXT,
                schema_version TEXT,
                model TEXT,
                graph_json TEXT,
                build_error TEXT,
                built_at REAL
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS vectors (
                path TEXT NOT NULL,
                model TEXT NOT NULL,
                kind TEXT NOT NULL,
                ent_id TEXT NOT NULL,
                vec BLOB NOT NULL,
                PRIMARY KEY (path, model, kind, ent_id)
            )
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: 建圖紀錄

    func buildRecord(path: String) -> ASBuildRecord? {
        lock.withLock {
            var result: ASBuildRecord?
            try? query("SELECT content_hash, schema_version, model, build_error FROM images WHERE path = ?",
                       bind: [path]) { stmt in
                result = ASBuildRecord(contentHash: text(stmt, 0), schemaVersion: text(stmt, 1),
                                       model: text(stmt, 2), buildError: optionalText(stmt, 3))
            }
            return result
        }
    }

    /// [PhotoAI 整合新增] 所有照片的建圖紀錄（一次查詢；建圖前判斷哪些要分析，不用每張照片各查一次）
    func allBuildRecords() -> [String: ASBuildRecord] {
        lock.withLock {
            var result: [String: ASBuildRecord] = [:]
            try? query("SELECT path, content_hash, schema_version, model, build_error FROM images", bind: []) { stmt in
                result[text(stmt, 0)] = ASBuildRecord(contentHash: text(stmt, 1), schemaVersion: text(stmt, 2),
                                                      model: text(stmt, 3), buildError: optionalText(stmt, 4))
            }
            return result
        }
    }

    /// 寫入新的場景圖；同時刪除這張照片的舊向量，避免圖和向量對不上
    func saveGraph(path: String, contentHash: String, schemaVersion: String, model: String,
                   graph: ASSceneGraph) throws {
        try lock.withLock {
            try run("""
                INSERT OR REPLACE INTO images
                (path, content_hash, schema_version, model, graph_json, build_error, built_at)
                VALUES (?, ?, ?, ?, ?, NULL, ?)
                """, bind: [path, contentHash, schemaVersion, model, graph.jsonString(),
                            Date().timeIntervalSince1970])
            try run("DELETE FROM vectors WHERE path = ?", bind: [path])
        }
    }

    func saveError(path: String, contentHash: String, schemaVersion: String, model: String,
                   message: String) throws {
        try lock.withLock {
            try run("""
                INSERT OR REPLACE INTO images
                (path, content_hash, schema_version, model, graph_json, build_error, built_at)
                VALUES (?, ?, ?, ?, '{}', ?, ?)
                """, bind: [path, contentHash, schemaVersion, model, message,
                            Date().timeIntervalSince1970])
            try run("DELETE FROM vectors WHERE path = ?", bind: [path])
        }
    }

    /// 刪除已經不在相簿裡的照片
    func deleteImages(notIn keep: Set<String>) throws -> Int {
        try lock.withLock {
            var stale: [String] = []
            try query("SELECT path FROM images", bind: []) { stmt in
                let p = text(stmt, 0)
                if !keep.contains(p) { stale.append(p) }
            }
            for p in stale {
                try run("DELETE FROM images WHERE path = ?", bind: [p])
                try run("DELETE FROM vectors WHERE path = ?", bind: [p])
            }
            return stale.count
        }
    }

    /// [PhotoAI 整合新增] 讀出一張照片已建好的場景圖（沿用給幾乎一樣的照片）
    func graph(path: String) -> ASSceneGraph? {
        lock.withLock {
            var result: ASSceneGraph?
            try? query("SELECT graph_json FROM images WHERE path = ? AND build_error IS NULL", bind: [path]) { stmt in
                result = ASSceneGraph.fromJSON(text(stmt, 0))
            }
            return result
        }
    }

    /// [PhotoAI 整合新增] 刪除指定照片的場景圖與向量
    func deleteImages(paths: Set<String>) throws -> Int {
        guard !paths.isEmpty else { return 0 }
        return try lock.withLock {
            var removed = 0
            for p in paths {
                try run("DELETE FROM vectors WHERE path = ?", bind: [p])
                try run("DELETE FROM images WHERE path = ?", bind: [p])
                removed += Int(sqlite3_changes(db))
            }
            return removed
        }
    }

    /// [PhotoAI 整合新增] 建圖成功／失敗與可搜尋的照片數
    func stats(model: String) throws -> ASIndexStats {
        try lock.withLock {
            var built = 0, failed = 0, searchable = 0
            try query("SELECT SUM(build_error IS NULL), SUM(build_error IS NOT NULL) FROM images", bind: []) { stmt in
                built = Int(sqlite3_column_int64(stmt, 0))
                failed = Int(sqlite3_column_int64(stmt, 1))
            }
            try query("SELECT COUNT(DISTINCT path) FROM vectors WHERE model = ? AND kind = 'doc'", bind: [model]) { stmt in
                searchable = Int(sqlite3_column_int64(stmt, 0))
            }
            return ASIndexStats(built: built, failed: failed, searchable: searchable)
        }
    }

    // MARK: 向量

    /// 建圖成功、但還沒有這個模型向量的照片
    func graphsMissingVectors(model: String) throws -> [(String, ASSceneGraph)] {
        try lock.withLock {
            var out: [(String, ASSceneGraph)] = []
            try query("""
                SELECT path, graph_json FROM images
                WHERE build_error IS NULL
                AND path NOT IN (SELECT path FROM vectors WHERE model = ? AND kind = 'doc')
                """, bind: [model]) { stmt in
                if let g = ASSceneGraph.fromJSON(text(stmt, 1)) {
                    out.append((text(stmt, 0), g))
                }
            }
            return out
        }
    }

    func saveVectors(path: String, model: String, docVec: [Float], entityVecs: [(String, [Float])]) throws {
        try lock.withLock {
            try exec("BEGIN")
            do {
                try run("DELETE FROM vectors WHERE path = ? AND model = ?", bind: [path, model])
                try run("INSERT INTO vectors VALUES (?, ?, 'doc', '', ?)", bind: [path, model, blob(docVec)])
                for (eid, v) in entityVecs {
                    try run("INSERT INTO vectors VALUES (?, ?, 'ent', ?, ?)", bind: [path, model, eid, blob(v)])
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// 讀出所有已建好圖且有向量的照片，給搜尋用
    func loadSearchable(model: String) throws -> [ASStoredImage] {
        try lock.withLock {
            var graphs: [String: ASSceneGraph] = [:]
            try query("SELECT path, graph_json FROM images WHERE build_error IS NULL", bind: []) { stmt in
                if let g = ASSceneGraph.fromJSON(text(stmt, 1)) { graphs[text(stmt, 0)] = g }
            }
            var docs: [String: [Float]] = [:]
            var ents: [String: [String: [Float]]] = [:]
            try query("SELECT path, kind, ent_id, vec FROM vectors WHERE model = ?", bind: [model]) { stmt in
                let p = text(stmt, 0)
                let v = floats(stmt, 3)
                if text(stmt, 1) == "doc" {
                    docs[p] = v
                } else {
                    ents[p, default: [:]][text(stmt, 2)] = v
                }
            }
            return graphs.compactMap { path, g in
                guard let d = docs[path] else { return nil }
                return ASStoredImage(path: path, graph: g, docVec: d, entityVecs: ents[path] ?? [:])
            }
        }
    }

    /// 隨機取幾張照片的整圖向量，用來校正相似度下限
    /// [PhotoAI 整合新增] 只抽「模型建圖」照片的描述向量（相似度校正用）。
    /// 文字型照片的紀錄幾乎都是「這是一張文件。」這種很像的句子，混進來會把「不相關」的基準估得太高，
    /// 所有搜尋分數都被校正成接近 0，智慧搜尋就什麼都找不到。
    func sampleDocVectors(model: String, limit: Int, builtBy builderModel: String) throws -> [[Float]] {
        try lock.withLock {
            var out: [[Float]] = []
            try query("""
                SELECT v.vec FROM vectors v JOIN images i ON i.path = v.path
                WHERE v.model = ? AND v.kind = 'doc' AND i.model = ? AND i.build_error IS NULL
                ORDER BY RANDOM() LIMIT ?
                """, bind: [model, builderModel, limit]) { stmt in
                out.append(floats(stmt, 0))
            }
            return out
        }
    }

    func sampleDocVectors(model: String, limit: Int) throws -> [[Float]] {
        try lock.withLock {
            var out: [[Float]] = []
            try query("SELECT vec FROM vectors WHERE model = ? AND kind = 'doc' ORDER BY RANDOM() LIMIT ?",
                      bind: [model, limit]) { stmt in
                out.append(floats(stmt, 0))
            }
            return out
        }
    }

    // MARK: SQLite 小工具（呼叫端需持有 lock）

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw ASStoreError.sqlFailed(msg)
        }
    }

    private func prepare(_ sql: String, bind values: [Any]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ASStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, transient)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let data as Data:
                _ = data.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(data.count), transient)
                }
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, bind values: [Any]) throws {
        let stmt = try prepare(sql, bind: values)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw ASStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, bind values: [Any], row: (OpaquePointer?) throws -> Void) throws {
        let stmt = try prepare(sql, bind: values)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { try row(stmt) } else if rc == SQLITE_DONE { break } else {
                throw ASStoreError.sqlFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func blob(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

private func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
    guard let c = sqlite3_column_text(stmt, col) else { return "" }
    return String(cString: c)
}

private func optionalText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
    sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : text(stmt, col)
}

private func floats(_ stmt: OpaquePointer?, _ col: Int32) -> [Float] {
    let bytes = Int(sqlite3_column_bytes(stmt, col))
    guard bytes > 0, let raw = sqlite3_column_blob(stmt, col) else { return [] }
    let n = bytes / MemoryLayout<Float>.size
    return Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: n))
}

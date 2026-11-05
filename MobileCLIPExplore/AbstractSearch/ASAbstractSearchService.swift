//
//  ASAbstractSearchService.swift
//  抽象語意搜尋模組（v10）
//
//  [PhotoAI 整合] 這份是組員新版模組（AbstractSearch 2）加上 App 需要的整合功能（標「PhotoAI 整合」的地方）：
//  @available(iOS 27)、建圖時間統計、pendingAssets／copyGraphs／removeAssets／sceneGraph／indexStats、
//  查詢解析快取、搜尋索引只更新新照片。
//
//  整合用的入口。同學只需要呼叫這個類別：
//
//      let service = try ASAbstractSearchService(databaseURL: url)
//      try await service.prepare()                       // App 啟動時呼叫一次
//      await service.buildIndex(for: assets, hint: { id in ... })   // 建圖（可中斷，下次會接續）
//                         // hint 回傳同學的 OCR／CLIP 結果，文字型照片就不建圖
//      let results = try await service.search("一隻在海邊散步的狗")
//
//  流程與 PC 版 pipeline_v10.py 相同：
//    建圖：照片 → 文字型照片？ 是 → OCR＋CLIP 標籤產生簡化場景圖（不呼叫模型）
//                             否 → Foundation Models 場景圖
//          → 存入 images 表 → 文字向量 → 存入 vectors 表
//    搜尋：查詢 → Foundation Models 解析 → 混合式搜尋 → 依分數排序
//

import Foundation
import Photos
import UIKit
import FoundationModels

public enum ASBuildStopReason: Sendable {
    /// 全部照片都處理過了
    case completed
    /// Task 被取消（App 進背景、背景時間用完、使用者在 Live Activity 按取消）
    case cancelled
    /// 系統限制模型的使用量（背景最常見）。照片沒有被記成失敗，等一段時間再呼叫即可接續。
    /// 被限制後仍會繼續處理文字型照片（不需要模型）
    case rateLimited
    /// Apple Intelligence 無法使用（關閉、裝置不支援、模型下載中）
    case modelUnavailable
}

public struct ASBuildSummary: Sendable {
    /// 用 Foundation Models 建圖的張數
    public var built = 0
    /// 文字型照片：用 OCR＋CLIP 標籤處理、沒有呼叫模型的張數
    public var textOnly = 0
    /// 模型被限制或無法使用，這次沒處理、下次會接續的張數
    public var pending = 0
    public var skipped = 0
    public var failed = 0
    public var stopReason: ASBuildStopReason = .completed
    /// 被中斷時為 true；下次呼叫會從沒建好的照片接續
    public var cancelled: Bool { stopReason != .completed }
    /// [PhotoAI 整合新增] 成功建圖的照片花在讀圖、模型上的總秒數（設定頁顯示平均速度與剩餘時間）
    public var imageSeconds: Double = 0
    public var modelSeconds: Double = 0
}

/// [PhotoAI 整合新增] 索引狀態
public struct ASIndexStats: Sendable {
    /// 建圖成功（含文字型照片）
    public let built: Int
    /// 建圖失敗（下次建圖會重試）
    public let failed: Int
    /// 已有文字向量、可以被搜尋到
    public let searchable: Int
}

public struct ASBuildProgress: Sendable {
    public let done: Int
    public let total: Int
}

public enum ASServiceError: Error, LocalizedError {
    case modelUnavailable(String)
    case imageLoadFailed

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let r): return "Apple Intelligence 無法使用：\(r)"
        case .imageLoadFailed: return "無法讀取照片"
        }
    }
}

@available(iOS 27, *)   // [PhotoAI 整合] App 最低版本 iOS 18.6；建圖需要 iOS 27 的 Foundation Models
public final class ASAbstractSearchService: @unchecked Sendable {
    /// 對應 PC 版的 schema 版本；之後改了提示詞或輸出格式就改這個值，舊照片會自動重建
    public static let schemaVersion = "v10"
    static let builderModelName = "apple-foundation-model-ondevice"

    private let store: ASStore
    private let embedder: ASTextEmbedding
    private let builder = ASGraphBuilder()
    private let parser = ASQueryParser()

    private let lock = NSLock()
    private var cachedIndex: [ASImageIndex]?
    /// [PhotoAI 整合] 最近解析過的查詢（同一句話不用再等模型；temperature 0，結果相同）
    private var parsedCache: [String: ASParsedQuery] = [:]
    private var parsedOrder: [String] = []
    private static let parsedCacheLimit = 50
    /// [PhotoAI 整合] v2：舊版校正可能被文字型照片的紀錄拉得太高（見 calibrateSimFloor），換新的鍵重新校正一次
    private var floorKey: String { "ASAbstractSearch.simFloor.v2.\(embedder.modelName)" }

    /// - Parameters:
    ///   - databaseURL: SQLite 檔案位置，建議放在 Application Support
    ///   - embedder: 不傳就用 NLContextualEmbedding
    public init(databaseURL: URL, embedder: ASTextEmbedding? = nil) throws {
        store = try ASStore(url: databaseURL)
        self.embedder = try embedder ?? ASContextualEmbedder()
        if let saved = UserDefaults.standard.object(forKey: floorKey) as? Float {
            self.embedder.simFloor = saved
        }
    }

    /// 預設的資料庫位置：Application Support/AbstractSearch.sqlite
    public static func defaultDatabaseURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return dir.appendingPathComponent("AbstractSearch.sqlite")
    }

    /// 是否可以使用 Apple Intelligence（不能用時，建圖與搜尋都會丟出 modelUnavailable）
    public static var isAvailable: Bool { ASModelAvailability.isAvailable }

    /// 下載並載入文字向量模型。App 啟動後呼叫一次。
    public func prepare() async throws {
        try await embedder.prepare()
    }

    // MARK: - 建圖

    /// 為照片建圖並計算向量。已建好且沒有修改過的照片會跳過；失敗的照片下次會重試。
    /// 在 Task 裡被取消時（例如 BGProcessingTask 時間用完）會在目前這張完成後停止。
    ///
    /// - Parameter hint: 傳入照片的 localIdentifier，回傳同學 App 已經算好的 OCR 與 CLIP 結果。
    ///   判斷為文字型照片（見 ASTextPhotoFilter）就不呼叫 Foundation Models，直接用標籤與 OCR 產生紀錄。
    ///   回傳 nil 代表這張還沒有 OCR／CLIP 結果，會照一般照片建圖。不傳就全部建圖。
    ///   文字型照片不需要模型，所以 App 在背景、模型被限制時也能處理。
    @discardableResult
    public func buildIndex(for assets: [PHAsset],
                           hint: (@Sendable (String) async -> ASPhotoHint?)? = nil,
                           progress: (@Sendable (ASBuildProgress) -> Void)? = nil) async -> ASBuildSummary {
        var summary = ASBuildSummary()
        // 模型不能用時不直接結束：文字型照片還是可以處理
        var modelBlocked: ASBuildStopReason? = ASModelAvailability.isAvailable ? nil : .modelUnavailable

        for (i, asset) in assets.enumerated() {
            if Task.isCancelled {
                summary.stopReason = .cancelled
                break
            }
            defer { progress?(ASBuildProgress(done: i + 1, total: assets.count)) }
            let key = asset.localIdentifier
            let hash = Self.contentHash(of: asset)
            let rec = store.buildRecord(path: key)
            let upToDate = rec.map { $0.contentHash == hash && $0.schemaVersion == Self.schemaVersion } ?? false

            // 1. 文字型照片：不呼叫模型
            if let h = await hint?(key) {
                var h = h
                h.isScreenshot = h.isScreenshot || asset.mediaSubtypes.contains(.photoScreenshot)
                if ASTextPhotoFilter.isTextPhoto(h) {
                    // 已經有文字紀錄，或之前已經完整建圖成功（比較完整，不用降級）就跳過
                    if upToDate, let rec,
                       rec.model == ASTextPhotoFilter.recordModelName
                        || (rec.model == Self.builderModelName && rec.buildError == nil) {
                        summary.skipped += 1
                        continue
                    }
                    do {
                        try store.saveGraph(path: key, contentHash: hash, schemaVersion: Self.schemaVersion,
                                            model: ASTextPhotoFilter.recordModelName,
                                            graph: ASTextPhotoFilter.graph(from: h))
                        summary.textOnly += 1
                    } catch {
                        summary.failed += 1
                    }
                    continue
                }
            }

            // 2. 一般照片：Foundation Models 建圖
            if upToDate, let rec, rec.model == Self.builderModelName,
               rec.buildError == nil || rec.buildError!.hasPrefix(Self.permanentPrefix) {
                summary.skipped += 1
                continue
            }
            if modelBlocked != nil {
                summary.pending += 1   // 模型被限制：先跳過，繼續找文字型照片
                continue
            }
            do {
                let t0 = Date()
                guard let image = await Self.loadImage(for: asset) else { throw ASServiceError.imageLoadFailed }
                let t1 = Date()
                let graph = try await buildWithRetry(image)
                let t2 = Date()
                try store.saveGraph(path: key, contentHash: hash, schemaVersion: Self.schemaVersion,
                                    model: Self.builderModelName, graph: graph)
                summary.built += 1
                // [PhotoAI 整合] 讀圖、模型各花多少時間（設定頁估計剩餘時間）
                summary.imageSeconds += t1.timeIntervalSince(t0)
                summary.modelSeconds += t2.timeIntervalSince(t1)
            } catch {
                switch Self.classify(error) {
                case .rateLimited:
                    // 不記成失敗：之後的一般照片先跳過，文字型照片照常處理。下次呼叫會從這張接續
                    modelBlocked = .rateLimited
                    summary.pending += 1
                case .unavailable:
                    modelBlocked = .modelUnavailable
                    summary.pending += 1
                case .cancelled:
                    summary.stopReason = .cancelled
                case .permanent:
                    // 重試也不會成功（例如觸發安全機制、內容超過模型長度）：記下來，之後跳過
                    try? store.saveError(path: key, contentHash: hash, schemaVersion: Self.schemaVersion,
                                         model: Self.builderModelName,
                                         message: Self.permanentPrefix + String(describing: error))
                    summary.failed += 1
                case .transient:
                    try? store.saveError(path: key, contentHash: hash, schemaVersion: Self.schemaVersion,
                                         model: Self.builderModelName, message: String(describing: error))
                    summary.failed += 1
                }
                if summary.stopReason == .cancelled { break }
            }
        }

        if summary.stopReason != .cancelled, let blocked = modelBlocked {
            summary.stopReason = blocked
        }
        try? embedPending()
        return summary
    }

    /// 被限流或逾時時，等一下再試；最多重試 maxRetries 次，仍被限流就交給呼叫端停下
    private func buildWithRetry(_ image: CGImage, maxRetries: Int = 2) async throws -> ASSceneGraph {
        var attempt = 0
        while true {
            do {
                return try await builder.buildGraph(from: image)
            } catch {
                let kind = Self.classify(error)
                guard attempt < maxRetries, kind == .rateLimited || kind == .transient else { throw error }
                attempt += 1
                // 5 秒、15 秒；Task 被取消時 sleep 會丟出 CancellationError，直接結束
                try await Task.sleep(for: .seconds(attempt == 1 ? 5 : 15))
            }
        }
    }

    static let permanentPrefix = "[permanent] "

    enum ErrorKind { case rateLimited, unavailable, cancelled, permanent, transient }

    static func classify(_ error: Error) -> ErrorKind {
        if error is CancellationError { return .cancelled }
        if case ASServiceError.modelUnavailable = error { return .unavailable }
        if let e = error as? LanguageModelError {
            switch e {
            case .rateLimited, .timeout:
                return .rateLimited
            case .guardrailViolation, .refusal, .contextSizeExceeded, .unsupportedTranscriptContent:
                return .permanent
            default:
                return ASModelAvailability.isAvailable ? .transient : .unavailable
            }
        }
        return ASModelAvailability.isAvailable ? .transient : .unavailable
    }

    /// 為還沒有向量的照片計算向量。換文字向量模型後也是呼叫這個（不會重新建圖）。
    /// [PhotoAI 整合] 一張失敗不影響其他張：以前只要有一張算不出向量（例如文字向量模型對某段文字丟出錯誤），
    /// 整批就停在那裡，而且下次又從同一張開始，結果後面所有照片都建好圖卻永遠搜尋不到。
    public func embedPending() throws {
        let todo = try store.graphsMissingVectors(model: embedder.modelName)
        var added: [ASImageIndex] = []
        var failures = 0
        var lastError: Error?
        for (path, graph) in todo {
            do {
                let texts = [ASText.document(graph)] + graph.entities.map(ASText.entity)
                let vecs = try embedder.embed(texts)
                guard let doc = vecs.first else { continue }
                let ents = zip(graph.entities.map(\.id), vecs.dropFirst()).map { ($0, $1) }
                try store.saveVectors(path: path, model: embedder.modelName, docVec: doc, entityVecs: ents)
                var entityVecs: [String: [Float]] = [:]
                for (id, vec) in ents { entityVecs[id] = vec }
                added.append(ASImageIndex(stored: ASStoredImage(path: path, graph: graph, docVec: doc, entityVecs: entityVecs)))
            } catch {
                failures += 1
                lastError = error
            }
        }
        if failures > 0 {
            print("[抽象搜尋] \(failures) 張照片算不出文字向量（下次再試）：\(lastError.map { String(describing: $0) } ?? "")")
        }
        if !todo.isEmpty {
            // [PhotoAI 整合] 只把新分析好的照片加進搜尋索引，不整份丟掉重讀（分析中搜尋不會每次都重讀資料庫）
            upsertCache(added)
            if UserDefaults.standard.object(forKey: floorKey) == nil {
                _ = try? calibrateSimFloor()
            }
        }
    }

    /// 刪除已經不在相簿裡的照片（傳入目前相簿所有照片的 localIdentifier）
    @discardableResult
    public func removeDeletedAssets(keeping identifiers: Set<String>) throws -> Int {
        let n = try store.deleteImages(notIn: identifiers)
        if n > 0 { lock.withLock { cachedIndex = cachedIndex?.filter { identifiers.contains($0.id) } } }
        return n
    }

    /// [PhotoAI 整合新增] 使用者在 App 中「移除 AI 分析資料」時，刪除指定照片的場景圖與向量（只刪這個資料庫的資料，不動照片）。
    @discardableResult
    public func removeAssets(_ identifiers: Set<String>) throws -> Int {
        let n = try store.deleteImages(paths: identifiers)
        if n > 0 { removeFromCache(identifiers) }
        return n
    }

    /// [PhotoAI 整合新增] 還需要處理的照片（沒建過、照片修改過、上次失敗，或提示詞版本更新）。
    /// 文字型照片的紀錄、重試也不會成功的錯誤，都算已經處理過（和 buildIndex 跳過的規則相同）。
    public func pendingAssets(_ assets: [PHAsset]) -> [PHAsset] {
        let records = store.allBuildRecords()   // 一次查詢，不用每張照片各查一次
        return assets.filter { asset in
            guard let rec = records[asset.localIdentifier] else { return true }
            return !Self.isUpToDate(rec, hash: Self.contentHash(of: asset))
        }
    }

    private static func isUpToDate(_ rec: ASBuildRecord, hash: String) -> Bool {
        guard rec.contentHash == hash, rec.schemaVersion == schemaVersion else { return false }
        if rec.model == ASTextPhotoFilter.recordModelName { return true }
        return rec.model == builderModelName && (rec.buildError == nil || rec.buildError!.hasPrefix(permanentPrefix))
    }

    /// [PhotoAI 整合新增] 幾乎一樣的照片（連拍、同一個畫面拍好幾張）：沿用另一張已建好的場景圖，
    /// 不再讓模型看一次。已經是最新的照片會略過。回傳實際沿用的張數。
    @discardableResult
    public func copyGraphs(_ groups: [(source: String, targets: [PHAsset])]) throws -> Int {
        let groups = groups.filter { !$0.targets.isEmpty }
        guard !groups.isEmpty else { return 0 }
        let records = store.allBuildRecords()
        var copied = 0
        for (source, targets) in groups {
            guard let rec = records[source], rec.buildError == nil,
                  rec.schemaVersion == Self.schemaVersion, rec.model == Self.builderModelName else { continue }
            let pending = targets.filter { target in
                guard let own = records[target.localIdentifier] else { return true }
                return !Self.isUpToDate(own, hash: Self.contentHash(of: target))
            }
            guard !pending.isEmpty, let graph = store.graph(path: source) else { continue }
            for target in pending {
                try store.saveGraph(path: target.localIdentifier, contentHash: Self.contentHash(of: target),
                                    schemaVersion: Self.schemaVersion, model: Self.builderModelName, graph: graph)
                copied += 1
            }
        }
        if copied > 0 { try embedPending() }
        return copied
    }

    /// [PhotoAI 整合新增] 已建好的場景圖（回憶草稿把它整理成文字交給 Agent；照片本身不上傳）
    public func sceneGraph(for identifier: String) -> ASSceneGraph? {
        store.graph(path: identifier)
    }

    /// [PhotoAI 整合新增] 索引狀態（設定頁的診斷畫面用）
    public func indexStats() throws -> ASIndexStats {
        try store.stats(model: embedder.modelName)
    }

    // MARK: - 搜尋

    public func search(_ text: String, topK: Int = 20) async throws -> [ASSearchResult] {
        guard ASModelAvailability.isAvailable else {
            throw ASServiceError.modelUnavailable(ASModelAvailability.unavailableReason ?? "")
        }
        // [PhotoAI 整合] 建好圖、還沒有向量的照片（建圖被中斷、上次算向量失敗）先補算，才搜尋得到
        try? embedPending()
        // 還沒校正過（或舊版校正作廢）：照片夠多就先校正
        if UserDefaults.standard.object(forKey: floorKey) == nil { _ = try? calibrateSimFloor() }
        // [PhotoAI 整合] 同一句話不用再請模型解析
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: ASParsedQuery
        if let cached = lock.withLock({ parsedCache[key] }) {
            parsed = cached
        } else {
            parsed = try await parser.parse(key)
            lock.withLock {
                if parsedCache[key] == nil { parsedOrder.append(key) }
                parsedCache[key] = parsed
                while parsedOrder.count > Self.parsedCacheLimit {
                    parsedCache[parsedOrder.removeFirst()] = nil
                }
            }
        }
        return try search(key, parsed: parsed, topK: topK)
    }

    /// 用已經解析好的查詢搜尋（測試用：可以餵 PC 版的 parsed，比對兩邊的結果）
    public func search(_ text: String, parsed: ASParsedQuery, topK: Int = 20) throws -> [ASSearchResult] {
        let index = try loadIndex()
        let q = try ASQueryIndex(text: text, parsed: parsed, embedder: embedder)
        let results = ASHybridSearch.search(q, index: index, floor: embedder.simFloor)
        #if DEBUG
        // [PhotoAI 整合] 找不到東西時用來判斷是哪一步：沒有可搜尋的照片、分數太低，還是被後面的篩選拿掉
        print("[抽象搜尋] 可搜尋 \(index.count) 張、相似度基準 \(String(format: "%.2f", embedder.simFloor))、"
              + "結果 \(results.count) 筆、最高分 \(results.first.map { String(format: "%.3f", $0.score) } ?? "-")")
        #endif
        return Array(results.prefix(topK))
    }

    // MARK: - 相似度校正

    /// 用資料庫裡隨機兩張照片的描述相似度，估計「不相關文字」的 cosine 中位數，作為校正下限。
    /// 照片至少 50 張時第一次算好向量會自動執行；之後照片大量增加可以再手動呼叫。
    @discardableResult
    public func calibrateSimFloor(sampleSize: Int = 200) throws -> Float {
        // [PhotoAI 整合] 只用模型建圖的照片校正（文字型照片的紀錄彼此太像，會把基準估得太高）
        let vecs = try store.sampleDocVectors(model: embedder.modelName, limit: sampleSize, builtBy: Self.builderModelName)
        guard vecs.count >= 50 else { return embedder.simFloor }
        var sims: [Float] = []
        for i in 0..<vecs.count {
            for j in (i + 1)..<vecs.count {
                sims.append(ASScoring.dot(vecs[i], vecs[j]))
            }
        }
        sims.sort()
        // [PhotoAI 整合] 上限 0.85（原本 0.95）：基準太高時所有分數都會被壓到接近 0
        let median = min(sims[sims.count / 2], 0.85)
        embedder.simFloor = median
        UserDefaults.standard.set(median, forKey: floorKey)
        return median
    }

    // MARK: - 內部

    private func loadIndex() throws -> [ASImageIndex] {
        if let cached = lock.withLock({ cachedIndex }) { return cached }
        let index = try store.loadSearchable(model: embedder.modelName).map(ASImageIndex.init(stored:))
        lock.withLock { cachedIndex = index }
        return index
    }

    private func invalidateCache() {
        lock.withLock { cachedIndex = nil }
    }

    /// [PhotoAI 整合] 新分析好的照片加進（或取代）記憶體裡的搜尋索引；還沒讀過索引時不用做
    private func upsertCache(_ items: [ASImageIndex]) {
        guard !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        lock.withLock {
            guard let current = cachedIndex else { return }
            cachedIndex = current.filter { !ids.contains($0.id) } + items
        }
    }

    private func removeFromCache(_ ids: Set<String>) {
        lock.withLock { cachedIndex = cachedIndex?.filter { !ids.contains($0.id) } }
    }

    /// 照片內容有沒有變：用修改時間代替 PC 版的檔案雜湊
    static func contentHash(of asset: PHAsset) -> String {
        let date = asset.modificationDate ?? asset.creationDate ?? Date(timeIntervalSince1970: 0)
        return String(format: "%.0f", date.timeIntervalSince1970)
    }

    /// 讀取最長邊 768 像素的照片（對應 PC 版的影像前處理），並轉成方向正確的 CGImage
    static func loadImage(for asset: PHAsset, maxSide: CGFloat = 768) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true   // iCloud 上的照片也能下載
        options.isSynchronous = false

        let once = ASOnce()
        let image: UIImage? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: CGSize(width: maxSide, height: maxSide),
                                                  contentMode: .aspectFit,
                                                  options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded || image == nil, once.claim() else { return }
                cont.resume(returning: image)
            }
        }
        guard let image else { return nil }
        // UIImage 的方向資訊在轉成 CGImage 時會遺失，先重畫成正向
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return upright.cgImage
    }
}

/// 確保 continuation 只被 resume 一次
private final class ASOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

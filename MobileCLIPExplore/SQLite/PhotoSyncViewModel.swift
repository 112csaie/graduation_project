import Foundation
import Photos
import CoreML
import UIKit
import CoreLocation

struct BackgroundSyncSummary {
    let embeddedCount: Int
    let classifiedCount: Int
}

class PhotoSyncViewModel: ObservableObject {
    private static let executionStateQueue = DispatchQueue(label: "com.photoai.sync.execution")
    private static var isAnySyncRunning = false
    
    @Published var isSyncing = false
    @Published var syncedCount = 0
    @Published var totalCount = 0
    
    // 🌟 新增：用於控制暫停的標記
    private var isCancelled = false
    
    private let imageModel = try? mobileclip_s2_image(configuration: MLModelConfiguration())
    private let classificationQueue = DispatchQueue(label: "com.photoai.classification.worker", qos: .utility)
    private let classificationStateQueue = DispatchQueue(label: "com.photoai.classification.state")
    private let classificationBatchSize = 50
    private let metadataFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private var isScanningEmbeddings = false
    /// 掃描一批的張數：同時讀圖、一次推論、一次寫入
    private let scanBatchSize = 16
    /// 前景掃描、背景同步、重新分析共用同一個模型；推論時一次只讓一批進去
    private let predictionLock = NSLock()
    private var classifiedCountDuringCurrentSync = 0

    // 🌟 新增：由 UI 呼叫的暫停函數
    func stopSync() {
        print("使用者要求暫停同步")
        isCancelled = true
    }

    func startSync() {
        print("[SYNC] startSync() called")
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            print("[SYNC] auth status: \(status.rawValue)")
            guard status == .authorized || status == .limited else {
                print("未取得相簿權限")
                return
            }
            PhotoLibraryDeletionWatcher.shared.start()   // 第一次授權後開始監聽刪除（已開始時只做一次檢查）

            guard let self, self.beginSyncExecution() else {
                print("同步略過：已有其他同步任務正在執行")
                return
            }

            DispatchQueue.main.async {
                print("[SYNC] fetchAndProcessPhotos starting")
                self.isSyncing = true
                self.isCancelled = false
                self.fetchAndProcessPhotos()
            }
        }
    }

    func performBackgroundSync(
        scanLimit: Int = 20,
        classificationLimit: Int = 50,
        shouldContinue: @escaping () -> Bool = { true }
    ) -> BackgroundSyncSummary {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            print("背景同步略過：未取得相簿權限")
            return BackgroundSyncSummary(embeddedCount: 0, classifiedCount: 0)
        }

        guard beginSyncExecution() else {
            print("背景同步略過：已有其他同步任務正在執行")
            return BackgroundSyncSummary(embeddedCount: 0, classifiedCount: 0)
        }
        defer { endSyncExecution() }

        let assets = fetchUnscannedAssets(limit: scanLimit)
        guard shouldContinue() else {
            return BackgroundSyncSummary(embeddedCount: 0, classifiedCount: 0)
        }

        var embeddedCount = 0
        var start = 0
        while start < assets.count, shouldContinue() {
            let batch = Array(assets[start..<min(start + scanBatchSize, assets.count)])
            embeddedCount += embedBatch(batch, shouldReverseGeocode: false, allowNetworkAccess: false).count
            start += batch.count
        }

        let classifiedCount = shouldContinue()
            ? DatabaseManager.shared.classifyPendingPhotos(limit: classificationLimit)
            : 0

        // 個人化多標籤：沿用剛寫入的照片向量，不重算。
        if shouldContinue() {
            PersonalizationService.shared.tagPendingPhotos(limit: classificationLimit)
        }

        return BackgroundSyncSummary(
            embeddedCount: embeddedCount,
            classifiedCount: classifiedCount
        )
    }
    
    private func fetchAndProcessPhotos() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // 🌟 新增：強制只抓取最新的 1000 張照片
        fetchOptions.fetchLimit = 0
        
        let allAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        
        let scannedIds = DatabaseManager.shared.fetchAllScannedAssetIds()
        
        var unscannedAssets: [PHAsset] = []
        allAssets.enumerateObjects { (asset, _, _) in
            if !scannedIds.contains(asset.localIdentifier) {
                unscannedAssets.append(asset)
            }
        }
        
        guard !unscannedAssets.isEmpty else {
            // 在背景執行：反向地理編碼會等待結果，而 CLGeocoder 的回呼在主執行緒，若在主執行緒等待會卡死。
            DispatchQueue.global(qos: .utility).async {
                PersonalizationService.shared.scheduleTagging()
                let regions = self.backfillMissingLocationMetadata(limit: 100_000)
                self.triggerAbstractSearchBuild()
                DispatchQueue.main.async {
                    self.isSyncing = false
                    print("所有照片都已是最新的，無需掃描。排入地區查詢 \(regions) 張。")
                    NotificationCenter.default.post(name: NSNotification.Name("DatabaseUpdated"), object: nil)
                }
                self.endSyncExecution()
            }
            return
        }

        DispatchQueue.main.async {
            self.totalCount = unscannedAssets.count
            self.syncedCount = 0
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.endSyncExecution() }

            self.startClassificationWorker()
            // 掃描與分類同步進行：先準備分類文字向量，之後每掃描一批就交給分類佇列（不同執行緒，不會拖慢掃描）。
            PersonalizationService.shared.prepareTaggerInBackground()
            let taggingBatchSize = 50
            var embeddedSinceLastTagging = 0
            // 掃描進度最多每 0.5 秒更新一次畫面：以前每張照片都更新，首頁整頁跟著重算，
            // 下拉選單會被關掉、點擊也沒反應。
            var processedCount = 0
            var lastPublished = Date.distantPast

            // 一次處理一批（同時讀圖 → 一次推論 → 一次寫入資料庫），比一張一張快
            let timingStart = PerfLog.now()   // PF-03 首次掃描速度
            var start = 0
            while start < unscannedAssets.count {
                // 🌟 每一批開始前檢查是否被暫停
                if self.isCancelled {
                    print("同步已中斷")
                    break
                }
                // 手機太燙：等降溫再繼續（每 3 秒看一次；按暫停一樣會停）
                if DeviceLoad.isHot && !self.isCancelled { PerfLog.logThermalPause("掃描") }
                while DeviceLoad.isHot && !self.isCancelled { Thread.sleep(forTimeInterval: 3) }
                let batch = Array(unscannedAssets[start..<min(start + self.scanBatchSize, unscannedAssets.count)])
                start += batch.count

                let written = self.embedBatch(batch, shouldReverseGeocode: true, allowNetworkAccess: false).count
                guard written > 0 else { continue }
                processedCount += written
                if Date().timeIntervalSince(lastPublished) >= 0.5 {
                    lastPublished = Date()
                    let value = processedCount
                    DispatchQueue.main.async { self.syncedCount = value }
                }
                embeddedSinceLastTagging += written
                if embeddedSinceLastTagging >= taggingBatchSize {
                    embeddedSinceLastTagging = 0
                    PersonalizationService.shared.scheduleTagging()
                }
            }

            let finalCount = processedCount
            if finalCount > 0 { PerfLog.log("掃描", since: timingStart, count: finalCount) }
            DispatchQueue.main.async { self.syncedCount = finalCount }
            // 剛掃描進來的照片如果在「照片」App 已經是喜好項目，現在就同步（以前要等下次相簿變動才會出現）
            if finalCount > 0 { DatabaseManager.shared.syncSystemFavorites() }

            let classifiedCount = self.finishClassificationWorkerAndWait()
            if finalCount > 0 { PerfLog.log("掃描＋分類", since: timingStart, count: finalCount) }
            // 收尾：處理最後不足一批的照片（或中斷前已掃描的照片）。
            PersonalizationService.shared.scheduleTagging()
            self.backfillMissingLocationMetadata(limit: 100_000)
            self.triggerAbstractSearchBuild()

            DispatchQueue.main.async {
                self.isSyncing = false
                print("掃描任務結束！共新增處理 \(self.syncedCount) 張照片，完成分類 \(classifiedCount) 張。")
            }
        }
    }

    /// 抽象語意搜尋：同步完成後在背景替新照片建圖（iOS 27 + Apple Intelligence；不支援時不做任何事）。
    private func triggerAbstractSearchBuild() {
        AbstractSearchCoordinator.shared.scheduleBuild()
    }

    // 唯讀：只透過 PHImageManager 讀取縮圖，不修改原始照片。
    // 在背景執行緒「同步」讀取：結果直接在呼叫的執行緒回來。
    // 以前用非同步讀取，Photos 會在主執行緒呼叫回呼，模型推論和寫資料庫都跑在主執行緒上，掃描時畫面會卡。
    private func loadPixelBuffer(for asset: PHAsset, allowNetworkAccess: Bool) -> CVPixelBuffer? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = allowNetworkAccess
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        let targetSize = CGSize(width: 256, height: 256)

        var result: CVPixelBuffer?
        PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, _ in
            guard let cgImage = image?.cgImage else { return }
            result = self.pixelBuffer(from: cgImage, size: targetSize)
        }
        return result
    }

    /// 一批照片：同時讀取縮圖 → 一次送進模型 → 一次寫入資料庫。回傳成功寫入的照片 ID。
    /// 必須在背景執行緒呼叫。只讀取照片，不修改原始照片。
    private func embedBatch(_ assets: [PHAsset], shouldReverseGeocode: Bool, allowNetworkAccess: Bool) -> [String] {
        guard !assets.isEmpty, let model = imageModel else { return [] }

        // 1. 同時讀取縮圖（I/O 與解碼可以平行）
        var buffers = [CVPixelBuffer?](repeating: nil, count: assets.count)
        let bufferLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: assets.count) { index in
            let buffer = loadPixelBuffer(for: assets[index], allowNetworkAccess: allowNetworkAccess)
            bufferLock.lock()
            buffers[index] = buffer
            bufferLock.unlock()
        }

        var inputs: [mobileclip_s2_imageInput] = []
        var inputAssets: [PHAsset] = []
        for (index, buffer) in buffers.enumerated() {
            guard let buffer else { continue }
            inputs.append(mobileclip_s2_imageInput(image: buffer))
            inputAssets.append(assets[index])
        }
        guard !inputs.isEmpty else { return [] }

        // 2. 一次推論；批次失敗時逐張重試，避免一張壞圖拖累整批
        predictionLock.lock()
        let outputs: [mobileclip_s2_imageOutput?]
        if let batch = try? model.predictions(inputs: inputs), batch.count == inputs.count {
            outputs = batch.map { Optional($0) }
        } else {
            outputs = inputs.map { try? model.prediction(input: $0) }
        }
        predictionLock.unlock()

        // 3. 一次寫入（同一個 transaction）
        var rows: [(assetId: String, metadata: String, embeddingData: Data)] = []
        for (asset, output) in zip(inputAssets, outputs) {
            guard let output else {
                print("照片 \(asset.localIdentifier) 推論失敗")
                continue
            }
            let normalizedArray = output.final_emb_1.toFloatArray().normalized()
            let embeddingData = Data(buffer: UnsafeBufferPointer(start: normalizedArray, count: normalizedArray.count))
            rows.append((asset.localIdentifier, metadataJSONString(for: asset), embeddingData))
        }
        // 使用者在處理途中移除了某張照片的 AI 分析時，那張不會寫入
        let written = DatabaseManager.shared.insertPhotoEmbeddings(rows)

        if shouldReverseGeocode {
            let withLocation = inputAssets.filter { written.contains($0.localIdentifier) && $0.location != nil }
            if !withLocation.isEmpty {
                RegionResolver.shared.enqueue(withLocation.map(\.localIdentifier), priority: false)
            }
        }
        return inputAssets.map(\.localIdentifier).filter { written.contains($0) }
    }
    
    private func pixelBuffer(from image: CGImage, size: CGSize) -> CVPixelBuffer? {
        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        var pxbuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width),
                                         Int(size.height),
                                         kCVPixelFormatType_32ARGB,
                                         options as CFDictionary,
                                         &pxbuffer)
        
        guard status == kCVReturnSuccess, let buffer = pxbuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, .init(rawValue: 0))
        let pxdata = CVPixelBufferGetBaseAddress(buffer)
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: pxdata,
                                width: Int(size.width),
                                height: Int(size.height),
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: rgbColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        
        context?.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        CVPixelBufferUnlockBaseAddress(buffer, .init(rawValue: 0))
        
        return buffer
    }

    // MARK: - 第一級行政區（旅行相簿用）
    //
    // 所有反向地理編碼都交給 RegionResolver.shared（全 App 唯一的佇列），避免多個 PhotoSyncViewModel
    // 各自持有 CLGeocoder、同時送出請求而被 Apple 限流。

    /// 為有座標但還沒有第一級行政區資料的照片排入一般佇列（背景慢慢查，不阻塞呼叫端）。
    /// - Returns: 本次排入的張數。
    @discardableResult
    private func backfillMissingLocationMetadata(limit: Int) -> Int {
        let assetIds = DatabaseManager.shared.fetchAssetIdsNeedingLocationMetadata(limit: limit)
        return RegionResolver.shared.enqueue(assetIds, priority: false)
    }

    /// 優先查詢指定照片的第一級行政區（旅行中還沒有地名的旅程用）。
    func resolveRegions(assetIds: [String]) {
        RegionResolver.shared.enqueue(assetIds, priority: true)
    }

    /// 設定頁「補全地點資料」：把所有缺地區的照片排入佇列。
    func startLocationBackfill() {
        DispatchQueue.global(qos: .utility).async {
            let count = self.backfillMissingLocationMetadata(limit: 100_000)
            print("補全地點資料：已排入 \(count) 張")
        }
    }

    private func fetchUnscannedAssets(limit: Int? = nil) -> [PHAsset] {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // 🌟 確保背景同步也只針對最新照片做檢查
        fetchOptions.fetchLimit = 1000
        
        let allAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let scannedIds = DatabaseManager.shared.fetchAllScannedAssetIds()

        var unscannedAssets: [PHAsset] = []
        allAssets.enumerateObjects { asset, _, stop in
            guard !scannedIds.contains(asset.localIdentifier) else { return }
            unscannedAssets.append(asset)

            if let limit, unscannedAssets.count >= limit {
                stop.pointee = true
            }
        }
        return unscannedAssets
    }

    /// 單張照片（重新分析用）：和掃描走同一條路徑。
    private func processAssetForEmbedding(_ asset: PHAsset, shouldReverseGeocode: Bool = true, allowNetworkAccess: Bool = false) -> Bool {
        !embedBatch([asset], shouldReverseGeocode: shouldReverseGeocode, allowNetworkAccess: allowNetworkAccess).isEmpty
    }

    /// 重新分析單張照片：以唯讀方式重新讀取照片並產生新向量。必須在背景執行緒呼叫。
    /// 不會修改、移動或刪除原始照片。
    func reanalyzeAsset(assetId: String) -> Bool {
        guard !Thread.isMainThread else {
            assertionFailure("reanalyzeAsset 不可在主執行緒呼叫")
            return false
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            return false
        }
        return processAssetForEmbedding(asset, shouldReverseGeocode: true, allowNetworkAccess: true)
    }

    private func metadataJSONString(for asset: PHAsset) -> String {
        var metadataDict: [String: Any] = [:]
        if let date = asset.creationDate {
            metadataDict["date"] = date.description
            metadataDict["dayKey"] = metadataFormatter.string(from: date)
        }
        if let location = asset.location {
            metadataDict["latitude"] = location.coordinate.latitude
            metadataDict["longitude"] = location.coordinate.longitude
            metadataDict["coordinateText"] = String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: metadataDict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return "{}"
    }

    private func startClassificationWorker() {
        classificationStateQueue.sync {
            isScanningEmbeddings = true
            classifiedCountDuringCurrentSync = 0
        }

        classificationQueue.async {
            DatabaseManager.shared.prepareClassificationIfNeeded()

            while true {
                // 🌟 新增：背景分類也檢查是否被使用者取消
                if self.isCancelled { break }
                
                let classified = DatabaseManager.shared.classifyPendingPhotos(limit: self.classificationBatchSize)
                if classified > 0 {
                    self.classificationStateQueue.sync {
                        self.classifiedCountDuringCurrentSync += classified
                    }
                    continue
                }

                let stillScanning = self.classificationStateQueue.sync { self.isScanningEmbeddings }
                if !stillScanning {
                    break
                }

                Thread.sleep(forTimeInterval: 0.15)
            }

            while true {
                if self.isCancelled { break }
                let classified = DatabaseManager.shared.classifyPendingPhotos(limit: self.classificationBatchSize)
                guard classified > 0 else { break }
                self.classificationStateQueue.sync {
                    self.classifiedCountDuringCurrentSync += classified
                }
            }
        }
    }

    private func drainPendingClassifications() -> Int {
        DatabaseManager.shared.prepareClassificationIfNeeded()

        var total = 0
        while true {
            if self.isCancelled { break }
            let classified = DatabaseManager.shared.classifyPendingPhotos(limit: classificationBatchSize)
            guard classified > 0 else { break }
            total += classified
        }
        return total
    }

    private func finishClassificationWorkerAndWait() -> Int {
        classificationStateQueue.sync {
            isScanningEmbeddings = false
        }

        classificationQueue.sync { }

        return classificationStateQueue.sync {
            let total = classifiedCountDuringCurrentSync
            classifiedCountDuringCurrentSync = 0
            return total
        }
    }

    private func beginSyncExecution() -> Bool {
        Self.executionStateQueue.sync {
            guard !Self.isAnySyncRunning else { return false }
            Self.isAnySyncRunning = true
            return true
        }
    }

    private func endSyncExecution() {
        Self.executionStateQueue.sync {
            Self.isAnySyncRunning = false
        }
    }
}


// MARK: - 第一級行政區查詢佇列

/// 全 App 唯一的反向地理編碼佇列。
///
/// 為什麼需要：Apple 的 CLGeocoder 有頻率限制（約每分鐘數十次）。之前每個 PhotoSyncViewModel 各有一個
/// geocoder，掃描、補資料、旅行標題同時送請求，很快就被限流；失敗的照片在這次啟動中不會再查，
/// 旅行就一直停在「地點讀取中」。
///
/// 做法：
/// - 同一時間只送一個請求，請求之間至少間隔 `minInterval`。
/// - 兩個佇列：旅行標題需要的照片（priority）永遠先處理，掃描／補資料的照片（normal）之後慢慢查。
/// - 同一網格（約 2 km）查過就用快取，不再連網。
/// - 遇到限流或沒有網路：暫停 `throttleBackoff` 秒後重試同一張，最多 `maxAttempts` 次。
/// - 查不到地名（海上、偏遠地區）的照片記為 unresolvable，旅行改挑其他照片查詢。
/// 只讀取照片的位置資訊，不會修改原始照片。
final class RegionResolver {
    static let shared = RegionResolver()

    private let geocoder = CLGeocoder()
    private let queue = DispatchQueue(label: "com.photoai.geocode", qos: .utility)
    private let lock = NSLock()
    private var priorityIds: [String] = []
    private var normalIds: [String] = []
    private var queued = Set<String>()
    private var inFlight: String?
    private var unresolvable = Set<String>()
    private var gaveUp = Set<String>()        // 這次啟動多次限流仍失敗（例如沒有網路），下次啟動再試
    private var isRunning = false
    private var lastRequestAt = Date.distantPast
    /// 連續限流後判定為「暫時無法連線」，這段時間內不再排入需要網路的查詢（標題直接用備援名稱）。
    private var offlineUntil = Date.distantPast

    private let minInterval: TimeInterval = 1.3
    private let throttleBackoff: TimeInterval = 30
    private let maxAttempts = 3
    private let offlinePause: TimeInterval = 300
    private static let locale = Locale(identifier: "zh-Hant-TW")

    private init() {}

    /// 排入查詢。已在佇列中的照片不會重複排入；priority 會把已在一般佇列的照片提前。
    /// - Returns: 實際新排入（或提前）的張數。
    @discardableResult
    func enqueue(_ assetIds: [String], priority: Bool) -> Int {
        guard !assetIds.isEmpty else { return 0 }
        lock.lock()
        if Date() < offlineUntil {
            // 暫時無法連線：不排隊，讓旅行標題立即改用備援名稱；之後再開啟頁面會重新嘗試。
            for id in assetIds where !unresolvable.contains(id) { gaveUp.insert(id) }
            lock.unlock()
            return 0
        }
        var added = 0
        for id in assetIds where !unresolvable.contains(id) && inFlight != id {
            if priority {
                gaveUp.remove(id)   // 使用者正在看這個旅行：再給一次機會
                if queued.contains(id) {
                    guard let index = normalIds.firstIndex(of: id) else { continue }   // 已在優先佇列
                    normalIds.remove(at: index)
                }
                priorityIds.append(id)
            } else {
                guard !queued.contains(id), !gaveUp.contains(id) else { continue }
                normalIds.append(id)
            }
            queued.insert(id)
            added += 1
        }
        let shouldStart = !isRunning && added > 0
        if shouldStart { isRunning = true }
        lock.unlock()
        if shouldStart { queue.async { self.runLoop() } }
        return added
    }

    /// 是否還在查詢中（排隊或正在查）。旅行標題用來決定顯示「地點讀取中」或改用備援名稱。
    func isPending(_ assetId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return queued.contains(assetId) || inFlight == assetId
    }

    /// 已確定查不到，或這次啟動多次失敗而放棄。
    func isExhausted(_ assetId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return unresolvable.contains(assetId) || gaveUp.contains(assetId)
    }

    private func next() -> (id: String, isPriority: Bool)? {
        lock.lock(); defer { lock.unlock() }
        if !priorityIds.isEmpty {
            let id = priorityIds.removeFirst()
            queued.remove(id); inFlight = id
            return (id, true)
        }
        if !normalIds.isEmpty {
            let id = normalIds.removeFirst()
            queued.remove(id); inFlight = id
            return (id, false)
        }
        inFlight = nil
        isRunning = false
        return nil
    }

    private enum Outcome { case stored, noResult, throttled }

    private func runLoop() {
        var resolvedPriority = 0
        var resolvedNormal = 0
        while let item = next() {
            var attempts = 0
            var outcome: Outcome = .throttled
            while attempts < maxAttempts {
                attempts += 1
                outcome = resolve(assetId: item.id)
                guard outcome == .throttled else { break }
                print("[Region] 地理編碼被限流或沒有網路，\(Int(throttleBackoff)) 秒後重試（第 \(attempts) 次）")
                Thread.sleep(forTimeInterval: throttleBackoff)
            }
            lock.lock()
            inFlight = nil
            switch outcome {
            case .stored: break
            case .noResult: unresolvable.insert(item.id)
            case .throttled:
                // 多次重試仍失敗：視為暫時無法連線，清空佇列（下次開啟旅行頁或同步時會重新排入）
                gaveUp.insert(item.id)
                gaveUp.formUnion(priorityIds)
                queued.subtract(priorityIds)
                queued.subtract(normalIds)
                priorityIds.removeAll()
                normalIds.removeAll()
                offlineUntil = Date().addingTimeInterval(offlinePause)
            }
            let morePriority = !priorityIds.isEmpty
            lock.unlock()

            if outcome == .stored {
                if item.isPriority { resolvedPriority += 1 } else { resolvedNormal += 1 }
            }
            // 旅行標題：優先佇列處理完（或每 5 張）就更新畫面；失敗也要更新，讓標題改用備援名稱。
            if outcome == .throttled || (item.isPriority && !morePriority) {
                postTripUpdate(force: true)   // 旅行標題需要的照片查完了（或無法連線）：立即更新
            } else if item.isPriority, outcome == .stored, resolvedPriority % 5 == 0 {
                postTripUpdate()
            } else if resolvedNormal > 0 && resolvedNormal % 50 == 0 {
                postTripUpdate()
            }
        }
        if resolvedNormal > 0 || resolvedPriority > 0 { postTripUpdate(force: true) }
    }

    private var lastPostAt = Date.distantPast   // 只在 queue 上讀寫

    /// 通知旅行頁重新整理標題。中途的通知至少間隔 5 秒（旅行偵測會讀整個圖庫，不宜太頻繁）。
    private func postTripUpdate(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastPostAt) >= 5 else { return }
        lastPostAt = Date()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("TripRegionsUpdated"), object: nil)
        }
    }

    /// 在 queue 上執行（會等待地理編碼完成；CLGeocoder 的回呼在主執行緒，因此絕不可在主執行緒呼叫）。
    private func resolve(assetId: String) -> Outcome {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
              let location = asset.location else { return .noResult }

        let gridKey = RegionNaming.gridKey(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        if let cached = DatabaseManager.shared.cachedRegion(gridKey: gridKey) {
            Self.store(cached, locationText: nil, assetId: assetId)
            return .stored
        }

        let wait = minInterval - Date().timeIntervalSince(lastRequestAt)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        lastRequestAt = Date()

        var outcome: Outcome = .noResult
        let semaphore = DispatchSemaphore(value: 0)
        geocoder.reverseGeocodeLocation(location, preferredLocale: Self.locale) { placemarks, error in
            defer { semaphore.signal() }
            if let error = error as? CLError, error.code == .network {
                outcome = .throttled   // 頻率限制或沒有網路
                return
            }
            guard error == nil, let placemark = placemarks?.first else { return }

            // 第一級行政區；沒有 administrativeArea 的地區（新加坡、香港…）改用城市名稱，最後才用國家名稱
            let name = [placemark.administrativeArea, placemark.locality, placemark.country]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            guard let name else { return }
            let region = GeoRegion(name: name,
                                   country: placemark.country ?? "",
                                   countryCode: placemark.isoCountryCode ?? "")

            let locationText = Array(NSOrderedSet(array: [
                placemark.name, placemark.locality, placemark.administrativeArea, placemark.country
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
                .compactMap { $0 as? String }
                .joined(separator: ", ")

            DatabaseManager.shared.cacheRegion(region, gridKey: gridKey)
            Self.store(region, locationText: locationText.isEmpty ? nil : locationText, assetId: assetId)
            outcome = .stored
        }
        semaphore.wait()
        return outcome
    }

    private static func store(_ region: GeoRegion, locationText: String?, assetId: String) {
        var updates: [String: Any] = [
            "regionName": region.name,
            "regionCountry": region.country,
            "regionCountryCode": region.countryCode,
            "regionVersion": 2,
        ]
        if let locationText { updates["locationText"] = locationText }
        DatabaseManager.shared.updatePhotoMetadata(assetId: assetId, merge: updates, notify: false)
    }
}

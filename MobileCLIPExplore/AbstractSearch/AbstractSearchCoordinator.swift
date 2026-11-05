// AbstractSearchCoordinator.swift
//
// 抽象語意搜尋模組（v10，資料夾內 AS 開頭的檔案）與 App 的整合層：
// - 首頁搜尋框：search(_:) 回傳依分數排序、已過濾掉明顯不相關結果的照片 ID
// - 建圖：同步照片後在背景建圖（新照片優先）；也排一個充電時的背景任務接續
// - 移除 AI 分析資料：一併刪除該照片的場景圖與向量
// - 照片被刪除：建圖前清掉資料庫裡已不存在的照片
//
// 模組只「讀取」照片（PHImageManager），資料存在獨立的 Application Support/AbstractSearch.sqlite，
// 不修改、不刪除使用者的原始照片或系統相簿。
//
// 需要 iOS 27 + Apple Intelligence；不支援的裝置 isAvailable 為 false，搜尋只用 MobileCLIP 與分類標籤。

import Foundation
import Photos
import BackgroundTasks
import Accelerate
import UIKit

extension Notification.Name {
    /// 抽象語意搜尋的建圖進度或索引內容有變化
    static let abstractSearchIndexUpdated = Notification.Name("AbstractSearchIndexUpdated")
}

final class AbstractSearchCoordinator: ObservableObject {
    static let shared = AbstractSearchCoordinator()

    /// Info.plist 的 BGTaskSchedulerPermittedIdentifiers 也要有這個 ID
    static let backgroundTaskIdentifier = "com.elaine.MobileCLIPExplore.abstractsearch.build"

    // 搜尋結果過濾：分數低於第一名的這個比例、或低於最低分的不顯示（初始值，依實際結果調整）
    // 分數已依「不相關照片」的相似度校正過：不相關約 0，明顯相關通常 0.3 以上。
    // 已分析的照片還少時，第一名也可能不相關，所以最低分要夠高，不能只看相對比例。
    static let relativeScoreCutoff: Float = 0.7
    static let minimumScore: Float = 0.3

    @Published private(set) var isBuilding = false
    @Published private(set) var buildDone = 0
    @Published private(set) var buildTotal = 0
    @Published private(set) var lastBuildMessage: String?
    /// 這次分析：幾乎一樣、直接沿用場景圖的照片數
    @Published private(set) var reusedCount = 0
    /// 平均每張（實際交給模型的照片）花的秒數：讀圖、模型
    @Published private(set) var averageImageSeconds: Double?
    @Published private(set) var averageModelSeconds: Double?

    /// 剩餘時間估計（秒）：還沒分析的張數 × 平均每張秒數
    var estimatedRemainingSeconds: Double? {
        guard let image = averageImageSeconds, let model = averageModelSeconds, buildTotal > buildDone else { return nil }
        return Double(buildTotal - buildDone) * (image + model)
    }

    /// 幾乎一樣的照片：MobileCLIP 相似度達此值、且拍攝時間相差在 maxDuplicateGap 內，就沿用同一份場景圖
    static let duplicateSimilarity: Float = 0.95
    static let maxDuplicateGap: TimeInterval = 30 * 60
    /// 文字類照片（截圖、文件、收據、簡報）排到最後：主題分類與文字比對已經能找到它們，智慧搜尋幫助不大
    static let lowPriorityTags: Set<String> = ["screenshot", "chat_screenshot", "document", "handwritten_notes", "receipt", "slides"]

    private let lock = NSLock()
    private var buildTask: Task<Void, Never>?

    // MARK: 分析範圍

    static let rangeMonthsKey = "ASAbstractSearch.rangeMonths"
    /// 可選的分析範圍（月）；0 = 全部照片
    static let rangeOptions: [(months: Int, title: String)] = [(0, "全部照片"), (12, "最近 1 年"), (6, "最近半年"), (3, "最近 3 個月")]

    /// 只分析最近幾個月的照片（0 = 全部）。照片很多時可以先分析最近的，搜尋常用的照片比較快可用。
    /// 已分析的舊照片不會刪除，照樣可以搜尋。
    @Published var analysisRangeMonths: Int = UserDefaults.standard.integer(forKey: AbstractSearchCoordinator.rangeMonthsKey) {
        didSet {
            guard analysisRangeMonths != oldValue else { return }
            UserDefaults.standard.set(analysisRangeMonths, forKey: Self.rangeMonthsKey)
            restartBuild()
        }
    }

    // MARK: 使用者暫停

    /// 使用者按了「暫停分析」：待在 App 裡（切換頁面、同步新照片）都不會自動開始，要按「繼續分析」。
    /// 離開 App 再回來就恢復預設，自動接續分析（見 clearUserPause）。只記在記憶體，不存檔。
    @Published private(set) var isPausedByUser = false
    private var pausedFlag = false   // lock 保護，給背景執行緒讀

    /// 「暫停分析」按鈕：這張分析完就停，之後不自動開始
    func pauseByUser() {
        setPausedByUser(true)
        cancelBuild()
    }

    /// 離開 App 時呼叫：解除使用者暫停，回到 App 時照預設自動接續分析
    func clearUserPause() {
        setPausedByUser(false)
    }

    /// 「立即分析／繼續分析」按鈕：解除暫停並開始
    func resumeByUser() {
        setPausedByUser(false)
        lock.lock()
        let busy = buildTask != nil
        lock.unlock()
        guard busy else { scheduleBuild(); return }
        // 剛按過暫停、上一輪還在收尾（這張分析完才停）：等它結束再開始，避免按了沒反應
        Task.detached(priority: .background) { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.lock.lock()
                let idle = self.buildTask == nil
                self.lock.unlock()
                if idle { self.scheduleBuild(); return }
            }
        }
    }

    private func setPausedByUser(_ paused: Bool) {
        lock.lock()
        pausedFlag = paused
        lock.unlock()
        if Thread.isMainThread {
            isPausedByUser = paused
        } else {
            DispatchQueue.main.async { self.isPausedByUser = paused }
        }
    }

    private var analysisCutoff: Date? {
        let months = analysisRangeMonths
        guard months > 0 else { return nil }
        return Calendar.current.date(byAdding: .month, value: -months, to: Date())
    }

    /// 改了範圍：停下目前這輪（這張分析完才停），再依新範圍重新開始
    private func restartBuild() {
        let wasBuilding = isBuilding
        cancelBuild()
        guard wasBuilding else { scheduleBuild(); return }
        Task.detached(priority: .background) { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.lock.lock()
                let idle = self.buildTask == nil
                self.lock.unlock()
                if idle { self.scheduleBuild(); return }
            }
        }
    }

    private init() {
        // 舊版（暫停會存檔）留下的設定：清掉，避免一直維持暫停
        UserDefaults.standard.removeObject(forKey: "ASAbstractSearch.pausedByUser")
    }

    // MARK: 可用性

    /// 系統版本支援（iOS 27 以上）
    var isSupportedOS: Bool {
        if #available(iOS 27, *) { return true }
        return false
    }

    /// 裝置與設定可以使用（iOS 27 + Apple Intelligence 已開啟且模型已下載）
    var isAvailable: Bool {
        if #available(iOS 27, *) { return ASAbstractSearchService.isAvailable }
        return false
    }

    /// 不能用時給使用者看的原因
    var unavailableReason: String? {
        guard #available(iOS 27, *) else { return "需要 iOS 27 以上（目前 iOS \(UIDeviceVersion.current)）" }
        guard !ASAbstractSearchService.isAvailable else { return nil }
        return "Apple Intelligence 無法使用：\(ASModelAvailability.unavailableReason ?? "未知原因")"
    }

    // MARK: 搜尋

    /// 首頁搜尋框用。無法使用或出錯時回傳空陣列（首頁仍有 MobileCLIP 與分類標籤的結果）。
    func search(_ text: String, topK: Int = 30) async -> [String] {
        await searchScored(text, topK: topK).map(\.id)
    }

    /// [PhotoAI 整合] 同 search，另外回傳分數（首頁用分數決定要不要再用照片向量確認）
    func searchScored(_ text: String, topK: Int = 30) async -> [(id: String, score: Float)] {
        guard #available(iOS 27, *), ASAbstractSearchService.isAvailable else { return [] }
        do {
            let service = try await ASServiceHolder.shared.service()
            let results = try await service.search(text, topK: topK)
            guard let top = results.first?.score, top > 0 else {
                print("[抽象搜尋] 「\(text)」沒有任何照片有分數")
                return []
            }
            let cutoff = max(Self.minimumScore, top * Self.relativeScoreCutoff)
            let kept = results.filter { $0.score >= cutoff }
            if kept.isEmpty {
                print("[抽象搜尋] 「\(text)」最高分 \(String(format: "%.3f", top)) 低於門檻 \(String(format: "%.2f", cutoff))，全部不顯示")
            }
            #if DEBUG
            for r in kept.prefix(5) {
                print("[抽象搜尋] \(String(format: "%.3f", r.score)) \(r.channelScores) \(r.description.prefix(60))")
            }
            #endif
            return kept.map { (id: $0.localIdentifier, score: $0.score) }
        } catch {
            print("[抽象搜尋] 搜尋失敗: \(error)")
            return []
        }
    }

    // MARK: 建圖

    /// 同步照片後呼叫：在背景替還沒建圖的照片建圖（已建好、沒修改過的會跳過）。同時只會有一個建圖工作。
    /// 使用者在 App 裡按過「暫停分析」時不會自動開始（要按「繼續分析」，見 resumeByUser）。
    func scheduleBuild() {
        guard #available(iOS 27, *), ASAbstractSearchService.isAvailable else { return }
        lock.lock()
        guard !pausedFlag, buildTask == nil else { lock.unlock(); return }
        let task = Task.detached(priority: .background) { [weak self] in
            await self?.runBuild()
            self?.finishBuildTask()
        }
        buildTask = task
        lock.unlock()
    }

    /// 停止前景建圖（目前這張完成後停止，下次從沒建好的照片接續）
    func cancelBuild() {
        lock.lock()
        buildTask?.cancel()
        lock.unlock()
    }

    private func finishBuildTask() {
        lock.lock()
        buildTask = nil
        lock.unlock()
    }

    /// 建圖本體。回傳是否被中斷。
    /// - Parameter inBackgroundTask: 系統排程的背景任務（充電時）才傳 true。
    ///   一般情況下 App 一進到背景就停：系統會限制背景的 Foundation Models，繼續跑只會每張都失敗。
    @discardableResult
    func runBuild(inBackgroundTask: Bool = false) async -> Bool {
        guard #available(iOS 27, *), ASAbstractSearchService.isAvailable else { return false }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }

        let service: ASAbstractSearchService
        do {
            service = try await ASServiceHolder.shared.service()
        } catch {
            await publish(message: "無法載入文字向量模型：\(error.localizedDescription)")
            return false
        }

        // 新照片優先
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetch = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        var allIds = Set<String>()
        fetch.enumerateObjects { asset, _, _ in
            assets.append(asset)
            allIds.insert(asset.localIdentifier)
        }

        // 已從系統相簿刪除的照片：只清掉這個模組資料庫裡的舊資料
        if let removed = try? service.removeDeletedAssets(keeping: allIds), removed > 0 {
            print("[抽象搜尋] 清除已不存在的照片 \(removed) 張")
        }
        // 使用者「移除 AI 分析資料」的照片不再自動建圖（「重新分析」後會恢復）；一次查出，不用每張照片各查一次
        let aiRemoved = DatabaseManager.shared.aiRemovedAssetIds()
        assets = assets.filter { !aiRemoved.contains($0.localIdentifier) }
        // 使用者選了分析範圍：只分析這段時間的照片（範圍外已分析的照片保留，照樣搜尋得到）
        if let cutoff = analysisCutoff {
            assets = assets.filter { ($0.creationDate ?? .distantPast) >= cutoff }
        }

        // 加速 1：文字類照片（截圖、文件…）排到最後
        let lowPriority = PersonalizationService.shared.assetIds(withAnyAcceptedTag: Self.lowPriorityTags)
        let isLowPriority: (PHAsset) -> Bool = {
            $0.mediaSubtypes.contains(.photoScreenshot) || lowPriority.contains($0.localIdentifier)
        }
        assets = assets.filter { !isLowPriority($0) } + assets.filter(isLowPriority)

        // 加速 2：幾乎一樣的照片（連拍、同一個畫面拍好幾張）只讓模型看一張，其他沿用
        let groups = Self.duplicateGroups(assets)
        // 代表照片已經建好的群：直接沿用（例如新拍的連拍跟之前分析過的照片幾乎一樣）；全部沿用完才一起算文字向量
        let reused = (try? service.copyGraphs(groups.map { (source: $0.key.localIdentifier, targets: $0.value) })) ?? 0
        let representatives = assets.filter { groups[$0] != nil }   // 保持優先順序
        let pending = service.pendingAssets(representatives)

        await MainActor.run {
            self.isBuilding = true
            self.buildDone = 0
            self.buildTotal = pending.count
            self.reusedCount = reused
        }
        print("[抽象搜尋] 共 \(assets.count) 張：代表照片 \(representatives.count) 張，需要分析 \(pending.count) 張，沿用 \(reused) 張")

        // 分批建圖：模組在每次 buildIndex 結束時才計算文字向量，整批送進去的話要全部分析完才搜尋得到。
        // 每 20 張一批，分析好的照片馬上可以搜尋，進度也逐張更新。
        let chunkSize = 20
        var summary = ASBuildSummary()
        var offset = 0
        while offset < pending.count {
            if Task.isCancelled { summary.stopReason = .cancelled; break }
            // 手機太燙：先停，降溫後自動接續（見 DeviceLoad）。這是最吃電的工作（手機上的語言模型逐張看照片）
            if DeviceLoad.isHot { print("[抽象搜尋] 手機較熱，先暫停"); summary.stopReason = .cancelled; break }
            if !inBackgroundTask {
                let isActive = await MainActor.run { UIApplication.shared.applicationState != .background }
                if !isActive { summary.stopReason = .cancelled; break }
            }
            let chunk = Array(pending[offset..<min(offset + chunkSize, pending.count)])
            let base = offset
            // 文字很多的照片（文件、收據、截圖）：用照片上的文字和分類名稱產生紀錄，不請模型看圖（新版模組的功能）
            let raw = PersonalizationService.shared.searchBuildHints(for: chunk.map(\.localIdentifier))
            let hints: [String: ASPhotoHint] = raw.mapValues { item in
                ASPhotoHint(ocrText: item.text, clipTags: item.tags.map { ASClipTag(tag: $0.name, score: $0.score) })
            }
            let part = await service.buildIndex(for: chunk, hint: { hints[$0] }, progress: { progress in
                let done = base + progress.done
                DispatchQueue.main.async {
                    AbstractSearchCoordinator.shared.buildDone = done
                }
            })
            summary.built += part.built
            summary.textOnly += part.textOnly
            summary.pending += part.pending
            summary.skipped += part.skipped
            summary.failed += part.failed
            summary.imageSeconds += part.imageSeconds
            summary.modelSeconds += part.modelSeconds
            offset += chunk.count

            // 剛建好的代表照片：把場景圖沿用給它的相似照片
            let reusedNow = (try? service.copyGraphs(chunk.compactMap { representative in
                groups[representative].map { (source: representative.localIdentifier, targets: $0) }
            })) ?? 0
            let built = summary.built
            let imageAverage = built > 0 ? summary.imageSeconds / Double(built) : nil
            let modelAverage = built > 0 ? summary.modelSeconds / Double(built) : nil
            await MainActor.run {
                self.reusedCount += reusedNow
                if let imageAverage, let modelAverage {
                    self.averageImageSeconds = imageAverage
                    self.averageModelSeconds = modelAverage
                }
            }
            if part.built > 0 || reusedNow > 0 { await postIndexUpdated() }   // 設定頁的「可以搜尋」張數跟著更新
            // 被取消、模型被系統限制或不能用：先停，下次從沒處理的照片接續
            if part.cancelled { summary.stopReason = part.stopReason; break }
        }
        if summary.built > 0 {
            print(String(format: "[抽象搜尋] 平均每張：讀圖 %.2fs、模型 %.2fs（%d 張）",
                         summary.imageSeconds / Double(summary.built), summary.modelSeconds / Double(summary.built), summary.built))
        }
        // 建圖期間使用者「移除 AI 分析資料」的照片：可能在移除之後才建好，這裡再刪一次
        let removedNow = DatabaseManager.shared.aiRemovedAssetIds()
        let removedDuringBuild = Set(assets.map(\.localIdentifier).filter { removedNow.contains($0) })
        if !removedDuringBuild.isEmpty {
            _ = try? service.removeAssets(removedDuringBuild)
        }

        let reusedTotal = await MainActor.run { self.reusedCount }
        let message = "新建 \(summary.built) 張、文字照片 \(summary.textOnly) 張、沿用相似照片 \(reusedTotal) 張、失敗 \(summary.failed) 張"
            + (summary.cancelled ? "（已中斷，下次接續）" : "")
        print("[抽象搜尋] 建圖結束：\(message)")
        await MainActor.run {
            self.isBuilding = false
            self.lastBuildMessage = message
        }
        await postIndexUpdated()
        return summary.cancelled
    }

    /// 把幾乎一樣的照片分成一群：代表照片 → 其他成員。用掃描時算好的 MobileCLIP 照片向量（記憶體快取），
    /// 只比較拍攝時間相差 maxDuplicateGap 以內的照片。代表照片是群裡最新的一張（照新照片優先的順序）。
    /// 沒有向量或沒有拍攝時間的照片自己一群。
    static func duplicateGroups(_ assets: [PHAsset]) -> [PHAsset: [PHAsset]] {
        let features = DatabaseManager.shared.featureCacheSnapshot()
        var groups: [PHAsset: [PHAsset]] = [:]
        // 依拍攝時間新到舊，用滑動視窗只比較時間相近的代表照片
        let dated = assets.compactMap { asset -> (asset: PHAsset, date: Date, vector: [Float])? in
            guard let date = asset.creationDate,
                  let vector = features[asset.localIdentifier]?.embedding, !vector.isEmpty else { return nil }
            return (asset, date, vector)
        }.sorted { $0.date > $1.date }
        var window: [(asset: PHAsset, date: Date, vector: [Float])] = []
        var assigned = Set<String>()
        for item in dated {
            assigned.insert(item.asset.localIdentifier)
            window.removeAll { $0.date.timeIntervalSince(item.date) > maxDuplicateGap }
            if let match = window.first(where: { cosine($0.vector, item.vector) >= duplicateSimilarity }) {
                groups[match.asset, default: []].append(item.asset)
            } else {
                groups[item.asset] = []
                window.append(item)
            }
        }
        // 沒有向量或時間的照片：自己當代表
        for asset in assets where !assigned.contains(asset.localIdentifier) {
            groups[asset] = []
        }
        return groups
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = vDSP.dot(a, b), na = vDSP.sumOfSquares(a), nb = vDSP.sumOfSquares(b)
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    // MARK: 移除 AI 分析資料

    /// 刪除這張照片的場景圖與向量（不動照片本身）。回傳刪除的筆數。
    @discardableResult
    func removeAnalysis(assetId: String) async -> Int {
        guard #available(iOS 27, *) else { return 0 }
        do {
            let service = try await ASServiceHolder.shared.service(prepare: false)
            let removed = try service.removeAssets([assetId])
            if removed > 0 { await postIndexUpdated() }
            return removed
        } catch {
            print("[抽象搜尋] 刪除索引失敗: \(error)")
            return 0
        }
    }

    // MARK: 場景描述（回憶草稿用）

    /// 已分析照片的一句話描述（場景圖的說明與事件）。iOS 27 以前或沒分析過的照片沒有結果。
    func sceneDescriptions(for assetIds: [String]) async -> [String: String] {
        guard #available(iOS 27, *), !assetIds.isEmpty,
              let service = try? await ASServiceHolder.shared.service(prepare: false) else { return [:] }
        var result: [String: String] = [:]
        for assetId in assetIds {
            guard let graph = service.sceneGraph(for: assetId) else { continue }
            let parts = [graph.explanation, graph.event]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { result[assetId] = Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }.joined(separator: "；") }
        }
        return result
    }

    // MARK: 診斷

    func indexStats() async -> ASIndexStats? {
        guard #available(iOS 27, *) else { return nil }
        return try? await ASServiceHolder.shared.service(prepare: false).indexStats()
    }

    /// 與 PC 版搜尋演算法的一致性檢查（App 內附 parity_fixture.json 時才能執行）
    func runParityCheck() -> String {
        guard let url = Bundle.main.url(forResource: "parity_fixture", withExtension: "json") else {
            return "App 內沒有 parity_fixture.json"
        }
        do {
            return try ASParityCheck.run(fixtureURL: url)
        } catch {
            return "無法執行：\(error)"
        }
    }

    // MARK: 背景任務（充電時接續建圖）

    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task.detached(priority: .background) {
                let cancelled = await AbstractSearchCoordinator.shared.runBuild(inBackgroundTask: true)
                task.setTaskCompleted(success: !cancelled)
                AbstractSearchCoordinator.shared.scheduleBackgroundBuild()
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    func scheduleBackgroundBuild() {
        guard isAvailable else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        // 不限定充電：沒接電源時系統也可以排這個任務。實際何時執行、給多少時間仍由 iOS 決定
        // （通常是手機閒置、電量足夠時），系統也可能限制背景的 Foundation Models。
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[抽象搜尋] 背景建圖排程失敗: \(error)")
        }
    }

    // MARK: 工具

    private func publish(message: String) async {
        print("[抽象搜尋] \(message)")
        await MainActor.run { self.lastBuildMessage = message }
    }

    private func postIndexUpdated() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .abstractSearchIndexUpdated, object: nil)
        }
    }
}

/// 整個 App 共用一個 ASAbstractSearchService；文字向量模型只載入一次。
@available(iOS 27, *)
private actor ASServiceHolder {
    static let shared = ASServiceHolder()

    private var instance: ASAbstractSearchService?
    private var isPrepared = false

    /// - Parameter prepare: 搜尋與建圖需要先載入文字向量模型；只刪除資料或讀統計時不需要。
    func service(prepare: Bool = true) async throws -> ASAbstractSearchService {
        let service: ASAbstractSearchService
        if let instance {
            service = instance
        } else {
            service = try ASAbstractSearchService(databaseURL: ASAbstractSearchService.defaultDatabaseURL())
            instance = service
        }
        if prepare && !isPrepared {
            try await service.prepare()
            isPrepared = true
        }
        return service
    }
}

/// 不用 UIKit 也能取得系統版本字串
private enum UIDeviceVersion {
    static var current: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}

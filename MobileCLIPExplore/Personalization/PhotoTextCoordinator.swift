// PhotoTextCoordinator.swift
//
// 照片文字辨識（OCR）：用 Apple Vision 在手機上辨識，結果存進 PhotoAI.sqlite 的 PhotoText 表。
// - 使用者在照片頁按「辨識照片中的文字」時，辨識那一張
// - 看起來像紙張或卡片的照片（票根、收據、證件、菜單、文件）自動辨識，由文字決定分類；其他照片不會自動掃描
// - 只讀取照片（PHImageManager 取縮小版），不上傳、不修改、不刪除照片
// - 辨識過的照片：首頁搜尋可以用文字找到、文字提到的分類當作分類線索、「我的 IP」名稱比對

import Foundation
import ImageIO
import Photos
import UIKit
import os
import Vision

extension Notification.Name {
    /// 有新的照片文字辨識結果（統計數字、搜尋結果、標籤可能改變）
    static let photoTextUpdated = Notification.Name("PhotoTextUpdated")
}

final class PhotoTextCoordinator: ObservableObject {
    static let shared = PhotoTextCoordinator()

    @Published private(set) var stats: PhotoTextStats?

    struct PaperScanProgress: Equatable {
        let done: Int
        let total: Int
    }
    /// 紙張類照片的文字辨識進度；沒有在跑時為 nil
    @Published private(set) var paperScan: PaperScanProgress?

    private var store: PersonalizationStore? { DatabaseManager.shared.personalization }
    private let scanLock = NSLock()
    private var paperScanTask: Task<Void, Never>?

    private init() {}

    // MARK: 紙張與卡片（自動）

    /// 有新照片分類好、或回到 App 時呼叫：辨識還沒辨識過、看起來像紙張或卡片的照片。
    /// 同時只會有一個工作；工作進行中有新照片進來，會在下一輪一起處理。
    func schedulePaperScan(delay: TimeInterval = 3) {
        scanLock.lock()
        guard paperScanTask == nil else { scanLock.unlock(); return }
        paperScanTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.runPaperScan()
            self?.finishPaperScan()
        }
        scanLock.unlock()
    }

    /// 離開 App 時停止（這張辨識完就停，下次從沒辨識的接續）
    func cancelPaperScan() {
        scanLock.lock()
        paperScanTask?.cancel()
        scanLock.unlock()
    }

    private func finishPaperScan() {
        scanLock.lock()
        paperScanTask = nil
        scanLock.unlock()
    }

    private func runPaperScan() async {
        guard !Task.isCancelled else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited, let store else { return }

        // 一輪 200 張；辨識期間有新照片進來（掃描、分類還在跑），下一輪接著處理，直到沒有要辨識的照片
        var attempted = Set<String>()   // 這次已經試過的（讀不到的照片不重複試）
        var done = 0
        var total = 0
        var withText: [String] = []
        let timingStart = PerfLog.now()   // PF-05 文字辨識速度
        // 以前菜單、筆記上的菜名被當成「麵食」等待確認：照新規則重新整理一次
        PersonalizationService.shared.recheckDishTextCandidatesOnce()
        while !Task.isCancelled {
            // 手機太燙或低耗電模式：先停，降溫後自動接續（見 DeviceLoad）
            if DeviceLoad.shouldPauseLightWork {
                print("[文字辨識] 手機較熱或低耗電模式，先暫停")
                if DeviceLoad.isHot { PerfLog.logThermalPause("文字辨識") }
                break
            }
            let ids = PersonalizationService.shared.paperPhotosNeedingOCR(limit: 200 + attempted.count)
                .filter { !attempted.contains($0) }
                .prefix(200)
            guard !ids.isEmpty else { break }
            total += ids.count
            print("[文字辨識] 紙張或卡片的照片：\(ids.count) 張")
            await publishPaperScan(PaperScanProgress(done: done, total: total))
            for id in ids {
                if Task.isCancelled { break }
                attempted.insert(id)
                // 票根、收據常只佔畫面一小塊（例如手上拿著幾張票），字比較小
                if case .text(let text) = PhotoTextRecognizer.recognize(assetId: id, minimumTextHeight: 0.006),
                   (try? store.savePhotoText(assetId: id, text: text)) == true, !text.isEmpty {
                    withText.append(id)
                }
                done += 1
                // 每 20 張重新整理一次這些照片的分類（文字決定票根、收據…），不用等全部辨識完
                if withText.count >= 20 {
                    PersonalizationService.shared.applyTextHints(assetIds: withText)
                    withText = []
                }
                if done % 5 == 0 { await publishPaperScan(PaperScanProgress(done: done, total: total)) }
                if DeviceLoad.shouldPauseLightWork {
                    if DeviceLoad.isHot { PerfLog.logThermalPause("文字辨識") }
                    break
                }
                await DeviceLoad.breather()
            }
        }
        if !withText.isEmpty { PersonalizationService.shared.applyTextHints(assetIds: withText) }
        await publishPaperScan(nil)
        guard done > 0 else { return }
        PerfLog.log("文字辨識", since: timingStart, count: done)
        PersonalizationService.shared.scheduleCustomMatching(delay: 1)
        refreshStats()
        await MainActor.run { NotificationCenter.default.post(name: .photoTextUpdated, object: nil) }
    }

    private func publishPaperScan(_ value: PaperScanProgress?) async {
        await MainActor.run { self.paperScan = value }
    }

    // MARK: 辨識一張（使用者按下按鈕時）

    /// 辨識並儲存這張照片的文字。回傳辨識到的文字（沒有文字為空字串）；讀不到照片時回傳 nil。
    func recognizeNow(assetId: String) async -> String? {
        let text: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            switch PhotoTextRecognizer.recognize(assetId: assetId) {
            case .text(let value): return value
            case .assetMissing, .imageUnavailable: return nil
            }
        }.value
        guard let text, let store else { return text }
        guard (try? store.savePhotoText(assetId: assetId, text: text)) == true else { return text }
        if !text.isEmpty {
            // 文字裡提到的分類：重新整理這張照片的自動標籤；也重新比對「我的 IP」名稱
            PersonalizationService.shared.applyTextHints(assetIds: [assetId])
            PersonalizationService.shared.scheduleCustomMatching(delay: 1)
        }
        refreshStats()
        await MainActor.run { NotificationCenter.default.post(name: .photoTextUpdated, object: nil) }
        return text
    }

    // MARK: 查詢

    func refreshStats() {
        let value = try? store?.photoTextStats()
        DispatchQueue.main.async { self.stats = value }
    }

    /// 已辨識的文字：nil = 還沒辨識；空字串 = 辨識過但沒有文字
    func recognizedText(for assetId: String) -> String? {
        try? store?.photoText(assetId: assetId)
    }

    /// 首頁搜尋：文字中包含查詢的照片（只含辨識過、仍在相簿中的照片）
    func assetIds(matching query: String) -> [String] {
        guard let ids = try? store?.assetIds(matchingPhotoText: query), !ids.isEmpty else { return [] }
        let existing = DatabaseManager.shared.existingAssetIds(ids)
        return ids.filter { existing.contains($0) }
    }
}

// MARK: - Vision 辨識

enum PhotoTextRecognizer {
    enum Result {
        case text(String)
        case assetMissing
        case imageUnavailable
    }

    /// 辨識語言：繁中、簡中、英文（Vision 的中文只能和英文一起使用）
    static let languages = ["zh-Hant", "zh-Hans", "en-US"]

    /// - Parameter minimumTextHeight: 忽略比這更小的字（相對於照片高度）。票根、收據常只佔畫面一小塊，自動辨識時用較小的值。
    static func recognize(assetId: String, minimumTextHeight: Float = 0.008) -> Result {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
            return .assetMissing
        }
        guard asset.mediaType == .image else { return .text("") }
        guard let (cgImage, orientation) = loadImage(asset) else { return .imageUnavailable }

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])

        // 1. 快速判斷有沒有字（截圖一定有字，直接跳過這步）
        if !asset.mediaSubtypes.contains(.photoScreenshot) {
            let detect = VNDetectTextRectanglesRequest()
            detect.reportCharacterBoxes = false
            guard (try? handler.perform([detect])) != nil else { return .text("") }
            let boxes = detect.results ?? []
            if boxes.isEmpty { return .text("") }
        }

        // 2. 精準辨識
        return .text(recognizeText(handler: handler, minimumTextHeight: minimumTextHeight))
    }

    /// 辨識一張圖片的文字（分享進來的截圖用，不經過相簿）
    static func recognize(image: UIImage, minimumTextHeight: Float = 0.008) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation), options: [:])
        return recognizeText(handler: handler, minimumTextHeight: minimumTextHeight)
    }

    private static func recognizeText(handler: VNImageRequestHandler, minimumTextHeight: Float) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        request.minimumTextHeight = minimumTextHeight   // 忽略非常小的字（多半是雜訊），也比較快
        guard (try? handler.perform([request])) != nil else { return "" }
        let lines = (request.results ?? []).compactMap { observation -> String? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
            let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
        return String(lines.joined(separator: "\n").prefix(4000))
    }

    /// 韓文、日文另外辨識一次（Vision 的中文只能和英文一起，第一次辨識時韓文、日文會變亂碼）。
    /// 只回傳含韓文字或日文假名的行；清單整理時用，不存進資料庫，也不影響一般的文字辨識。
    static func extraScripts(image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        var lines: [String] = []
        for (language, isScript) in [("ko-KR", isHangul), ("ja-JP", isKana)] as [(String, (Unicode.Scalar) -> Bool)] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = [language, "en-US"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.008
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            // 這支手機不支援該語言時會失敗：略過就好
            guard (try? handler.perform([request])) != nil else { continue }
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { continue }
                let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.unicodeScalars.filter(isScript).count >= 2 { lines.append(line) }
            }
        }
        return String(lines.joined(separator: "\n").prefix(1500))
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7AF).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value) || (0x3130...0x318F).contains(scalar.value)
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041...0x30FF).contains(scalar.value)
    }

    /// 讀取縮小版（長邊約 1600 px）供辨識；只讀取，不修改照片
    private static func loadImage(_ asset: PHAsset) -> (CGImage, CGImagePropertyOrientation)? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        var result: UIImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600),
                                              contentMode: .aspectFit, options: options) { image, _ in
            result = image
        }
        guard let image = result, let cgImage = image.cgImage else { return nil }
        return (cgImage, CGImagePropertyOrientation(image.imageOrientation))
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}


// MARK: - 手機發燙時放慢背景整理

/// 背景整理（辨識文字、智慧搜尋分析、照片掃描）共用的降溫規則：
/// - 手機很燙（系統回報 serious 以上）：先停下來，降溫後自動接續
/// - 有點熱（fair）：每張照片之間多休息一下
/// - 低耗電模式：辨識文字先停（照片掃描、智慧搜尋照常，可以在「整理進度」暫停）
enum DeviceLoad {
    static var isHot: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    /// 辨識文字這類不急的工作要不要先停
    static var shouldPauseLightWork: Bool { isHot || ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// 每處理一張照片後休息一下，不讓處理器一直滿載；有點熱時休息久一點
    static func breather() async {
        let nanoseconds: UInt64 = ProcessInfo.processInfo.thermalState == .nominal ? 20_000_000 : 250_000_000
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    /// 降溫或關掉低耗電模式時，App 在前景就接續背景整理
    private static let observers: [NSObjectProtocol] = [
        ProcessInfo.thermalStateDidChangeNotification,
        Notification.Name.NSProcessInfoPowerStateDidChange,
    ].map { name in
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard !DeviceLoad.isHot, UIApplication.shared.applicationState == .active else { return }
                PhotoTextCoordinator.shared.schedulePaperScan(delay: 5)
                AbstractSearchCoordinator.shared.scheduleBuild()
            }
        }
    }

    static func startObserving() { _ = observers }
}

// MARK: - 測試用計時紀錄（系統測試報告第 3.4 節的績效 KPI）

/// 只在 Debug 版記錄，正式版（Release）什麼都不做。
/// 每一行的格式：`[計時] 名稱 | 1.234s | 120 張 | 97.3 張/秒 | 備註`
/// - Xcode 主控台或 Mac「主機」App（Console）搜尋「[計時]」都看得到
///   （量啟動時間、過熱暫停時建議不要接著 Xcode 除錯，改用「主機」App 看，數字比較準）
/// - 整段複製存成文字檔後，用 PersonalizationCore/Scripts/kpi_timing.py 算平均、p95
enum PerfLog {
    #if DEBUG
    private static let logger = Logger(subsystem: "selfIE", category: "計時")
    private static let lock = NSLock()
    /// 手機變熱（serious 以上）的時間；降溫後清掉
    private static var hotSince: UInt64?
    private static var launchLogged = false
    private static var thermalObserver: NSObjectProtocol?
    #endif

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
    }

    /// 印出從 start 到現在的時間；有張數時一起印出每秒幾張
    static func log(_ name: String, since start: UInt64, count: Int? = nil, note: String = "") {
        #if DEBUG
        write(name, seconds: seconds(since: start), count: count, note: note)
        #endif
    }

    #if DEBUG
    private static func write(_ name: String, seconds value: Double, count: Int?, note: String) {
        var line = "[計時] \(name) | \(String(format: "%.3f", value))s"
        if let count {
            let rate = value > 0 ? String(format: "%.1f", Double(count) / value) : "-"
            line += " | \(count) 張 | \(rate) 張/秒"
        }
        if !note.isEmpty { line += " | \(note)" }
        logger.notice("\(line, privacy: .public)")
    }
    #endif

    /// 從 App 程序啟動到首頁出現的時間（只記第一次）。PF-06
    static func logLaunchOnce() {
        #if DEBUG
        lock.lock()
        let first = !launchLogged
        launchLogged = true
        lock.unlock()
        guard first else { return }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return }
        let started = info.kp_proc.p_starttime
        let startSeconds = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        write("啟動到首頁", seconds: Date().timeIntervalSince1970 - startSeconds, count: nil, note: "")
        #endif
    }

    /// 記錄手機變熱的時間，之後各項背景工作暫停時印出「變熱後幾秒暫停」。PF-10
    static func startThermalWatch() {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            let state = ProcessInfo.processInfo.thermalState
            let hot = state == .serious || state == .critical
            lock.lock()
            if hot, hotSince == nil { hotSince = now() }
            if !hot { hotSince = nil }
            lock.unlock()
            let names: [ProcessInfo.ThermalState: String] = [.nominal: "正常", .fair: "有點熱", .serious: "很熱", .critical: "嚴重"]
            logger.notice("[計時] 熱狀態 | \(names[state] ?? "未知", privacy: .public)")
        }
        #endif
    }

    /// 背景工作因為過熱停下來時呼叫（work：掃描、文字辨識…）
    static func logThermalPause(_ work: String) {
        #if DEBUG
        lock.lock()
        let start = hotSince
        lock.unlock()
        if let start {
            log("過熱暫停", since: start, note: work)
        } else {
            logger.notice("[計時] 過熱暫停 | \(work, privacy: .public) | 沒有記到變熱的時間")
        }
        #endif
    }
}

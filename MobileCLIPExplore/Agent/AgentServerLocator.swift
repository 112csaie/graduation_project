// AgentServerLocator.swift
//
// 自動找 Agent 後端的位址，不用每次換網路就改 Info.plist 重新編譯。
//
// 尋找順序：
// 1. 使用者在「設定 › Agent 伺服器」手動輸入的位址（有填就直接用，不檢查）
// 2. 上次連得到的位址、Info.plist 的 AGENT_API_BASE_URL（先用 /health 快速確認還連得到）
// 3. Bonjour：後端啟動時會在區域網路廣播 _photoai-agent._tcp（api_server.py 用 macOS 內建的 dns-sd），
//    手機在同一個 Wi-Fi 就找得到，不需要知道 IP
//
// 限制：Bonjour 需要手機和電腦在同一個區域網路，而且網路沒有擋多播（部分校園／公司 Wi-Fi 會擋）。
// 找不到時仍可手動輸入位址。

import Foundation
import Network
import Combine

enum AgentServerError: LocalizedError {
    case notFound
    var errorDescription: String? {
        "找不到 Agent 伺服器。請確認電腦已啟動後端、手機和電腦在同一個 Wi-Fi，或到「設定 › Agent 伺服器」手動輸入位址。"
    }
}

actor AgentServerLocator {
    static let shared = AgentServerLocator()

    static let serviceType = "_photoai-agent._tcp"

    enum Source: String {
        case manual = "手動設定"
        case discovered = "自動尋找（Bonjour）"
        case saved = "上次連線的位址"
        case bundled = "App 內建位址"
    }

    struct Status {
        let url: String?
        let source: Source?
        let checkedAt: Date?
    }

    private static let manualKey = "agentServer.manualURL"
    private static let lastGoodKey = "agentServer.lastGoodURL"

    private var current: String?
    private var currentSource: Source?
    private var checkedAt: Date?
    private var resolving: Task<String?, Never>?

    /// 檢查用的短逾時連線（正式請求的逾時很長，不能拿來判斷伺服器在不在）
    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: 設定

    nonisolated var manualURL: String? {
        Self.normalize(UserDefaults.standard.string(forKey: Self.manualKey))
    }

    /// 設定手動位址；傳 nil 或空字串改回自動尋找
    func setManualURL(_ value: String?) {
        if let normalized = Self.normalize(value) {
            UserDefaults.standard.set(normalized, forKey: Self.manualKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.manualKey)
        }
        current = nil
        currentSource = nil
        checkedAt = nil
    }

    nonisolated var bundledURL: String? {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AGENT_API_BASE_URL") as? String,
           let normalized = Self.normalize(configured) {
            return normalized
        }
        return Self.normalize(ProcessInfo.processInfo.environment["AGENT_API_BASE_URL"])
    }

    func status() -> Status {
        if let manual = manualURL { return Status(url: manual, source: .manual, checkedAt: nil) }
        return Status(url: current, source: currentSource, checkedAt: checkedAt)
    }

    // MARK: 取得位址

    /// 目前要連的位址；找不到時丟出 AgentServerError.notFound
    func baseURL(forceRefresh: Bool = false) async throws -> String {
        if let manual = manualURL { return manual }
        // 剛確認過的位址直接用，不用每次都檢查
        if !forceRefresh, let current, let checkedAt, Date().timeIntervalSince(checkedAt) < 60 {
            return current
        }
        if forceRefresh { invalidate() }
        if let resolving {
            if let url = await resolving.value { return url }
            throw AgentServerError.notFound
        }
        let task = Task { await self.resolve() }
        resolving = task
        let url = await task.value
        resolving = nil
        guard let url else { throw AgentServerError.notFound }
        return url
    }

    /// 請求連不上時呼叫：下次重新尋找
    func invalidate() {
        current = nil
        currentSource = nil
        checkedAt = nil
    }

    /// 現在連得到伺服器嗎？（手動位址也實際檢查一次；給「有沒有連上電腦」的狀態用）
    func checkReachable() async -> Bool {
        if let manual = manualURL { return await isReachable(manual) }
        return (try? await baseURL()) != nil
    }

    /// 重新尋找（設定頁的按鈕）
    func refresh() async -> Status {
        _ = try? await baseURL(forceRefresh: true)
        return status()
    }

    private func resolve() async -> String? {
        // 1. 已知的位址：上次成功的、App 內建的
        var known: [(String, Source)] = []
        if let saved = Self.normalize(UserDefaults.standard.string(forKey: Self.lastGoodKey)) { known.append((saved, .saved)) }
        if let bundled = bundledURL, !known.contains(where: { $0.0 == bundled }) { known.append((bundled, .bundled)) }
        for (url, source) in known {
            if await isReachable(url) {
                remember(url, source: source)
                return url
            }
        }
        // 2. Bonjour
        let discovered = await discover(timeout: 4)
        for url in discovered {
            if await isReachable(url) {
                remember(url, source: .discovered)
                return url
            }
        }
        return nil
    }

    private func remember(_ url: String, source: Source) {
        current = url
        currentSource = source
        checkedAt = Date()
        UserDefaults.standard.set(url, forKey: Self.lastGoodKey)
    }

    /// 伺服器有回應就算連得到（舊版後端沒有 /health，會回 404，也算）
    private func isReachable(_ base: String) async -> Bool {
        guard let url = URL(string: "\(base)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await probeSession.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    // MARK: Bonjour

    /// 在區域網路找廣播 _photoai-agent._tcp 的後端，回傳找到的位址（例如 http://192.168.0.12:8000）
    private nonisolated func discover(timeout: TimeInterval) async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            let queue = DispatchQueue(label: "AgentServerLocator.discovery")
            let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
            // 以下變數只在 queue 上存取
            var finished = false
            var found: [String] = []
            var tried = Set<NWEndpoint>()
            var connections: [NWConnection] = []

            func finish() {
                guard !finished else { return }
                finished = true
                browser.cancel()
                connections.forEach { $0.cancel() }
                continuation.resume(returning: found)
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results where !tried.contains(result.endpoint) {
                    tried.insert(result.endpoint)
                    // 只用 IPv4，避免 IPv6 鏈路本地位址放進網址的問題
                    let parameters = NWParameters.tcp
                    if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                        ip.version = .v4
                    }
                    let connection = NWConnection(to: result.endpoint, using: parameters)
                    connections.append(connection)
                    connection.stateUpdateHandler = { state in
                        guard case .ready = state else { return }
                        if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint,
                           let url = Self.url(host: host, port: port), !found.contains(url) {
                            found.append(url)
                            finish()   // 找到一台就夠了
                        }
                        connection.cancel()
                    }
                    connection.start(queue: queue)
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish() }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    private static func url(host: NWEndpoint.Host, port: NWEndpoint.Port) -> String? {
        func stripInterface(_ text: String) -> String {
            text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        }
        switch host {
        case .ipv4(let address):
            return "http://\(stripInterface("\(address)")):\(port.rawValue)"
        case .ipv6(let address):
            return "http://[\(stripInterface("\(address)"))]:\(port.rawValue)"
        case .name(let name, _):
            return "http://\(name):\(port.rawValue)"
        @unknown default:
            return nil
        }
    }

    // MARK: 工具

    /// 「192.168.0.12:8000」→「http://192.168.0.12:8000」；去掉結尾的 /
    nonisolated static func normalize(_ value: String?) -> String? {
        var text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text), components.host?.isEmpty == false else { return nil }
        return text
    }
}


// MARK: - 有沒有連上電腦

/// Agent 對話、回憶筆記、想去清單／購物清單的「加入」都需要電腦上的後端。
/// 這裡記錄目前連不連得到，介面用來事先標示「需要連上電腦」，而不是按了才跳錯誤。
/// 其他功能（搜尋、分類、相簿、清單的瀏覽與編輯）都在手機上，不受影響。
final class AgentConnection: ObservableObject {
    static let shared = AgentConnection()

    enum State: Equatable {
        case unknown, checking, connected, offline
    }

    @Published private(set) var state: State = .unknown
    private var lastCheck: Date?
    private var checkTask: Task<Void, Never>?

    private init() {}

    var isOffline: Bool { state == .offline }

    /// 檢查一次（30 秒內檢查過就不重複，除非 force）
    func check(force: Bool = false) {
        DispatchQueue.main.async {
            if !force, let lastCheck = self.lastCheck, Date().timeIntervalSince(lastCheck) < 30 { return }
            guard self.checkTask == nil else { return }
            self.lastCheck = Date()
            if self.state == .unknown { self.state = .checking }   // 已知連不上時，檢查期間維持「連不上」，提示不會閃掉
            self.checkTask = Task {
                let ok = await AgentServerLocator.shared.checkReachable()
                await MainActor.run {
                    self.state = ok ? .connected : .offline
                    self.checkTask = nil
                }
            }
        }
    }

    /// 實際請求的結果（成功或連不上）
    func report(connected: Bool) {
        DispatchQueue.main.async {
            self.lastCheck = Date()
            self.state = connected ? .connected : .offline
        }
    }
}

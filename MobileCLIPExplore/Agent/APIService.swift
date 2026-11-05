import Foundation
import UIKit

// MARK: - Request Models

struct TurnRequest: Codable {
    let message: String
    let image_path: String?
    /// 之前的對話（和這次的訊息分開送，後端的「要不要存」規則只看這次的訊息）
    var context: String? = nil
    /// 圖片分析結果（不再塞進訊息文字裡）
    var image_analysis: String? = nil
    /// 筆記存在手機：送上相關筆記，後端只回傳決定，不讀寫自己的資料庫
    var local_notes: [LocalWikiNote]? = nil
    /// 使用者選了「延續筆記」的那一篇
    var target_topic: String? = nil
}

struct WikiSearchRequest: Codable {
    let query: String
    let top_k: Int
}

// MARK: - Response Models

struct TurnResponse: Codable {
    let reply: String
    let mode: String?
    let topic: String?
    let summary: String?
    let web_search: String?
    let image_analysis: String?
    let wiki_action: String?
    /// 後端的決定：store／update／skip（筆記存在手機時才有）
    var wiki_decision: String? = nil
    var new_content: String? = nil
    var reason: String? = nil

    enum CodingKeys: String, CodingKey {
        case reply, mode, topic, summary
        case web_search, image_analysis, wiki_action
        case wiki_decision, new_content, reason
    }
}

struct WikiItem: Codable, Identifiable {
    var id: String { topic }
    let topic: String
    let summary: String
    let preview: String?
    let updated_at: String?
}

struct WikiCandidate: Codable {
    let topic: String
    let summary: String
    let content: String
    let score: Double
}

struct WikiSearchResult: Codable {
    let query: String
    let status: String
    let exact: WikiCandidate?
    let candidates: [WikiCandidate]?
}

struct ImageAnalyzeResponse: Codable {
    let analysis: String
}

struct MemoryDraftRequest: Codable {
    let kind: String            // trip / concert / event / album
    let title_hint: String?
    let date_range: String?
    let places: [String]
    let photo_context: String
    let local_notes: [LocalWikiNote]
    let user_note: String?
}

struct MemoryDraftResponse: Codable {
    let reply: String
    let wiki_decision: String   // store / update / skip
    let topic: String?
    let summary: String?
    let new_content: String?
    let reason: String?
}

struct PlacesRequest: Codable {
    let text: String
    let image_analysis: String?
}

struct ExtractedPlace: Codable, Hashable {
    let name: String
    let address: String
    let area: String
    let category: String
    let note: String
}

struct PlacesResponse: Codable {
    let places: [ExtractedPlace]
}

/// 購物清單：從商品截圖整理出的商品
struct ExtractedProduct: Codable, Hashable {
    let name: String
    let brand: String
    let price: String
    let store: String
    let country_code: String
    let note: String
}

struct ProductsResponse: Codable {
    let items: [ExtractedProduct]
}

// MARK: - APIService

class APIService {
    static let shared = APIService()

    /// 後端位址由 AgentServerLocator 自動尋找（手動設定 → 上次的位址／Info.plist → 區域網路 Bonjour）

    /// 送出請求；連不上時重新尋找一次伺服器再試（例如電腦換了 IP）
    private func send(path: String, build: (URL) throws -> URLRequest) async throws -> Data {
        do {
            let data = try await sendOnce(path: path, build: build)
            AgentConnection.shared.report(connected: true)
            return data
        } catch {
            // 找不到伺服器、連不上：記下來，介面上標示「需要連上電腦」
            if error is AgentServerError || (error as? URLError).map(Self.isUnreachable) == true {
                AgentConnection.shared.report(connected: false)
            }
            throw error
        }
    }

    private func sendOnce(path: String, build: (URL) throws -> URLRequest) async throws -> Data {
        let locator = AgentServerLocator.shared
        var base = try await locator.baseURL()
        for attempt in 0..<2 {
            guard let url = URL(string: "\(base)\(path)") else { throw URLError(.badURL) }
            do {
                let (data, response) = try await session.data(for: try build(url))
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch let error as URLError where attempt == 0 && Self.isUnreachable(error) {
                await locator.invalidate()
                let next = try await locator.baseURL(forceRefresh: true)
                guard next != base else { throw error }
                base = next
            }
        }
        throw AgentServerError.notFound
    }

    private static func isUnreachable(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
         .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3000
        config.timeoutIntervalForResource = 3000
        return URLSession(configuration: config)
    }()

    // MARK: - /turn

    /// 舊介面：沒有分開的對話紀錄
    func askAgent(message: String, image: UIImage?) async throws -> TurnResponse {
        try await askAgent(message: message, context: nil, image: image, targetTopic: nil, assetIds: [])
    }

    /// 送出一輪對話。筆記存在手機：
    /// 1. 先在手機上找出相關筆記一起送給後端（後端不再讀寫它自己的 Wiki 資料庫）
    /// 2. 後端回傳「新建／更新／略過」與筆記內容
    /// 3. 由手機寫進自己的資料庫，並記錄這次對話用到的照片
    func askAgent(message: String, context: String?, image: UIImage?, targetTopic: String?,
                  assetIds: [String]) async throws -> TurnResponse {
        var analysis: String?
        if let image {
            analysis = try? await analyzeImage(image: image, prompt: message)
        }
        let notes = await WikiService.shared.relatedNotes(for: message, targetTopic: targetTopic)

        let body = TurnRequest(message: message.isEmpty && analysis != nil ? "請描述這張圖片" : message,
                               image_path: nil,
                               context: context,
                               image_analysis: analysis,
                               local_notes: notes,
                               target_topic: targetTopic)

        let payload = try JSONEncoder().encode(body)
        let data = try await send(path: "/turn") { url in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        }
        let turn = try JSONDecoder().decode(TurnResponse.self, from: data)

        // 後端決定要存：寫進手機的資料庫
        var wikiAction = turn.wiki_action
        var topic = turn.topic
        var reply = turn.reply
        switch turn.wiki_decision {
        case "store", "update":
            if let saved = try await WikiService.shared.apply(decision: turn.wiki_decision, topic: turn.topic,
                                                              summary: turn.summary, content: turn.new_content,
                                                              assetIds: assetIds) {
                wikiAction = saved.action
                topic = saved.topic
            } else {
                wikiAction = "skipped:筆記內容不完整"
                reply = "已略過存入 Wiki：筆記內容不完整"
            }
        case "skip":
            wikiAction = "skipped:\(turn.reason ?? "")"
        default:
            break
        }
        return TurnResponse(reply: TraditionalChinese.convert(reply), mode: turn.mode, topic: topic, summary: turn.summary,
                            web_search: turn.web_search, image_analysis: turn.image_analysis,
                            wiki_action: wikiAction, wiki_decision: turn.wiki_decision,
                            new_content: turn.new_content, reason: turn.reason)
    }

    // MARK: - /image/analyze (multipart)

    func analyzeImage(image: UIImage, prompt: String) async throws -> String {
        guard let imageData = image.jpegData(compressionQuality: 0.5) else { throw URLError(.cannotCreateFile) }

        let boundary = UUID().uuidString
        var body = Data()
        func append(_ string: String) { body.append(string.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\n")
        append("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        append("\r\n")

        let msg = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "請描述這張圖片" : prompt
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"message\"\r\n\r\n")
        append(msg)
        append("\r\n")
        append("--\(boundary)--\r\n")

        let payload = body
        let data = try await send(path: "/image/analyze") { url in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        }
        return try JSONDecoder().decode(ImageAnalyzeResponse.self, from: data).analysis
    }

    // MARK: - 回憶草稿、想去清單（照片只在手機上整理成文字，不上傳）

    private func postJSON<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        let payload = try JSONEncoder().encode(body)
        let data = try await send(path: path) { url in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return request
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func draftMemory(_ request: MemoryDraftRequest) async throws -> MemoryDraftResponse {
        try await postJSON("/draft/memory", body: request)
    }

    func extractPlaces(text: String, imageAnalysis: String?) async throws -> [ExtractedPlace] {
        let response: PlacesResponse = try await postJSON("/extract/places",
                                                          body: PlacesRequest(text: text, image_analysis: imageAnalysis))
        return response.places
    }

    /// 商品截圖的文字 → 想買的商品（購物清單）
    func extractProducts(text: String, imageAnalysis: String?) async throws -> [ExtractedProduct] {
        let response: ProductsResponse = try await postJSON("/extract/products",
                                                            body: PlacesRequest(text: text, image_analysis: imageAnalysis))
        return response.items
    }

    // MARK: - 個人 Wiki（存在手機，不需要連線）

    func listWiki(limit: Int = 50) async throws -> [WikiItem] {
        try await WikiService.shared.list(limit: limit)
    }

    func deleteWiki(topic: String) async throws {
        try await WikiService.shared.delete(topic: topic)
    }

    func searchWiki(query: String, topK: Int = 5) async throws -> WikiSearchResult {
        try await WikiService.shared.search(query: query, topK: topK)
    }
}

//
//  ASSceneGraph.swift
//  抽象語意搜尋模組（v10）
//
//  場景圖的儲存格式。JSON 欄位名稱與 PC 版（pipeline_v10.py）完全相同，
//  所以手機上的 SQLite 資料庫可以直接拿回 PC，用 evaluate.py、draw_graph.py 分析。
//

import Foundation

// MARK: - 場景圖

public struct ASEntity: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var concept: String
    public var count: Int
    public var attributes: [String]

    public init(id: String, name: String, category: String, concept: String, count: Int, attributes: [String]) {
        self.id = id
        self.name = name
        self.category = category
        self.concept = concept
        self.count = count
        self.attributes = attributes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, concept, count, attributes
    }

    // 寬鬆解碼：PC 舊資料可能缺欄位或型別不同，缺的一律給預設值
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        category = (try? c.decode(String.self, forKey: .category)) ?? ""
        concept = (try? c.decode(String.self, forKey: .concept)) ?? ""
        count = (try? c.decode(Int.self, forKey: .count)) ?? 1
        attributes = (try? c.decode([String].self, forKey: .attributes)) ?? []
    }
}

public struct ASRelation: Codable, Hashable, Sendable {
    public var subject: String
    public var predicate: String
    public var object: String
    public var relationType: String
    public var confidence: String

    public init(subject: String, predicate: String, object: String, relationType: String, confidence: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
        self.relationType = relationType
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case subject, predicate, object, confidence
        case relationType = "relation_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        predicate = (try? c.decode(String.self, forKey: .predicate)) ?? ""
        object = (try? c.decode(String.self, forKey: .object)) ?? ""
        relationType = (try? c.decode(String.self, forKey: .relationType)) ?? ""
        confidence = (try? c.decode(String.self, forKey: .confidence)) ?? ""
    }
}

public struct ASScene: Codable, Hashable, Sendable {
    public var location: String = ""
    public var setting: String = ""
    public var timeOfDay: String = ""

    public init(location: String = "", setting: String = "", timeOfDay: String = "") {
        self.location = location
        self.setting = setting
        self.timeOfDay = timeOfDay
    }

    enum CodingKeys: String, CodingKey {
        case location, setting
        case timeOfDay = "time_of_day"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        location = (try? c.decode(String.self, forKey: .location)) ?? ""
        setting = (try? c.decode(String.self, forKey: .setting)) ?? ""
        timeOfDay = (try? c.decode(String.self, forKey: .timeOfDay)) ?? ""
    }
}

public struct ASEmotion: Codable, Hashable, Sendable {
    public var tags: [String] = []

    public init(tags: [String] = []) { self.tags = tags }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
    }
}

public struct ASSceneGraph: Codable, Hashable, Sendable {
    public var contentType: String = "photo"
    public var entities: [ASEntity] = []
    public var relations: [ASRelation] = []
    public var scene: ASScene = ASScene()
    public var event: String = ""
    public var explanation: String = ""
    public var captionEn: String = ""
    public var emotion: ASEmotion = ASEmotion()
    public var appContext: String = ""
    public var visibleTextSummary: String = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case entities, relations, scene, event, explanation, emotion
        case contentType = "content_type"
        case captionEn = "caption_en"
        case appContext = "app_context"
        case visibleTextSummary = "visible_text_summary"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentType = (try? c.decode(String.self, forKey: .contentType)) ?? "photo"
        entities = (try? c.decode([ASEntity].self, forKey: .entities)) ?? []
        relations = (try? c.decode([ASRelation].self, forKey: .relations)) ?? []
        scene = (try? c.decode(ASScene.self, forKey: .scene)) ?? ASScene()
        event = (try? c.decode(String.self, forKey: .event)) ?? ""
        explanation = (try? c.decode(String.self, forKey: .explanation)) ?? ""
        captionEn = (try? c.decode(String.self, forKey: .captionEn)) ?? ""
        emotion = (try? c.decode(ASEmotion.self, forKey: .emotion)) ?? ASEmotion()
        appContext = (try? c.decode(String.self, forKey: .appContext)) ?? ""
        visibleTextSummary = (try? c.decode(String.self, forKey: .visibleTextSummary)) ?? ""
    }

    /// 格式保底（對應 PC 版 normalize_graph）：只修格式，不改內容。
    public func normalized() -> ASSceneGraph {
        var g = self
        if !["photo", "screenshot", "document"].contains(g.contentType) {
            g.contentType = "photo"
        }
        var seen = Set<String>()
        g.entities = g.entities.enumerated().map { k, e in
            var e = e
            var eid = e.id.trimmingCharacters(in: .whitespaces)
            if eid.isEmpty { eid = "e\(k + 1)" }
            if seen.contains(eid) { eid = "\(eid)_\(k)" }
            seen.insert(eid)
            e.id = eid
            e.count = max(1, e.count)
            e.attributes = e.attributes.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return e
        }
        return g
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func fromJSON(_ text: String) -> ASSceneGraph? {
        try? JSONDecoder().decode(ASSceneGraph.self, from: Data(text.utf8))
    }
}

// MARK: - 查詢解析結果

public struct ASParsedEntity: Codable, Hashable, Sendable {
    public var text: String
    public var concept: String
    public var category: String
    /// 0 代表查詢沒有指定數量
    public var count: Int
    public var attributes: [String]
}

public struct ASParsedRelation: Codable, Hashable, Sendable {
    public var subject: String
    public var predicate: String
    /// 空字串代表不及物動作，例如「散步」
    public var object: String
    public var relationType: String
}

public struct ASParsedQuery: Codable, Hashable, Sendable {
    public var entities: [ASParsedEntity] = []
    public var relations: [ASParsedRelation] = []
    public var scene: ASScene = ASScene()
    public var event: String = ""
    public var mood: [String] = []
    /// 空字串、screenshot 或 document
    public var contentType: String = ""
    public var queryEn: String = ""
}

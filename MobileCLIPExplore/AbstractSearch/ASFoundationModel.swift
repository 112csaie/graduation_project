//
//  ASFoundationModel.swift
//  抽象語意搜尋模組（v10）
//
//  用 Apple Intelligence 的 Foundation Models（iOS 27）：
//  - 建圖：模型直接看照片，輸出場景圖（對應 PC 版的 Gemini 建圖）
//  - 查詢解析：把使用者輸入的文字解析成結構化查詢
//
//  [PhotoAI 整合] App 的最低版本是 iOS 18.6，這個檔案用到的 Foundation Models API
//  （@Generable、圖片 Attachment）需要 iOS 27，所以相關型別都標上 @available(iOS 27, *)。
//
//  PC 版要求模型輸出 JSON 再自己解析、失敗重試；這裡改用 @Generable 的結構化輸出，
//  框架保證輸出符合格式，所以提示詞裡不需要再描述 JSON 格式，可以省下 context。
//

import Foundation
import FoundationModels
import CoreGraphics

// MARK: - 共用的選項清單

enum ASVocabulary {
    static let categories = ["person", "animal", "object", "food", "plant", "vehicle",
                             "structure", "nature", "ui", "content", "other"]
    static let relationTypes = ["spatial", "possession", "action", "comparison"]
}

// MARK: - 建圖的輸出格式

@available(iOS 27, *)
@Generable(description: "照片中的一個主體")
struct ASGenEntity {
    @Guide(description: "編號，依序為 e1、e2、e3")
    var id: String

    @Guide(description: "繁體中文名稱，用最具體且有把握的說法")
    var name: String

    @Guide(description: "類別", .anyOf(ASVocabulary.categories))
    var category: String

    @Guide(description: "通用英文名詞；具體品種或型號也要寫出所屬的通用類別，例如柴犬寫 dog")
    var concept: String

    @Guide(description: "數量；同類無法區分的多個個體合併時填總數", .range(1...99))
    var count: Int

    @Guide(description: "外觀、顏色、材質、狀態、表情、正在做的動作，繁體中文", .maximumCount(5))
    var attributes: [String]
}

@available(iOS 27, *)
@Generable(description: "兩個主體之間的關係")
struct ASGenRelation {
    @Guide(description: "主詞主體的 id")
    var subject: String

    @Guide(description: "繁體中文動詞或空間詞")
    var predicate: String

    @Guide(description: "受詞主體的 id，不可與主詞相同")
    var object: String

    @Guide(description: "關係類型", .anyOf(ASVocabulary.relationTypes))
    var relationType: String

    @Guide(description: "把握程度", .anyOf(["high", "medium", "low"]))
    var confidence: String
}

@available(iOS 27, *)
@Generable(description: "一張照片的場景圖")
struct ASGenGraph {
    @Guide(description: "照片類型", .anyOf(["photo", "screenshot", "document"]))
    var contentType: String

    @Guide(description: "照片中的主體，最多 8 個", .maximumCount(8))
    var entities: [ASGenEntity]

    @Guide(description: "主體之間的關係，最多 8 條", .maximumCount(8))
    var relations: [ASGenRelation]

    @Guide(description: "地點類型，繁體中文；不確定就留空")
    var location: String

    @Guide(description: "室內或戶外", .anyOf(["indoor", "outdoor", "unknown"]))
    var setting: String

    @Guide(description: "時間", .anyOf(["早上", "白天", "下午", "黃昏", "晚上", "夜晚", "不明"]))
    var timeOfDay: String

    @Guide(description: "畫面在進行的活動或場合，沒有就留空")
    var event: String

    @Guide(description: "1～2 句繁體中文，描述整張照片的情境")
    var explanation: String

    @Guide(description: "one English sentence describing the image")
    var captionEn: String

    @Guide(description: "畫面給人的氛圍或情緒，繁體中文", .maximumCount(4))
    var moods: [String]

    @Guide(description: "只有截圖或文件才填：這是什麼畫面；照片留空")
    var appContext: String

    @Guide(description: "只有截圖或文件才填：可見文字的大意，不抄錄隱私內容；照片留空")
    var visibleTextSummary: String
}

@available(iOS 27, *)
extension ASSceneGraph {
    init(generated g: ASGenGraph) {
        self.init()
        contentType = g.contentType
        entities = g.entities.map {
            ASEntity(id: $0.id, name: $0.name, category: $0.category, concept: $0.concept,
                     count: $0.count, attributes: $0.attributes)
        }
        relations = g.relations.map {
            ASRelation(subject: $0.subject, predicate: $0.predicate, object: $0.object,
                       relationType: $0.relationType, confidence: $0.confidence)
        }
        scene = ASScene(location: g.location,
                        setting: g.setting == "unknown" ? "" : g.setting,
                        timeOfDay: g.timeOfDay == "不明" ? "" : g.timeOfDay)
        event = g.event
        explanation = g.explanation
        captionEn = g.captionEn
        emotion = ASEmotion(tags: g.moods)
        appContext = g.appContext
        visibleTextSummary = g.visibleTextSummary
    }
}

// MARK: - 查詢解析的輸出格式

@available(iOS 27, *)
@Generable(description: "查詢中提到的一個實體")
struct ASGenQueryEntity {
    @Guide(description: "保留使用者的原始用詞")
    var text: String

    @Guide(description: "通用英文名詞")
    var concept: String

    @Guide(description: "類別", .anyOf(ASVocabulary.categories))
    var category: String

    @Guide(description: "有明確數量才填（兩個人填 2）；一群、很多填 6；沒提到填 0", .range(0...99))
    var count: Int

    @Guide(description: "描述這個實體的形容詞，例如顏色、外觀", .maximumCount(4))
    var attributes: [String]
}

@available(iOS 27, *)
@Generable(description: "查詢中的關係")
struct ASGenQueryRelation {
    @Guide(description: "entities 裡的 text")
    var subject: String

    @Guide(description: "動詞或空間詞")
    var predicate: String

    @Guide(description: "entities 裡的 text；不及物動作（例如走路、睡覺）留空")
    var object: String

    @Guide(description: "關係類型", .anyOf(ASVocabulary.relationTypes))
    var relationType: String
}

@available(iOS 27, *)
@Generable(description: "結構化的相簿搜尋查詢")
struct ASGenQuery {
    @Guide(description: "查詢中的實體，最多 4 個", .maximumCount(4))
    var entities: [ASGenQueryEntity]

    @Guide(description: "查詢中的關係，最多 3 條", .maximumCount(3))
    var relations: [ASGenQueryRelation]

    @Guide(description: "地點，沒提到就留空")
    var location: String

    @Guide(description: "室內或戶外", .anyOf(["indoor", "outdoor", "none"]))
    var setting: String

    @Guide(description: "時間，沒提到就留空")
    var timeOfDay: String

    @Guide(description: "活動或場合，例如生日、聚餐、畢業；沒有就留空")
    var event: String

    @Guide(description: "氛圍或情緒詞，例如溫馨、熱鬧、孤單", .maximumCount(3))
    var moods: [String]

    @Guide(description: "使用者明確在找截圖或文件時才填", .anyOf(["none", "screenshot", "document"]))
    var contentType: String

    @Guide(description: "整句查詢的英文翻譯")
    var queryEn: String
}

@available(iOS 27, *)
extension ASParsedQuery {
    init(generated q: ASGenQuery) {
        self.init()
        entities = q.entities
            .filter { !$0.text.isEmpty }
            .map { ASParsedEntity(text: $0.text, concept: $0.concept, category: $0.category,
                                  count: $0.count, attributes: $0.attributes) }
        relations = q.relations.map {
            ASParsedRelation(subject: $0.subject, predicate: $0.predicate, object: $0.object,
                             relationType: $0.relationType)
        }
        scene = ASScene(location: q.location,
                        setting: q.setting == "none" ? "" : q.setting,
                        timeOfDay: q.timeOfDay)
        event = q.event
        mood = q.moods
        contentType = q.contentType == "none" ? "" : q.contentType
        queryEn = q.queryEn
    }
}

// MARK: - 提示詞（對應 PC 版 prompts_v10.py，只保留原則，格式交給 @Generable）

enum ASPrompts {
    static let build = """
    你是相片內容標註員，依照輸出格式描述使用者提供的照片。
    原則：
    - 保留明顯的主體、背景主體與關鍵物件；資訊不足時寧可少抽，不要猜
    - 同一個物理個體只建一個主體；同一人的手、臉、衣物、手持物，歸在那個人的屬性或關係
    - 同類且無法個別區分的多個個體可合併成一個主體，數量寫在 count；人物數量要準確
    - 關係的 subject、object 填主體的 id，兩者不可相同；空間關係依實際位置判斷，不要把畫面重疊當成相鄰
    - 空間關係優先使用：在...上方、在...下方、包含於內部、緊鄰、位於前方（較靠近鏡頭）、位於後方（較遠）
    - 專有名詞（地標、品牌、作品、角色）只在有把握時使用正式名稱，否則用通用描述
    - concept 與 captionEn 用英文，其餘文字一律用繁體中文
    """

    static let query = """
    把使用者的相簿搜尋文字解析成結構化查詢。
    原則：
    - 修飾語放進該實體的 attributes，不要拆成獨立實體
    - 同類的多個個體（例如「兩個人在聊天」）只建一個實體，關係的 subject 和 object 都指向它
    - 地點、時間放在對應欄位，不要放進 entities；活動或場合放在 event
    - 情緒與氛圍詞一定要保留在 moods
    """
}

// MARK: - 模型可用性

@available(iOS 27, *)
public enum ASModelAvailability {
    /// 裝置與設定是否可以使用 Apple Intelligence 的裝置端模型
    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// 不能用時的原因（例如裝置不支援、使用者沒開啟 Apple Intelligence、模型還在下載）
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return String(describing: reason)
        @unknown default:
            return "unknown"
        }
    }
}

// MARK: - 建圖

@available(iOS 27, *)
public struct ASGraphBuilder: Sendable {
    public init() {}

    /// 讓模型看一張照片並輸出場景圖。每張照片用新的 session，避免前一張照片佔用 context。
    public func buildGraph(from image: CGImage) async throws -> ASSceneGraph {
        let session = LanguageModelSession(instructions: ASPrompts.build)
        let response = try await session.respond(
            generating: ASGenGraph.self,
            options: GenerationOptions(temperature: 0.2)
        ) {
            "請描述這張照片。"
            Attachment(image)
        }
        return ASSceneGraph(generated: response.content).normalized()
    }
}

// MARK: - 查詢解析

@available(iOS 27, *)
public struct ASQueryParser: Sendable {
    public init() {}

    public func parse(_ text: String) async throws -> ASParsedQuery {
        let session = LanguageModelSession(instructions: ASPrompts.query)
        let response = try await session.respond(
            to: "搜尋文字：「\(text)」",
            generating: ASGenQuery.self,
            options: GenerationOptions(temperature: 0)
        )
        return ASParsedQuery(generated: response.content)
    }
}

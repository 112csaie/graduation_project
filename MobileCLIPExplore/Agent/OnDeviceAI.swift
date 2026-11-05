// OnDeviceAI.swift
//
// 手機上的 AI（Apple Intelligence 的裝置端模型，和智慧搜尋同一個模型）。
// 在支援的手機上，下面這些工作改在手機上做，照片和文字都不會離開手機：
// - 想去清單：從截圖文字整理出店名、地址、地區
// - 購物清單：從截圖文字整理出商品、品牌、價格、在哪裡買
// - 沒有文字的照片：讓模型直接看圖描述（不上傳照片）
// - 回憶筆記：日期、地點、tag、場景描述本來就在手機上，直接寫成筆記（OnDeviceMemoryWriter）
// 不支援的手機（或沒開 Apple Intelligence）才照舊交給電腦上的後端。
// 手機上的模型能讀的字數有限，材料太長時只取前面一段。

import Foundation
import FoundationModels
import UIKit

enum OnDeviceAIError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "這支手機不能使用手機上的 AI。"
        case .failed(let detail): return "手機上的 AI 這次沒有整理出來，請再試一次或手動加入。（\(detail)）"
        }
    }
}

enum OnDeviceAI {
    /// 這支手機現在能不能用手機上的 AI（裝置支援、Apple Intelligence 已開啟、模型已下載）
    static var isAvailable: Bool {
        if #available(iOS 27, *) { return ASModelAvailability.isAvailable }
        return false
    }

    /// 給隱私頁顯示：為什麼不能用
    static var statusText: String {
        if isAvailable { return "這支手機支援手機上的 AI：清單整理、看圖描述、回憶筆記都在手機上完成。" }
        if #available(iOS 27, *) {
            return "手機上的 AI 目前不能用（可能沒開 Apple Intelligence，或模型還在下載），這些工作會先交給開發者的後端。"
        }
        return "這支手機的 iOS 版本不支援手機上的 AI，這些工作會交給開發者的後端。"
    }

    private static let maxInputCharacters = 2400

    private static func clip(_ text: String, _ limit: Int = maxInputCharacters) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    // MARK: 想去清單

    static func extractPlaces(text: String, imageDescription: String?) async throws -> [ExtractedPlace] {
        guard #available(iOS 27, *), isAvailable else { throw OnDeviceAIError.unavailable }
        let prompt = "截圖中的文字：\n\(clip(text).isEmpty ? "（沒有）" : clip(text))\n\n圖片描述：\n\(clip(imageDescription ?? "", 800).isEmpty ? "（沒有）" : clip(imageDescription ?? "", 800))"
        do {
            let session = LanguageModelSession(instructions: ODPrompts.places)
            let response = try await session.respond(to: prompt, generating: ODPlaces.self,
                                                     options: GenerationOptions(temperature: 0))
            var seen = Set<String>()
            return response.content.places.compactMap { place in
                let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = name.replacingOccurrences(of: " ", with: "").lowercased()
                guard !name.isEmpty, seen.insert(key).inserted else { return nil }
                return ExtractedPlace(name: name, address: place.address, area: place.area,
                                      category: place.category, note: place.note)
            }
        } catch {
            throw OnDeviceAIError.failed(error.localizedDescription)
        }
    }

    // MARK: 購物清單

    static func extractProducts(text: String, imageDescription: String?) async throws -> [ExtractedProduct] {
        guard #available(iOS 27, *), isAvailable else { throw OnDeviceAIError.unavailable }
        let prompt = "截圖中的文字：\n\(clip(text).isEmpty ? "（沒有）" : clip(text))\n\n圖片描述：\n\(clip(imageDescription ?? "", 800).isEmpty ? "（沒有）" : clip(imageDescription ?? "", 800))"
        do {
            let session = LanguageModelSession(instructions: ODPrompts.products)
            let response = try await session.respond(to: prompt, generating: ODProducts.self,
                                                     options: GenerationOptions(temperature: 0))
            let source = text + "\n" + (imageDescription ?? "")
            var seen = Set<String>()
            return response.content.items.compactMap { item in
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = name.replacingOccurrences(of: " ", with: "").lowercased()
                let brand = ProductCheck.keepIfInSource(item.brand, source: source)
                guard ProductCheck.isProductName(name, brand: brand), seen.insert(key).inserted else { return nil }
                let code = item.countryCode.trimmingCharacters(in: .whitespaces).uppercased()
                return ExtractedProduct(name: name, brand: brand,
                                        price: ProductCheck.price(item.price, source: source),
                                        store: ProductCheck.store(item.store, source: source),
                                        country_code: code.count == 2 ? code : "", note: item.note)
            }
        } catch {
            throw OnDeviceAIError.failed(error.localizedDescription)
        }
    }

    // MARK: 搜尋查詢翻成英文

    /// 照片向量模型只看得懂英文：把中文（日文、韓文）的搜尋句子翻成簡短的英文畫面描述，例如「海邊的夕陽」→ a sunset at the beach。
    /// 只傳搜尋文字，不傳照片。
    static func translateSearchQuery(_ text: String) async throws -> String {
        guard #available(iOS 27, *), isAvailable else { throw OnDeviceAIError.unavailable }
        do {
            let session = LanguageModelSession(instructions: ODPrompts.searchTranslation)
            let response = try await session.respond(to: clip(text, 200), options: GenerationOptions(temperature: 0))
            let line = response.content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”「」。.")).trimmingCharacters(in: .whitespaces)
            return String(cleaned.prefix(200))
        } catch {
            throw OnDeviceAIError.failed(error.localizedDescription)
        }
    }

    // MARK: 看圖描述（沒有文字的照片）

    /// 讓手機上的模型看這張照片，用繁體中文回答 request（例如「列出圖中的店家名稱」）。照片不會上傳。
    static func describe(image: UIImage, request: String) async throws -> String {
        guard #available(iOS 27, *), isAvailable else { throw OnDeviceAIError.unavailable }
        guard let cgImage = image.cgImage else { throw OnDeviceAIError.failed("讀不到照片") }
        do {
            let session = LanguageModelSession(instructions: ODPrompts.describe)
            let response = try await session.respond(options: GenerationOptions(temperature: 0.2)) {
                request
                Attachment(cgImage)
            }
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw OnDeviceAIError.failed(error.localizedDescription)
        }
    }
}

// MARK: - 輸出格式

@available(iOS 27, *)
@Generable(description: "截圖中一個想去的地點")
struct ODPlace {
    @Guide(description: "店名或景點名稱，照截圖原文（保留原本的語言）")
    var name: String
    @Guide(description: "地址；截圖沒寫就留空")
    var address: String
    @Guide(description: "城市或區域，例如 台北市大安區、東京；截圖沒寫就留空")
    var area: String
    @Guide(description: "類別", .anyOf(["餐廳", "咖啡廳", "甜點", "飲料", "酒吧", "景點", "展覽", "商店", "住宿", "其他"]))
    var category: String
    @Guide(description: "很短的繁體中文理由（推薦餐點、營業時間、展期）；沒有就留空")
    var note: String
}

@available(iOS 27, *)
@Generable(description: "截圖中想去的地點")
struct ODPlaces {
    @Guide(description: "最多 8 個；沒有明確的地點就留空", .maximumCount(8))
    var places: [ODPlace]
}

@available(iOS 27, *)
@Generable(description: "截圖中一個想買的商品")
struct ODProduct {
    @Guide(description: "商品名稱，照截圖原文（保留原本的語言）")
    var name: String
    @Guide(description: "品牌；沒寫就留空")
    var brand: String
    @Guide(description: "價格，含幣別，照原文；沒寫就留空")
    var price: String
    @Guide(description: "在哪裡買（例如唐吉訶德、松本清）；文字沒寫就留空，不要猜")
    var store: String
    @Guide(description: "要在哪個國家買的兩碼國家代碼（JP、KR、TH…）；看不出來就留空")
    var countryCode: String
    @Guide(description: "很短的繁體中文細節（容量、顏色、限定版）；沒有就留空")
    var note: String
}

@available(iOS 27, *)
@Generable(description: "截圖中想買的商品")
struct ODProducts {
    @Guide(description: "最多 8 個；沒有明確的商品就留空", .maximumCount(8))
    var items: [ODProduct]
}

// MARK: - 提示詞（和後端的規則相同）

enum ODPrompts {
    static let searchTranslation = """
    你把使用者找照片時輸入的句子翻成英文，給看圖片的模型使用。
    規則：
    - 只輸出一行簡短的英文，描述照片畫面裡看得到的東西；不要解釋、不要加引號。
    - 專有名詞（店名、人名、作品名）照原文的英文或羅馬拼音寫，不知道就省略。
    例：
    海邊的夕陽 → a sunset at the beach
    我家的貓在睡覺 → a cat sleeping
    一碗拉麵 → a bowl of ramen
    在咖啡廳拍的拿鐵拉花 → latte art on a coffee in a cafe
    """
    static let places = """
    你從截圖（IG 貼文、地圖、部落格、LINE 訊息）中找出使用者可能想去的地點。手機會提供截圖裡辨識到的文字，有時附上圖片描述。
    規則：
    - 只列出文字中明確出現名稱的店家、餐廳、咖啡廳、景點、展覽或場地。
    - 地圖截圖（Google 地圖、Apple 地圖）：只列出被選取的那一家（搜尋框或地點卡上的名稱，旁邊有評分、營業時間、路線／開始／致電按鈕），地圖上其他店名標籤不算。
    - 帳號名稱、hashtag、價格、菜名都不是地點。
    - 同一個招牌上的品牌名稱和分店名稱（例如「炸雞大獅」和「桃園輯安店」）是同一家店，合併成一筆，名稱寫成「品牌 分店」；電話、開幕日期寫在備註。
    - 不要編造地址或地點。
    """

    static let products = """
    你從截圖（購物貼文、商品頁、藥妝清單、IG 或小紅書貼文）中找出使用者想買的商品。手機會提供截圖裡辨識到的文字，有時附上圖片描述。
    規則：
    - 只列出文字或圖片描述中明確出現的商品，每個商品一筆。
    - 影片或貼文截圖常常沒寫商品全名：品牌和商品類型清楚時（例如 无印良品 + 護髮油），加一筆「品牌 商品類型」（繁體中文），備註寫「名稱待確認」。
    - 帳號名稱、hashtag、店名都不是商品。
    - 不要編造商品、價格或店家。
    - 帳號名稱（貼文作者，常在愛心數、留言數旁邊）、按讚數、收藏數、TESTER 這類標籤都不是商品或價格。
    - 價格只填文字裡和幣別寫在一起的數字（例如 $699、¥1,034）；沒有就留空，不要自己加幣別。
    - 國家代碼：文字提到國家或城市（韓國、首爾 → KR；日本、東京 → JP；泰國、曼谷 → TH）時填入；看不出來就留空。
    """

    static let describe = """
    你看著使用者提供的照片，用繁體中文簡短回答。只寫看得到的內容，看不清楚的不要猜；店名、品牌、看板文字照原文寫出來。
    """

    static func memoryDay(kind: String) -> String {
        """
        你幫使用者寫個人回憶筆記裡的「一天」，使用繁體中文。資料是手機整理的地區、去過的地方、tag、照片場景和照片文字，沒有照片本身。
        規則：
        - 寫成使用者做了什麼（例如「下午去 Dhyana Spa 按摩，晚上吃火鍋」），依時間排，不要寫成「有…照片」。
        - 「去過的地方」和「已確認的 tag」可信；「畫面像」可能不準，只在和其他資料吻合時才用，並用「看起來」。
        - 只用資料裡的事實，不要編造店名、人物、價格、心情或天氣。
        - 不要寫日期、照片張數或統計數字。
        \(kind == "monthly" || kind == "report" ? "- 這是一個月的興趣紀錄；不要評論身材、體重或外表。" : "")
        """
    }

    static let memorySummary = """
    你幫使用者寫回憶筆記開頭的一句摘要，使用繁體中文。資料是每天已經整理好的行程。
    規則：一句話，30～70 字；說出什麼時候、在哪裡、印象深刻的 2～3 件事；只用資料裡的事實，不要寫照片張數或「進行住宿、餐飲活動」這種空泛的說法。
    """

    static func kindName(_ kind: String) -> String {
        switch kind {
        case "trip": return "旅行"
        case "concert": return "演唱會或演出"
        case "event": return "活動"
        case "report", "monthly": return "一個月的興趣紀錄（月報）"
        default: return "相簿"
        }
    }
}

// MARK: - 交給誰做

/// 清單整理、看圖描述：支援的手機預設在手機上做（照片和文字不離開手機）；
/// 使用者在設定改選「開發者的後端」、按了「用後端再整理一次」、或手機不支援時才交給後端。
/// 回憶筆記的分流在 PhotoMemoryService（手機上用 OnDeviceMemoryWriter）。
/// 手機上做失敗時不會偷偷改送後端，直接告訴使用者（隱私承諾）。
enum AIRouter {
    /// 使用者在設定選的處理方式
    enum Preference: String, CaseIterable, Identifiable {
        case device, backend
        static let storageKey = "aiProcessingPreference"
        var id: String { rawValue }
        var title: String { self == .device ? "在手機上（最隱私）" : "開發者的後端（較準確）" }
    }

    static var preference: Preference {
        Preference(rawValue: UserDefaults.standard.string(forKey: Preference.storageKey) ?? "") ?? .device
    }

    /// 「用後端再整理一次」：只在這一次動作裡改用後端（使用者按了按鈕才會）
    @TaskLocal static var forceBackend = false

    /// 這次要不要在手機上做：手機支援、使用者選「在手機上」、而且不是按了「用後端再整理一次」
    static var onDevice: Bool { OnDeviceAI.isAvailable && preference == .device && !forceBackend }

    // 輸出一律轉成繁體中文（截圖常是簡體，模型會照抄）

    static func analyzeImage(image: UIImage, prompt: String) async throws -> String {
        let text = onDevice ? try await OnDeviceAI.describe(image: image, request: prompt)
                            : try await APIService.shared.analyzeImage(image: image, prompt: prompt)
        return TraditionalChinese.convert(text)
    }

    static func extractPlaces(text: String, imageAnalysis: String?) async throws -> [ExtractedPlace] {
        let places = onDevice ? try await OnDeviceAI.extractPlaces(text: text, imageDescription: imageAnalysis)
                              : try await APIService.shared.extractPlaces(text: text, imageAnalysis: imageAnalysis)
        let t = TraditionalChinese.convert
        return places.map { ExtractedPlace(name: t($0.name), address: t($0.address), area: t($0.area),
                                           category: t($0.category), note: t($0.note)) }
    }

    static func extractProducts(text: String, imageAnalysis: String?) async throws -> [ExtractedProduct] {
        let items = onDevice ? try await OnDeviceAI.extractProducts(text: text, imageDescription: imageAnalysis)
                             : try await APIService.shared.extractProducts(text: text, imageAnalysis: imageAnalysis)
        let t = TraditionalChinese.convert
        return items.map { ExtractedProduct(name: t($0.name), brand: t($0.brand), price: $0.price, store: t($0.store),
                                            country_code: $0.country_code, note: t($0.note)) }
    }
}


// MARK: - 回憶筆記（手機上）

/// 在手機上把一本相簿寫成回憶筆記。
/// 手機上的模型一次能讀的字數有限（整本旅行一次送進去會超過），所以：
/// - 每天分開請模型寫一行行程（每次都是新的對話，不會越寫越長）
/// - 標題、亮點、筆記結構由程式決定；模型只寫句子，提到的店名、食物要真的出現在資料裡才採用
/// - 模型失敗或那天資料太少時，用資料直接組成一行，不會因為資料少就不寫
enum OnDeviceMemoryWriter {
    /// 最多幾天交給模型寫（再多的天數直接用資料組成）
    static let maxModelDays = 14

    struct DayResult {
        let line: String
        let highlights: [String]
        let foods: [String]
    }

    static func write(title: String, kind: String, context: PhotoContext, userNote: String?,
                      existingTopics: [String]) async -> MemoryDraftResponse {
        let country = context.countryCodes.first
        let note = userNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var dayLines: [String] = []
        var highlights: [String] = []
        var foods: [(day: String, items: [String])] = []

        for (index, day) in context.days.enumerated() {
            let visits = unique(day.visits.filter { readable($0, country: country) })
            var written: DayResult?
            if index < maxModelDays, day.hasContent || !visits.isEmpty, #available(iOS 27, *) {
                written = await writeDay(day, visits: visits, kind: kind, userNote: note)
            }
            let line = written?.line ?? fallbackLine(day, visits: visits)
            guard !line.isEmpty else { continue }
            dayLines.append("- \(day.label)：\(line)")
            highlights += visits + (written?.highlights ?? [])
            if let items = written?.foods, !items.isEmpty { foods.append((day.label, items)) }
        }

        guard !dayLines.isEmpty else {
            return MemoryDraftResponse(reply: "讀不到這本相簿的照片資料，沒有寫成筆記。", wiki_decision: "skip",
                                       topic: nil, summary: nil, new_content: nil, reason: "讀不到照片的日期")
        }

        let topic = makeTitle(title: title, kind: kind, context: context)
        let summary = await writeSummary(kind: kind, context: context, dayLines: dayLines)
            ?? fallbackSummary(kind: kind, context: context)

        var content: [String] = []
        content.append(kind == "trip" ? "## 行程" : "## 紀錄")
        content += dayLines
        let picks = Array(unique(highlights).prefix(8))
        if !picks.isEmpty {
            content.append("")
            content.append("## 亮點")
            content += picks.map { "- " + $0 }
        }
        if !foods.isEmpty {
            content.append("")
            content.append("## 吃了什麼")
            content += foods.map { "- \($0.day)：" + $0.items.joined(separator: "、") }
        }
        if !note.isEmpty {
            content.append("")
            content.append("## 備註")
            content.append("- " + note)
        }

        let isUpdate = existingTopics.contains(topic)
        return MemoryDraftResponse(reply: "已在手機上整理成《\(topic)》", wiki_decision: isUpdate ? "update" : "store",
                                   topic: topic, summary: summary, new_content: content.joined(separator: "\n"), reason: nil)
    }

    // MARK: 一天一行

    @available(iOS 27, *)
    private static func writeDay(_ day: MemoryDayFacts, visits: [String], kind: String, userNote: String) async -> DayResult? {
        var facts: [String] = ["日期：\(day.label)"]
        if !day.regions.isEmpty { facts.append("地區：" + day.regions.prefix(3).joined(separator: "、")) }
        if !visits.isEmpty { facts.append("去過的地方（Apple 地圖依照片位置查到）：" + visits.prefix(5).joined(separator: "、")) }
        if !day.tags.isEmpty { facts.append("已確認的 tag：" + day.tags.prefix(6).joined(separator: "、")) }
        if !day.guesses.isEmpty { facts.append("畫面像（可能不準）：" + day.guesses.prefix(4).joined(separator: "、")) }
        let scenes = unique(day.scenes.map { String($0.prefix(70)) }).prefix(4)
        if !scenes.isEmpty { facts.append("照片場景：\n" + scenes.map { "- " + $0 }.joined(separator: "\n")) }
        if !day.texts.isEmpty { facts.append("照片上的文字：" + day.texts.prefix(2).map { String($0.prefix(40)) }.joined(separator: "／")) }
        if !userNote.isEmpty { facts.append("使用者補充：" + String(userNote.prefix(80))) }
        let input = facts.joined(separator: "\n")

        do {
            let session = LanguageModelSession(instructions: ODPrompts.memoryDay(kind: kind))
            let response = try await session.respond(to: input, generating: ODDayLine.self,
                                                     options: GenerationOptions(temperature: 0.3))
            let key = normalized(input)
            let line = cleanLine(response.content.line, label: day.label)
            guard line.count >= 4 else { return nil }
            // 店名、食物要真的出現在資料裡才採用（模型有時會自己補名字）
            let picks = response.content.highlights
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 && key.contains(normalized($0)) }
            let foods = response.content.foods
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 1 && key.contains(normalized($0)) }
            return DayResult(line: line, highlights: unique(picks), foods: unique(foods))
        } catch {
            return nil     // 超過長度、模型忙碌…：改用資料直接組成
        }
    }

    /// 模型失敗時：地區＋去過的地方＋tag
    private static func fallbackLine(_ day: MemoryDayFacts, visits: [String]) -> String {
        var parts: [String] = []
        if !day.regions.isEmpty { parts.append("在" + day.regions.prefix(2).joined(separator: "、")) }
        let things = unique(Array(visits.prefix(3)) + Array(day.tags.prefix(3)))
        if !things.isEmpty { parts.append(things.joined(separator: "、")) }
        return parts.isEmpty ? "" : parts.joined(separator: "，") + "。"
    }

    // MARK: 摘要

    private static func writeSummary(kind: String, context: PhotoContext, dayLines: [String]) async -> String? {
        guard #available(iOS 27, *) else { return nil }
        let input = """
        類型：\(ODPrompts.kindName(kind))
        日期：\(context.dateRange ?? "未知")
        地點：\(context.places.prefix(4).joined(separator: "、"))
        每天：
        \(String(dayLines.joined(separator: "\n").prefix(1400)))
        """
        do {
            let session = LanguageModelSession(instructions: ODPrompts.memorySummary)
            let response = try await session.respond(to: input, generating: ODSummary.self,
                                                     options: GenerationOptions(temperature: 0.4))
            let text = response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count >= 8 ? String(text.prefix(90)) : nil
        } catch {
            return nil
        }
    }

    private static func fallbackSummary(kind: String, context: PhotoContext) -> String {
        let places = context.places.prefix(3).joined(separator: "、")
        let when = context.dateRange ?? ""
        switch kind {
        case "trip": return "\(when)\(places.isEmpty ? "" : "，在\(places)")的旅行。"
        case "monthly", "report": return "\(when)的紀錄。"
        default: return "\(when)\(places.isEmpty ? "" : "，在\(places)")。"
        }
    }

    // MARK: 標題

    /// 旅行：「曼谷・春武里 10 天」「台南一日遊」；其他：用相簿標題（去掉「，」後面的日期說明）
    static func makeTitle(title: String, kind: String, context: PhotoContext) -> String {
        let base = title.components(separatedBy: CharacterSet(charactersIn: "，,")).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch kind {
        case "trip":
            let places = context.places.prefix(2).joined(separator: "・")
            let name = places.isEmpty ? (base.isEmpty ? "旅行" : base) : places
            let days = max(context.spanDays, 1)
            return days == 1 ? "\(name)一日遊" : "\(name) \(days) 天"
        case "monthly", "report":
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return base.isEmpty ? (context.dateRange ?? "回憶") : base
        }
    }

    // MARK: 工具

    /// Apple 地圖有時回傳當地文字（泰文）或別國文字（泰國的店回傳日文）：看不懂的名稱不用
    static func readable(_ name: String, country: String?) -> Bool {
        var thai = 0, kana = 0, hangul = 0, letters = 0
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0x0E00...0x0E7F: thai += 1
            case 0x3041...0x309F, 0x30A0...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            default: if CharacterSet.letters.contains(scalar) { letters += 1 }
            }
        }
        if thai > 0 { return false }
        if kana > 0 && country != "JP" { return false }
        if hangul > 0 && country != "KR" { return false }
        return letters + kana + hangul >= 2
    }

    private static func cleanLine(_ text: String, label: String) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        // 模型有時自己加上日期開頭
        if line.hasPrefix(label) { line = String(line.dropFirst(label.count)) }
        while let first = line.first, "：:-–— ".contains(first) { line.removeFirst() }
        if !line.isEmpty, !"。！!？?".contains(line.last!) { line += "。" }
        return line
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "臺", with: "台").filter { !$0.isWhitespace }
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
    }
}

@available(iOS 27, *)
@Generable(description: "回憶筆記裡的一天")
struct ODDayLine {
    @Guide(description: "一句繁體中文，20～60 字，依時間寫使用者這天做了什麼，例如「上午在海灘玩水，下午去 Dhyana Spa 按摩，晚上吃海鮮自助餐」")
    var line: String
    @Guide(description: "這天有名字的店、景點或活動，照資料原文；沒有就留空", .maximumCount(3))
    var highlights: [String]
    @Guide(description: "這天吃了什麼（例如 火鍋、拉麵），只能用資料裡出現的詞；沒有就留空", .maximumCount(3))
    var foods: [String]
}

@available(iOS 27, *)
@Generable(description: "回憶筆記的摘要")
struct ODSummary {
    @Guide(description: "一句繁體中文，30～70 字：什麼時候、在哪裡、做了哪些印象深刻的事")
    var summary: String
}


// MARK: - 檢查手機上模型整理出的商品

/// 手機上的模型比較小，有時會把帳號名稱當商品、把按讚數當價格、自己補幣別或店名。
/// 這裡只保留真的出現在截圖文字（或看圖描述）裡的資料。
enum ProductCheck {
    /// 不是商品的字（影片標籤、試用品標示）
    static let notProducts: Set<String> = ["tester", "sample", "new", "sale", "hot", "pr", "ad", "廣告", "新品", "試用", "試用品", "限定",
                                           // 商品分類、App 分頁標籤（「香氛｜洗護｜日用品」）
                                           "洗護", "洗护", "日用品", "香氛", "美妝", "美妆", "彩妝", "彩妆", "保養", "保养", "護膚", "护肤",
                                           "零食", "食品", "藥妝", "药妆", "生活用品", "居家", "推薦", "推荐", "好物", "必買", "必买"]

    static func isProductName(_ name: String, brand: String) -> Bool {
        let key = normalized(name)
        guard key.count >= 2, !notProducts.contains(key) else { return false }
        // 名稱只有品牌（或帳號名稱）、沒有商品內容
        if !brand.isEmpty && key == normalized(brand) { return false }
        return true
    }

    static func keepIfInSource(_ value: String, source: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, normalized(source).contains(normalized(trimmed)) else { return "" }
        return trimmed
    }

    /// 店名：要出現在文字裡，也不能只是國家代碼或國名
    static func store(_ value: String, source: String) -> String {
        let kept = keepIfInSource(value, source: source)
        guard kept.count >= 2, ShoppingCountry.code(forName: kept) == nil else { return "" }
        return kept
    }

    /// 價格：數字要出現在文字裡，而且旁邊（前後 3 個字內）真的有幣別；否則多半是按讚數、收藏數
    static func price(_ value: String, source: String) -> String {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        let markers: [Character] = ["$", "¥", "￥", "円", "元", "₩", "원", "฿", "€", "£"]
        // 同一行裡的空白、千分位逗號拿掉；換行保留成分隔（不同行的數字不會黏在一起）
        let compact = Array(source.map { $0.isNewline ? "|" : $0 }.filter { $0 != " " && $0 != "\t" && $0 != "," })
        let target = Array(digits)
        guard target.count <= compact.count else { return "" }
        for start in 0...(compact.count - target.count) where Array(compact[start..<start + target.count]) == target {
            // 數字前後不能再接數字（避免 2686 對到 12686）
            if start > 0, compact[start - 1].isNumber { continue }
            let end = start + target.count
            if end < compact.count, compact[end].isNumber { continue }
            let window = compact[max(0, start - 3)..<min(compact.count, end + 3)]
            if window.contains(where: { markers.contains($0) }) || String(window).uppercased().contains("NT") {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}


// MARK: - 繁體中文

/// 把簡體字轉成繁體（Apple 內建的 ICU 轉換，在手機上完成）。
/// 只轉簡體專用字：「台」「里」「后」「面」這類繁體也常用的字保留原樣，避免「台北」變「臺北」。
enum TraditionalChinese {
    /// 繁體中文也常用、不要轉的字
    private static let keep: Set<Character> = ["台", "里", "后", "干", "面", "系", "只", "余", "着", "了", "于", "云", "丑", "斗",
                                               "谷", "制", "范", "松", "冲", "表", "游", "征", "历", "向", "尽", "准", "卷", "党",
                                               "吁", "郁", "凶", "采", "咸", "布", "合", "克", "弦", "念", "挂", "板", "朴", "杰",
                                               "占", "才", "家", "出", "回", "姜", "术", "胡", "须", "千", "症", "仆", "注", "据"]

    static func convert(_ text: String) -> String {
        guard !text.isEmpty,
              let converted = text.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false),
              converted != text else { return text }
        let original = Array(text)
        let result = Array(converted)
        // 一字對一字時，保留繁體也常用的字；長度不同（少見）就直接用轉換結果
        guard original.count == result.count else { return converted }
        return String(zip(original, result).map { keep.contains($0.0) ? $0.0 : $0.1 })
    }
}

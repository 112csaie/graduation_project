// PhotoTextStore.swift
//
// 照片中的文字（OCR，migration v7 的 PhotoText 表）。
// 文字由 App 在手機上用 Apple Vision 辨識後傳入：使用者在照片頁按「辨識照片中的文字」時，
// 以及「看起來像紙張或卡片」的照片（票根、收據、證件、菜單、文件）會自動辨識，其他照片不掃描；
// 這裡只負責儲存、查詢與「文字 → 分類線索」。照片還沒被掃描（沒有 PhotoFeatures）也可以存文字。
// 只存 App 自己的分析結果，不會修改或刪除照片。使用者「移除 AI 分析資料」時一併刪除。
//
// 本檔案只依賴 Foundation 與 SQLite.swift，可在 macOS 用 swift test 驗證。

import Foundation
import SQLite

// MARK: - 文字正規化與分類線索

enum PhotoTextHints {

    /// 辨識結果的版本：辨識設定改變時遞增，App 會重新辨識
    static let ocrVersion = "vision-1"

    /// 搜尋用的正規化：全形轉半形、轉小寫、去掉空白（中文辨識結果常在字與字之間多出空白）
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        return String(folded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(Character.init))
    }

    /// 文字裡常見、可以直接說明照片內容的詞（分類名稱本身也會自動比對，見 terms(for:)）
    static let extraKeywords: [String: [String]] = [
        // v25：音樂祭、Live House 併入演唱會
        "concert": ["演唱會", "concert", "worldtour", "巡迴演唱", "巡演", "音樂祭", "musicfestival", "livehouse"],
        "receipt": ["發票", "收據", "統一編號", "統編", "receipt", "invoice", "電子發票"],
        "chat_screenshot": ["已讀"],
        "exhibition": ["特展", "展覽", "exhibition"],
        "museum": ["博物館", "美術館", "museum"],
        // v21：電影院＋票根合併成「電影」（名稱「電影」太常出現在海報、文章裡，不拿來比對，見 nameStoplist）
        "movie": ["影城", "cinema", "威秀", "秀泰", "國賓影城", "電影票", "放映日期", "放映時間"],
        "menu": ["菜單", "menu"],
        "fansign": ["簽售", "簽名會", "見面會", "fansign"],
        "comic_convention": ["開拓動漫祭", "同人誌", "漫展", "comicmarket"],
        "merch": ["小卡", "壓克力立牌", "吧唧", "徽章", "專輯"],
        "theme_park": ["樂園", "disneyland", "環球影城", "universalstudios"],
        "airport": ["航廈"],
        "boarding_pass": ["登機證", "boardingpass", "電子機票", "eticket", "登机牌"],
        "transport_vehicle": ["高鐵", "台鐵", "車票"],
        "bubble_tea": ["珍珠奶茶", "手搖"],
        "noodle_dish": ["拉麵", "ramen", "牛肉麵", "烏龍麵", "義大利麵"],
        "sports_game": ["職棒", "中職", "baseball"],
        "body_composition": ["inbody", "體組成", "體脂肪", "骨骼肌", "體脂率"],
        "textbook": ["vocabulary", "lesson", "課本", "講義", "習題", "單字"],
        "christmas": ["merrychristmas", "聖誕"],
        // v22：生日派對、KTV 合併成「派對聚會」；移除婚禮
        "party": ["生日快樂", "happybirthday", "錢櫃", "好樂迪", "ktv"],
    ]

    /// 名稱太籠統、出現在文字裡也不代表照片內容的分類
    static let nameStoplist: Set<String> = [
        "daily", "home_daily", "document", "documents", "product_photo", "products", "screenshot", "screens",
        "portrait", "portraits", "restaurant_meal", "outfit", "outfits", "instrument",
        "workspace", "home", "sights", "outings", "travel_memories", "milestones", "meals", "family",
        "drinks", "collectibles", "sports", "workout",
        // v21：「電影」兩個字太常出現在海報、文章、截圖裡（電影院、電影票另外用 extraKeywords 比對）
        "movie", "film",
    ]

    /// 每個分類拿來比對文字的詞（已正規化，至少 2 個字）
    static func terms(for catalog: TaxonomyCatalog) -> [(nodeId: String, terms: [String])] {
        catalog.nodes.compactMap { node in
            guard node.level >= 2 else { return nil }
            var words: [String] = []
            if !nameStoplist.contains(node.id) { words.append(node.nameZh) }
            words += extraKeywords[node.id] ?? []
            let normalized = Array(Set(words.map(normalize).filter { $0.count >= 2 }))
            return normalized.isEmpty ? nil : (node.id, normalized.sorted { $0.count > $1.count })
        }
    }

    /// 文字裡出現的分類，較長（較具體）的詞優先
    static func nodeIds(in normalizedText: String, terms: [(nodeId: String, terms: [String])], limit: Int = 3) -> [String] {
        guard !normalizedText.isEmpty else { return [] }
        var hits: [(nodeId: String, length: Int)] = []
        for entry in terms {
            if let term = entry.terms.first(where: { normalizedText.contains($0) }) {
                hits.append((entry.nodeId, term.count))
            }
        }
        return hits.sorted { ($0.length, $1.nodeId) > ($1.length, $0.nodeId) }.prefix(limit).map(\.nodeId)
    }

    // MARK: 紙張與卡片：靠文字決定分類

    /// 「看起來像紙張或卡片」的分類：照片最像的分類裡有這些，才自動辨識文字。
    /// 模型分不出票根、收據、證件、菜單（都是一張有字的紙或卡片），要靠上面的字。
    static let paperLikeNodeIds: Set<String> = ["receipt", "id_card", "menu", "document",
                                                "textbook", "handwritten_notes", "boarding_pass"]

    /// 由文字決定的紙張類分類（依序比對，先符合的優先）。關鍵字都已正規化（小寫、無空白）。
    /// 計分：明確的字（strong）2 分、只是可能相關的字（weak）1 分，要 2 分以上才算。
    /// 例：黑板上的「座位表」只有「座位」1 分，不算票根；電影票有放映、票種、票號、票價，一定超過。
    /// 電影票上常印有統一編號，所以票根排在收據前面。
    struct PaperRule {
        let nodeId: String
        let strong: [String]
        let weak: [String]
        /// 文字裡至少要有其中一個（空的代表不限）。例：電影票要有電影相關的字，演唱會門票不算電影
        var requiresAny: [String] = []
    }

    static let paperRules: [PaperRule] = [
        PaperRule(nodeId: "body_composition",
                  strong: ["inbody", "體組成", "骨骼肌", "體脂肪"],
                  weak: ["體脂率", "基礎代謝", "內臟脂肪"]),
        // 登機證、電子機票：排在票根前面（登機證也有座位、票價這些字）
        PaperRule(nodeId: "boarding_pass",
                  strong: ["boardingpass", "登機證", "登机牌", "電子機票", "eticket", "boardingtime", "登機時間"],
                  weak: ["gate", "登機門", "flight", "班機", "航班", "seat", "zone", "經濟艙", "economy", "訂位代號",
                         "起飛", "departure"]),
        // 威秀等影城的電影票：放映影城／放映時間／放映日期、廳排號、票種、票價、票號、級數、存根聯
        //（不用「影城」當分數：販賣部的發票也有；不用「機票」：訂機票的頁面也有座位、票價）
        // v21：票根併入「電影」，所以要有電影相關的字才算（演唱會、展覽的門票不算電影）
        PaperRule(nodeId: "movie",
                  strong: ["電影票", "放映", "票種", "票號", "存根聯", "票根", "入場券"],
                  // 「門票」只算 1 分：活動簡章、海報上也常寫「門票 NT$300」
                  weak: ["門票", "座位", "場次", "票價", "影廳", "普遍級", "保護級", "輔導級", "限制級", "4dx", "imax",
                         "admission", "ticket"],
                  requiresAny: ["電影", "放映", "影廳", "影城", "威秀", "秀泰", "國賓", "普遍級", "保護級", "輔導級", "限制級",
                                "4dx", "imax", "cinema", "movie"]),
        PaperRule(nodeId: "receipt",
                  strong: ["電子發票", "發票號碼", "統一編號", "收據", "receipt", "invoice"],
                  weak: ["統編", "合計", "總計", "小計", "找零", "subtotal", "total"]),
        PaperRule(nodeId: "id_card",
                  strong: ["學生證", "身分證", "身份證", "居留證", "健保卡", "駕照", "studentid", "identitycard"],
                  weak: ["學號", "會員卡", "悠遊卡", "一卡通", "卡號", "有效期限"]),
        PaperRule(nodeId: "menu",
                  strong: ["菜單", "menu", "價目表", "飲品單"],
                  weak: ["套餐", "單點", "加點", "大份", "小份"]),
    ]

    static var paperDecisionNodeIds: Set<String> { Set(paperRules.map(\.nodeId)) }
    static let boardingPass = "boarding_pass"
    /// 截圖的文字只當作這些分類的線索
    static let screenshotHintNodeIds: Set<String> = ["chat_screenshot", boardingPass]

    /// 這段文字對某個規則的分數
    static func paperScore(_ rule: PaperRule, in normalizedText: String) -> Int {
        rule.strong.filter { normalizedText.contains($0) }.count * 2
            + rule.weak.filter { normalizedText.contains($0) }.count
    }

    /// 文字決定的紙張類分類（2 分以上，先符合的規則優先）；都不夠時為 nil。
    /// 收據另外要有收據的格式（見 looksLikeReceipt）：公告、公文寫到「收據」兩個字不算。
    static func paperDecision(in normalizedText: String) -> String? {
        guard !normalizedText.isEmpty else { return nil }
        return paperRules.first { rule in
            paperScore(rule, in: normalizedText) >= 2
                && (rule.requiresAny.isEmpty || rule.requiresAny.contains { normalizedText.contains($0) })
                && (rule.nodeId != receipt || looksLikeReceipt(normalizedText))
        }?.nodeId
    }

    static let receipt = "receipt"

    /// 台灣統一發票號碼：兩個英文字母＋8 位數字（例如 FR-12772916）。
    /// 前面不能接英文字母、後面不能再接數字：「tel0212345678」這類電話、網址、文件編號不算。
    private static let invoiceNumber = try! NSRegularExpression(pattern: "(?<![a-z])[a-z]{2}-?[0-9]{8}(?![0-9])")
    /// 金額欄位：總計、合計、小計、找零…後面接著數字（例如「總計:$120」「total120」）
    private static let amountField = try! NSRegularExpression(
        pattern: "(總計|合計|小計|找零|應付|實收|實付|現金|信用卡|total|subtotal|amount|tax)[:：]?(nt\\$|\\$|＄|元)?[0-9]")
    private static let receiptWords = ["發票", "收據", "receipt", "invoice", "統一編號", "統編", "交易明細", "隨機碼"]

    /// 文字有沒有收據的格式：
    /// - 有「電子發票證明聯」→ 是
    /// - 有發票號碼（兩個英文字母＋8 位數字），而且有「發票、收據、統編…」或金額欄位 → 是
    /// - 有金額欄位（總計 120、找零 30…），而且有「發票、收據、統編…」→ 是
    /// 其他（公告寫「請繳交收據」、文件上的「統一編號」、只有一堆數字的表格、電話號碼）都不算。
    static func looksLikeReceipt(_ normalizedText: String) -> Bool {
        guard !normalizedText.isEmpty else { return false }
        if normalizedText.contains("電子發票證明聯") || normalizedText.contains("發票證明聯") { return true }
        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        let hasReceiptWord = receiptWords.contains { normalizedText.contains($0) }
        let amounts = amountField.numberOfMatches(in: normalizedText, range: range)
        if invoiceNumber.firstMatch(in: normalizedText, range: range) != nil { return hasReceiptWord || amounts > 0 }
        return amounts >= 1 && hasReceiptWord
    }

    /// 照片向量覺得像紙張或卡片、文字又說明了是什麼：直接確認那個分類，並拿掉其他紙張類的自動結果
    /// （例如看起來像收據、但文字有「影廳、座位」→ 票根）。
    static func applyPaperDecision(_ suggestions: [TagSuggestion], nodeId: String) -> [TagSuggestion] {
        let others = paperDecisionNodeIds.subtracting([nodeId])
        var result = suggestions.filter { !others.contains($0.nodeId) }
        if let index = result.firstIndex(where: { $0.nodeId == nodeId }) {
            result[index] = TagSuggestion(nodeId: nodeId, score: max(result[index].score, 0.5), status: .accepted)
        } else {
            result.append(TagSuggestion(nodeId: nodeId, score: 0.5, status: .accepted))
        }
        return result
    }

    /// 文字裡出現這些字：多半是菜單（價目表）
    static let menuWords = ["菜單", "menu", "價目表", "價目"]

    /// 菜色類分類：「美食與飲品」底下、菜單以外的分類（麵食、壽司、蛋糕、咖啡、夜市…）
    static func dishNodeIds(for catalog: TaxonomyCatalog) -> Set<String> {
        Set(catalog.descendants(of: "food_drink").map(\.id)).subtracting(["menu", "menus"])
    }

    /// 照片向量的分類結果＋照片文字：
    /// - 一般照片：文字提到的分類當作線索（見 merge）
    /// - 菜單、筆記這類紙張上的菜名不算（見 dishNodeIds）
    /// - 看起來像紙張或卡片：再由文字直接決定是票根、收據、證件、菜單或體組成
    /// - 螢幕截圖（訂票頁面、海報截圖…）：不會被當成票根、收據這些紙張類
    static func combine(_ suggestions: [TagSuggestion], normalizedText: String?,
                        terms: [(nodeId: String, terms: [String])], looksLikePaper: Bool,
                        isScreenshot: Bool = false, dishNodeIds: Set<String> = []) -> [TagSuggestion] {
        guard let text = normalizedText, !text.isEmpty else { return suggestions }
        // 菜單、筆記、收據上寫的菜名（牛肉麵、拉麵…）不代表照片拍的是那道菜：
        // 看起來像紙張、或文字提到「菜單」時，菜色類分類不當作文字線索
        let onPaper = looksLikePaper || menuWords.contains { text.contains($0) }
        let usableTerms = onPaper && !dishNodeIds.isEmpty ? terms.filter { !dishNodeIds.contains($0.nodeId) } : terms
        var hints = nodeIds(in: text, terms: usableTerms)
        // 「收據」「發票」兩個字不夠：要有收據的格式（金額、發票號碼）才當作線索
        if !looksLikeReceipt(text) { hints.removeAll { $0 == receipt } }
        // 截圖：聊天、網頁、訂購頁面上提到的東西（演唱會、拉麵、票、收據…）不代表截圖的內容，
        // 只留聊天截圖與登機證（手機錢包的登機證截圖）這兩種線索。
        if isScreenshot { hints.removeAll { !screenshotHintNodeIds.contains($0) } }
        var result = merge(suggestions, hintNodeIds: hints)
        if let decided = paperDecision(in: text),
           (looksLikePaper && !isScreenshot) || (isScreenshot && decided == boardingPass) {
            result = applyPaperDecision(result, nodeId: decided)
        }
        return result
    }

    /// 把文字線索併進照片向量的分類結果：
    /// - 向量判斷「待確認」、文字也提到 → 直接確認（兩種證據一致）
    /// - 只有文字提到 → 列入待確認（最多 maxNew 個），由使用者回答
    /// - 已確認的不變
    static func merge(_ suggestions: [TagSuggestion], hintNodeIds: [String], maxNew: Int = 2) -> [TagSuggestion] {
        guard !hintNodeIds.isEmpty else { return suggestions }
        let hints = Set(hintNodeIds)
        var result = suggestions.map { suggestion -> TagSuggestion in
            guard hints.contains(suggestion.nodeId), suggestion.status == .candidate else { return suggestion }
            return TagSuggestion(nodeId: suggestion.nodeId, score: max(suggestion.score, 0.5), status: .accepted)
        }
        let present = Set(result.map(\.nodeId))
        for nodeId in hintNodeIds.filter({ !present.contains($0) }).prefix(maxNew) {
            result.append(TagSuggestion(nodeId: nodeId, score: 0.3, status: .candidate))
        }
        return result
    }
}

// MARK: - 資料庫

struct PhotoTextStats: Equatable {
    let recognized: Int      // 已辨識（含沒有文字的照片）
    let withText: Int        // 有文字的照片
    let pending: Int         // 還沒辨識
}

extension PersonalizationStore {

    /// 還沒辨識文字（或辨識版本較舊）的照片：已有照片向量、沒有被「移除 AI 分析資料」。較新加入的優先。
    func assetsPendingOCR(limit: Int) throws -> [String] {
        try query("""
        SELECT f.asset_id FROM PhotoFeatures f
        LEFT JOIN PhotoText t ON t.asset_id = f.asset_id
        WHERE f.ai_removed_at IS NULL AND f.image_embedding IS NOT NULL
          AND (t.asset_id IS NULL OR t.ocr_version IS NOT ?)
        ORDER BY f.rowid DESC
        LIMIT ?
        """, PhotoTextHints.ocrVersion, Int64(max(limit, 0))).compactMap { $0[0] as? String }
    }

    func photoTextStats() throws -> PhotoTextStats {
        let recognized = try scalarInt("""
        SELECT COUNT(*) FROM PhotoText t LEFT JOIN PhotoFeatures f ON f.asset_id = t.asset_id
        WHERE f.ai_removed_at IS NULL AND t.ocr_version = ?
        """, PhotoTextHints.ocrVersion)
        let withText = try scalarInt("""
        SELECT COUNT(*) FROM PhotoText t LEFT JOIN PhotoFeatures f ON f.asset_id = t.asset_id
        WHERE f.ai_removed_at IS NULL AND t.ocr_version = ? AND t.normalized <> ''
        """, PhotoTextHints.ocrVersion)
        let pending = try scalarInt("""
        SELECT COUNT(*) FROM PhotoFeatures f
        LEFT JOIN PhotoText t ON t.asset_id = f.asset_id
        WHERE f.ai_removed_at IS NULL AND f.image_embedding IS NOT NULL
          AND (t.asset_id IS NULL OR t.ocr_version IS NOT ?)
        """, PhotoTextHints.ocrVersion)
        return PhotoTextStats(recognized: recognized, withText: withText, pending: pending)
    }

    /// 儲存辨識結果（沒有文字也存空字串，避免重複辨識）。照片在這期間被移除 AI 分析時不寫入，回傳 false。
    @discardableResult
    func savePhotoText(assetId: String, text: String, version: String = PhotoTextHints.ocrVersion) throws -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try write {
            try exec("""
            INSERT INTO PhotoText (asset_id, text, normalized, ocr_version, recognized_at)
            SELECT ?, ?, ?, ?, CURRENT_TIMESTAMP
            WHERE NOT EXISTS (SELECT 1 FROM PhotoFeatures WHERE asset_id = ? AND ai_removed_at IS NOT NULL)
            ON CONFLICT(asset_id) DO UPDATE SET
                text = excluded.text, normalized = excluded.normalized,
                ocr_version = excluded.ocr_version, recognized_at = CURRENT_TIMESTAMP
            """, assetId, cleaned, PhotoTextHints.normalize(cleaned), version, assetId)
            return db.changes > 0
        }
    }

    func photoText(assetId: String) throws -> String? {
        try query("SELECT text FROM PhotoText WHERE asset_id = ?", assetId).first?[0] as? String
    }

    /// 多張照片的正規化文字（分類時使用）
    func normalizedPhotoTexts(assetIds: [String]) throws -> [String: String] {
        guard !assetIds.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for chunk in stride(from: 0, to: assetIds.count, by: 400).map({ Array(assetIds[$0..<min($0 + 400, assetIds.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let args: [Binding?] = chunk
            for row in try db.prepare("SELECT asset_id, normalized FROM PhotoText WHERE normalized <> '' AND asset_id IN (\(placeholders))").run(args) {
                if let id = row[0] as? String, let text = row[1] as? String { result[id] = text }
            }
        }
        return result
    }

    /// 文字中包含查詢的照片（首頁搜尋）。出現次數多的在前。
    func assetIds(matchingPhotoText text: String, limit: Int = 300) throws -> [String] {
        let needle = PhotoTextHints.normalize(text)
        guard !needle.isEmpty else { return [] }
        // LIKE 的萬用字元當成一般文字（跳脫字元用「!」）
        let escaped = needle
            .replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
        return try query("""
        SELECT t.asset_id FROM PhotoText t LEFT JOIN PhotoFeatures f ON f.asset_id = t.asset_id
        WHERE f.ai_removed_at IS NULL AND t.normalized LIKE ? ESCAPE '!'
        ORDER BY (length(t.normalized) - length(replace(t.normalized, ?, ''))) DESC, t.recognized_at DESC
        LIMIT ?
        """, "%\(escaped)%", needle, Int64(max(limit, 0))).compactMap { $0[0] as? String }
    }
}


// MARK: - 人像（自拍、人物照）

/// 人像分類不再偵測人臉（耗電，而且會把人形立牌、競選看板上的臉當成人）：
/// - 自拍：用 iPhone「照片」App 內建的「自拍」相簿（系統依前鏡頭分好，App 只讀名單，不分析照片）
/// - 人物照：照片向量判斷「照片主角是人」，不分幾個人（照片向量數不出人數）
enum PeopleHints {
    static let selfie = "selfie"
    static let person = "portrait"
    /// 自拍的分數（只用來排序；系統相簿分好的，很有把握）
    static let selfieScore: Float = 0.5

    /// 系統「自拍」相簿裡的照片標上自拍（自拍就不再另外標人物照）；不在裡面的照片拿掉照片向量給的自拍。
    /// - selfieAllowed: 自拍分類有開啟
    /// - maxAccepted: 每張最多幾個確認的分類；超過時拿掉分數最低的其他分類
    static func combine(_ suggestions: [TagSuggestion], isSelfie: Bool, selfieAllowed: Bool,
                        maxAccepted: Int) -> [TagSuggestion] {
        var result = suggestions.filter { $0.nodeId != selfie }
        guard isSelfie, selfieAllowed else { return result }
        result.removeAll { $0.nodeId == person }
        let accepted = result.filter { $0.status == .accepted }.sorted { $0.score > $1.score }
        let room = max(0, maxAccepted - 1)
        if accepted.count > room {
            let dropped = Set(accepted.suffix(accepted.count - room).map(\.nodeId))
            result.removeAll { $0.status == .accepted && dropped.contains($0.nodeId) }
        }
        return [TagSuggestion(nodeId: selfie, score: selfieScore, status: .accepted)] + result
    }
}

extension PersonalizationStore {

    /// 以前人臉偵測留下的資料（人臉數量與大小）：不再使用，清掉。資料表保留，不重建資料庫。
    @discardableResult
    func clearFaceData() throws -> Int {
        guard try tableExists("PhotoFaces") else { return 0 }
        return try write {
            try exec("DELETE FROM PhotoFaces")
            return db.changes
        }
    }
}

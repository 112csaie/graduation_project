//
//  ASTextPhotoFilter.swift
//  抽象語意搜尋模組（v10）
//
//  文字型照片（截圖、文件、收據、菜單…）不建圖：
//  用同學 App 已經算好的 OCR 與 MobileCLIP 標籤，直接產生一筆簡化的場景圖。
//
//  判斷規則與 PC 版 ocr_filter_experiment.py 相同：
//    1. OCR 文字面積 ≥ 10% 且字數 ≥ 20 → 文字型照片
//       （沒有文字面積時，改用字數 ≥ fallbackMinChars 判斷）
//    2. 類型標籤 = MobileCLIP 分數 ≥ 0.10 的前 3 名
//       （OCR 關鍵字補標籤預設關閉：PC 實驗沒有提升，還會誤補，例如網頁上的「Menu」被補成菜單）
//    3. 場景圖 = 標籤當主體、「這是一張 X。」當描述、OCR 前 80 字
//
//  PC 實驗結果（124 張、30 條查詢）：16 張文字照片完全不建圖，整體 MRR 0.812 → 0.804。
//  注意：CLIP 不能單獨用來判斷是不是文字照片（會把很多一般照片誤判成海報、截圖），
//  一定要先用 OCR 判斷。
//

import Foundation

/// 同學那邊的一個 CLIP 標籤
public struct ASClipTag: Sendable, Hashable {
    public let tag: String
    /// 0～1 的機率（softmax 後）。只有標籤沒有分數時傳 1
    public let score: Double

    public init(tag: String, score: Double = 1) {
        self.tag = tag
        self.score = score
    }
}

/// 同學 App 對一張照片已經算好的結果
public struct ASPhotoHint: Sendable {
    /// OCR 辨識出的全部文字（沒有文字就傳空字串）
    public var ocrText: String
    /// 文字框面積總和 ÷ 照片面積（0～1）。拿不到就傳 nil，改用字數判斷
    public var textAreaRatio: Double?
    /// CLIP 標籤，分數由高到低（前 3 名就夠）
    public var clipTags: [ASClipTag]
    /// 是否為螢幕截圖（PHAsset.mediaSubtypes 含 .photoScreenshot）；用來決定照片類型
    public var isScreenshot: Bool

    public init(ocrText: String, textAreaRatio: Double? = nil, clipTags: [ASClipTag] = [], isScreenshot: Bool = false) {
        self.ocrText = ocrText
        self.textAreaRatio = textAreaRatio
        self.clipTags = clipTags
        self.isScreenshot = isScreenshot
    }
}

public enum ASTextPhotoFilter {
    /// 對應 PC 版：文字面積門檻與最少字數
    nonisolated(unsafe) public static var minAreaRatio = 0.10
    nonisolated(unsafe) public static var minChars = 20
    /// 沒有文字面積時的字數門檻。PC 實驗：≥ 200 字和面積判斷 16 張中有 14 張一致，多抓 2 張；
    /// 門檻再低會把有字的一般照片（例如教室裡拍到投影片）也當成文字照片
    nonisolated(unsafe) public static var fallbackMinChars = 200
    /// 是否用 OCR 關鍵字補標籤（預設關閉，見檔案開頭說明）
    nonisolated(unsafe) public static var useKeywordTags = false
    /// CLIP 標籤：分數 ≥ minTagScore 的前 maxClipTags 名
    nonisolated(unsafe) public static var minTagScore = 0.10
    nonisolated(unsafe) public static var maxClipTags = 3
    /// 只保留 OCR 前幾個字（PC 實驗：長篇 OCR 對排序沒有幫助，反而會稀釋描述）
    nonisolated(unsafe) public static var ocrPrefixLength = 80

    /// 這個版本的規則名稱，存在資料庫的 model 欄位；規則改了就改這個值，文字照片會自動重算
    static let recordModelName = "text-filter-v1"

    /// OCR 關鍵字補標籤（和 PC 版 KEYWORD_TAGS 相同）
    static let keywordRules: [(tag: String, pattern: String)] = [
        ("收據發票", "發票|收據|統一編號|合計|總計|小計|找零|交易明細|RECEIPT|Receipt"),
        ("菜單", "菜單|MENU|Menu|套餐|價目"),
        ("考卷題目", "第\\s*\\d+\\s*題|選擇題|何者|[（(][A-DＡ-Ｄ][)）]"),
        ("講義課本", "目錄|講義|課綱|第\\s*[一二三四五六七八九十\\d]+\\s*[章課節]"),
        ("機票登機證", "登機|航班|Boarding|BOARDING|Flight|FLIGHT|Gate|GATE"),
        ("票券", "票價|入場|場次|Ticket|TICKET"),
        ("新聞截圖", "記者|報導|中央社|新聞"),
        ("聊天截圖", "已讀|輸入訊息|傳送訊息"),
    ]

    /// 是不是「只看文字就能找到」的照片
    public static func isTextPhoto(_ hint: ASPhotoHint) -> Bool {
        let chars = hint.ocrText.filter { !$0.isWhitespace }.count
        if let ratio = hint.textAreaRatio {
            return ratio >= minAreaRatio && chars >= minChars
        }
        return chars >= fallbackMinChars
    }

    static func keywordTags(_ text: String) -> [String] {
        keywordRules.compactMap { rule in
            text.range(of: rule.pattern, options: .regularExpression) != nil ? rule.tag : nil
        }
    }

    /// 類型標籤：CLIP 前幾名（開啟 useKeywordTags 時再加關鍵字補的）；都沒有就用「截圖」或「文件」
    static func tags(for hint: ASPhotoHint) -> [String] {
        var tags: [String] = []
        for t in hint.clipTags.sorted(by: { $0.score > $1.score })
            where t.score >= minTagScore && tags.count < maxClipTags && !tags.contains(t.tag) {
            tags.append(t.tag)
        }
        for t in (useKeywordTags ? keywordTags(hint.ocrText) : []) where !tags.contains(t) {
            tags.append(t)
        }
        if tags.isEmpty { tags = [hint.isScreenshot ? "截圖" : "文件"] }
        return tags
    }

    /// 產生簡化的場景圖（不呼叫任何模型）
    public static func graph(from hint: ASPhotoHint) -> ASSceneGraph {
        let tags = tags(for: hint)
        var g = ASSceneGraph()
        g.contentType = hint.isScreenshot ? "screenshot" : "document"
        g.entities = tags.enumerated().map { i, t in
            ASEntity(id: "e\(i + 1)", name: t, category: "object", concept: t, count: 1, attributes: [])
        }
        g.explanation = "這是一張\(tags.joined(separator: "或"))。"
        let text = hint.ocrText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        g.visibleTextSummary = String(text.prefix(ocrPrefixLength))
        return g.normalized()
    }
}

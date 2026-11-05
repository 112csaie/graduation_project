// TaxonomyTuning.swift
//
// 逐一調整主題分類：桌面「相簿主題設定」資料夾裡每個分類一個 JSON 檔（名稱、門檻、提示詞、容易誤認的畫面…），
// 改完執行資料夾裡的「套用到App.py」，它會比對原始設定，把「有改的地方」寫進 TaxonomyTuningData.swift。
// App 啟動時把這些調整套用到內建分類目錄（TaxonomyCatalog.builtIn）與全域門檻（TaggingThresholds.default）。
//
// - 沒有任何調整時（TaxonomyTuningData.json 為 {}），行為和以前完全一樣。
// - 調整內容一變，簽章（signature）就會變：App 下次啟動會更新資料庫裡的分類名稱與提示詞（新提示詞補算文字向量），
//   並用既有照片向量重新比對自動標籤。不會重算照片向量，也不會動到手動標籤或照片本身。
//
// 本檔案只依賴 Foundation，可在 macOS 用 swift test 驗證。

import Foundation

/// 單一分類的調整；nil 代表沿用內建設定
struct TaxonomyNodeTuning: Codable, Equatable {
    var nameZh: String?
    var nameEn: String?
    var recognition: RecognitionMode?
    /// 這個分類自己的確認門檻（取代全域的 acceptScore；選了／沒選大分類的加減仍照常套用）
    var acceptScore: Float?
    var prompts: [String]?
    var confusers: [String]?
    var suppressedBy: [String]?
    var distinct: Bool?
    var enabledByDefault: Bool?
}

/// 全域門檻的調整；nil 代表沿用預設值
struct TaggingThresholdTuning: Codable, Equatable {
    var acceptScore: Float?
    var preferredAcceptBonus: Float?
    var unpreferredAcceptPenalty: Float?
    var acceptMarginFromBest: Float?
    var maxAccepted: Int?
    var suppressMargin: Float?
    var distinctMarginFromBest: Float?
}

struct TaxonomyTuning: Codable, Equatable {
    var thresholds: TaggingThresholdTuning?
    var nodes: [String: TaxonomyNodeTuning]?

    static let empty = TaxonomyTuning(thresholds: nil, nodes: nil)

    /// App 內建的調整（由「套用到App.py」產生）。格式錯誤時不套用任何調整，並在除錯輸出提醒。
    static let current: TaxonomyTuning = {
        do {
            return try parse(TaxonomyTuningData.json)
        } catch {
            print("[主題設定] TaxonomyTuningData.json 格式錯誤，沿用內建設定：\(error)")
            return .empty
        }
    }()

    /// 調整內容的簽章（沒有調整時為空字串）。內容改變時 App 會重新同步分類與重新比對自動標籤。
    static let currentSignature: String = signature(of: TaxonomyTuningData.json)

    static func parse(_ json: String) throws -> TaxonomyTuning {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return .empty }
        return try JSONDecoder().decode(TaxonomyTuning.self, from: Data(trimmed.utf8))
    }

    /// FNV-1a 64 位元（跨版本穩定，不用 Swift 的 hashValue）
    static func signature(of json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return "" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    var isEmpty: Bool { (nodes ?? [:]).isEmpty && thresholds == nil }

    // MARK: 套用

    func apply(to nodes: [TaxonomyNode]) -> [TaxonomyNode] {
        guard let tuned = self.nodes, !tuned.isEmpty else { return nodes }
        return nodes.map { node in tuned[node.id].map { apply($0, to: node) } ?? node }
    }

    private func apply(_ t: TaxonomyNodeTuning, to node: TaxonomyNode) -> TaxonomyNode {
        var result = TaxonomyNode(
            id: node.id, parentId: node.parentId, level: node.level,
            nameZh: t.nameZh ?? node.nameZh, nameEn: t.nameEn ?? node.nameEn,
            summaryZh: node.summaryZh, summaryEn: node.summaryEn, examplesZh: node.examplesZh, icon: node.icon,
            recognition: t.recognition ?? node.recognition,
            prompts: t.prompts ?? node.prompts,
            requiresAnyOf: node.requiresAnyOf,
            enabledByDefault: t.enabledByDefault ?? node.enabledByDefault,
            sortOrder: node.sortOrder,
            suppressedBy: t.suppressedBy ?? node.suppressedBy,
            confusers: t.confusers ?? node.confusers,
            distinct: t.distinct ?? node.distinct)
        result.acceptScore = t.acceptScore ?? node.acceptScore
        result.requiresText = node.requiresText
        return result
    }

    func apply(to base: TaggingThresholds) -> TaggingThresholds {
        guard let t = thresholds else { return base }
        var result = base
        if let v = t.acceptScore { result.acceptScore = v }
        if let v = t.preferredAcceptBonus { result.preferredAcceptBonus = v }
        if let v = t.unpreferredAcceptPenalty { result.unpreferredAcceptPenalty = v }
        if let v = t.acceptMarginFromBest { result.acceptMarginFromBest = v }
        if let v = t.maxAccepted { result.maxAccepted = v }
        if let v = t.suppressMargin { result.suppressMargin = v }
        if let v = t.distinctMarginFromBest { result.distinctMarginFromBest = v }
        return result
    }

    // MARK: 檢查

    /// 調整引用了不存在的分類、門檻超出合理範圍時的錯誤（套用腳本也會先檢查一次）
    func validationErrors(baseNodeIds: Set<String>) -> [String] {
        var errors: [String] = []
        for (id, t) in nodes ?? [:] {
            if !baseNodeIds.contains(id) { errors.append("調整了不存在的分類：\(id)") }
            if let score = t.acceptScore, !(0.1...0.5).contains(score) { errors.append("門檻超出 0.1～0.5：\(id) = \(score)") }
            for ref in t.suppressedBy ?? [] where !baseNodeIds.contains(ref) {
                errors.append("排除規則引用不存在的分類：\(id) → \(ref)")
            }
            if t.recognition == .derived { errors.append("不能把分類改成組合推論（derived）：\(id)") }
        }
        if let score = thresholds?.acceptScore, !(0.1...0.5).contains(score) {
            errors.append("全域門檻超出 0.1～0.5：\(score)")
        }
        return errors
    }
}

// ReferenceMatcher.swift
//
// 「我的 IP」：用使用者挑的範例照片找出同一個 IP（作品、角色、團體）的其他照片。
//
// 為什麼不用文字：MobileCLIP 的文字比對只認得很有名的東西（皮卡丘、Hello Kitty），
// 小眾作品、新角色或某個團體它多半不認得。改成「照片 × 照片」比對：
// 同一個角色的立牌、徽章、小卡在設計與配色上很接近，比文字描述可靠得多。
//
// 做法（全部沿用既有照片向量，不重算、不需要新套件）：
// - 正面範例：建立時挑的照片 + 之後按「是」的照片（PhotoTags 中 source = manual、status = accepted）。
// - 反面範例：按「不是」的照片（source = manual、status = rejected），
//   以及同一部作品其他角色的範例（例如五條悟的題目不會出現比較像虎杖悠仁的照片）。
// - 每張照片的分數 = 與最像的正面範例的相似度（1-NN）；另外計算與最像的兩張的平均。
// - 比任何反面範例都更像反面 → 不算。
// - 非常像（幾乎同一件周邊）→ 自動加入；有點像 → 待確認，交給使用者回答；回答會成為新的範例，越用越準。
//
// 門檻說明：專案沒有標註過的驗證資料，以下是保守的初始值（寧可多問、不要亂分），應依實際使用調整。

import Foundation

struct ReferenceMatchThresholds: Equatable {
    /// 與某一張範例的相似度達此值 → 自動加入（幾乎是同一件周邊／同一張圖）。
    var acceptTop1: Float = 0.86
    /// 與最像的兩張範例平均達此值 → 自動加入（和多張範例都很像）。
    var acceptTop2Mean: Float = 0.80
    /// 與某一張範例的相似度達此值 → 待確認。
    var candidateTop1: Float = 0.72
    /// 每個 IP 最多產生的待確認數（依分數由高到低），避免待確認爆量。
    var maxCandidates: Int = 60

    static let `default` = ReferenceMatchThresholds()
}

struct ReferenceMatch: Equatable {
    let assetId: String
    let score: Float
    let status: TagStatus   // accepted 或 candidate
}

enum ReferenceMatcher {

    static let version = "ref-1"

    /// - Parameters:
    ///   - positives: 正面範例向量（已 L2 正規化）。
    ///   - negatives: 反面範例向量。
    ///   - photos: 要比對的照片（assetId, 向量）。
    ///   - excluded: 已有使用者回答（範例或拒絕）的照片，不再自動判斷。
    static func match(positives: [[Float]],
                      negatives: [[Float]],
                      photos: [(assetId: String, embedding: [Float])],
                      excluded: Set<String>,
                      thresholds: ReferenceMatchThresholds = .default) -> [ReferenceMatch] {
        guard !positives.isEmpty else { return [] }
        var accepted: [ReferenceMatch] = []
        var candidates: [ReferenceMatch] = []

        for photo in photos where !excluded.contains(photo.assetId) && !photo.embedding.isEmpty {
            var best: Float = -1
            var second: Float = -1
            for example in positives {
                let score = MultiLabelTagger.dot(photo.embedding, example)
                if score > best {
                    second = best
                    best = score
                } else if score > second {
                    second = score
                }
            }
            guard best >= thresholds.candidateTop1 else { continue }

            // 比任何反面範例都更像反面 → 不算（使用者說過「不是」的那種照片）
            var bestNegative: Float = -1
            for example in negatives {
                bestNegative = max(bestNegative, MultiLabelTagger.dot(photo.embedding, example))
            }
            if !negatives.isEmpty && bestNegative >= best { continue }

            let top2Mean = positives.count >= 2 ? (best + second) / 2 : best
            if best >= thresholds.acceptTop1 || (positives.count >= 2 && top2Mean >= thresholds.acceptTop2Mean) {
                accepted.append(ReferenceMatch(assetId: photo.assetId, score: best, status: .accepted))
            } else {
                candidates.append(ReferenceMatch(assetId: photo.assetId, score: best, status: .candidate))
            }
        }

        candidates.sort { ($0.score, $1.assetId) > ($1.score, $0.assetId) }
        return accepted + candidates.prefix(max(0, thresholds.maxCandidates))
    }
}

// MARK: - 使用者自訂分類（我的 IP）

enum CustomCategoryKind: String, Codable, CaseIterable {
    case ip
}

struct CustomCategory: Identifiable, Hashable {
    let id: String
    let kind: CustomCategoryKind
    let name: String
    /// 上層 IP（例如角色「五條悟」的上層是作品「咒術迴戰」）；nil 代表最上層。
    var parentId: String? = nil
    /// 使用者自選的封面照片。
    var coverAssetId: String? = nil

    /// 在 PhotoTags 中使用的節點 ID，例如「ip:6F1C…」。
    var nodeId: String { Self.nodeId(kind: kind, id: id) }

    static func nodeId(kind: CustomCategoryKind, id: String) -> String { kind.rawValue + ":" + id }

    /// 「ip:xxx」→ ("ip", "xxx")；不是自訂分類時回傳 nil。
    static func parse(nodeId: String) -> (kind: CustomCategoryKind, id: String)? {
        guard let colon = nodeId.firstIndex(of: ":"),
              let kind = CustomCategoryKind(rawValue: String(nodeId[..<colon])) else { return nil }
        let id = String(nodeId[nodeId.index(after: colon)...])
        return id.isEmpty ? nil : (kind, id)
    }

    static func isCustomNodeId(_ nodeId: String) -> Bool { parse(nodeId: nodeId) != nil }

    /// 同一部作品底下的其他角色。它們的範例會當成這個角色的額外反例：
    /// 比較像虎杖悠仁的照片，就不會出現在「是五條悟嗎？」的題目裡。最上層的 IP 沒有兄弟。
    func siblings(in all: [CustomCategory]) -> [CustomCategory] {
        guard let parentId else { return [] }
        return all.filter { $0.parentId == parentId && $0.id != id }
    }
}

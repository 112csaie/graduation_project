// InterestRecommender.swift
//
// 興趣定位 → 大分類推薦與排序。
// 規則：興趣只影響「推薦、排序、預設設定」，不影響照片內容辨識，也不會隱藏任何大分類。

import Foundation

struct TopLevelRecommendation: Identifiable, Hashable {
    var id: String { node.id }
    let node: TaxonomyNode
    let score: Double
    /// 是哪些興趣推薦了這個大分類（用於 UI 說明「因為你選了…」）。
    let recommendedBy: [String]
    var isRecommended: Bool { score > 0 }
}

enum InterestRecommender {

    /// 依興趣計算全部大分類的排序。永遠回傳「完整」大分類清單：
    /// 推薦的排前面，其餘依目錄預設順序。未選任何興趣時就是預設順序。
    static func rankTopLevel(
        selectedInterestIds: Set<String>,
        catalog: TaxonomyCatalog = .builtIn
    ) -> [TopLevelRecommendation] {
        var scores: [String: Double] = [:]
        var sources: [String: [String]] = [:]

        let interests = catalog.interests.filter { selectedInterestIds.contains($0.id) }
        for interest in interests {
            let count = interest.recommendedTopLevelIds.count
            for (index, topId) in interest.recommendedTopLevelIds.enumerated() {
                // 第一順位 1.0，往後遞減，但至少 0.5；多個興趣推薦同一分類時分數累加。
                let weight = max(0.5, 1.0 - Double(index) * (0.5 / Double(max(count, 1))))
                scores[topId, default: 0] += weight
                sources[topId, default: []].append(interest.id)
            }
            // 相關子分類所屬的大分類：每個興趣對每個大分類最多加 0.05，只用來打破同分，
            // 不會推翻 recommendedTopLevelIds 的優先順序。
            let relatedTopIds = Set(interest.relatedNodeIds.compactMap { catalog.topLevelId(of: $0) })
            for topId in relatedTopIds {
                scores[topId, default: 0] += 0.05
                if !(sources[topId] ?? []).contains(interest.id) {
                    sources[topId, default: []].append(interest.id)
                }
            }
        }

        return catalog.topLevelNodes
            .map { node in
                TopLevelRecommendation(
                    node: node,
                    score: scores[node.id] ?? 0,
                    recommendedBy: sources[node.id] ?? []
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.node.sortOrder < rhs.node.sortOrder
            }
    }

    /// 興趣相關的子分類 ID（用於在瀏覽頁提升排序、在設定頁標示「推薦」）。
    static func relatedNodeIds(
        selectedInterestIds: Set<String>,
        catalog: TaxonomyCatalog = .builtIn
    ) -> Set<String> {
        Set(catalog.interests
            .filter { selectedInterestIds.contains($0.id) }
            .flatMap(\.relatedNodeIds))
    }

    /// 選取大分類後要自動啟用的子分類（L2 + L3，enabledByDefault == true）。
    static func defaultEnabledDescendants(
        ofTopLevel topLevelId: String,
        catalog: TaxonomyCatalog = .builtIn
    ) -> [TaxonomyNode] {
        catalog.descendants(of: topLevelId).filter(\.enabledByDefault)
    }

    /// 瀏覽頁的大分類排序：使用者啟用的優先，其次依興趣推薦分數，最後依預設順序。
    static func browseOrder(
        enabledTopLevelIds: Set<String>,
        selectedInterestIds: Set<String>,
        catalog: TaxonomyCatalog = .builtIn
    ) -> [TaxonomyNode] {
        let ranked = rankTopLevel(selectedInterestIds: selectedInterestIds, catalog: catalog)
        let rankIndex = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1.node.id, $0) })
        return catalog.topLevelNodes.sorted { lhs, rhs in
            let lEnabled = enabledTopLevelIds.contains(lhs.id)
            let rEnabled = enabledTopLevelIds.contains(rhs.id)
            if lEnabled != rEnabled { return lEnabled }
            return (rankIndex[lhs.id] ?? Int.max) < (rankIndex[rhs.id] ?? Int.max)
        }
    }
}

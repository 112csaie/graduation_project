//
//  ASHybridSearch.swift
//  抽象語意搜尋模組（v10）
//
//  混合式搜尋演算法，逐函式移植自 PC 版 hybrid_search_v10.py（註解標出對應的 Python 函式）。
//  這個檔案不呼叫任何模型，只做向量運算與場景圖比對，所以和 PC 版的結果應該一致
//  （前提是輸入的向量與解析結果相同）。
//
//  兩階段：
//    第一階段：整圖語意 + 實體，對全部照片計分，取前 N 張
//    第二階段：只對前 N 張加上數量、關係、類型重新排序
//

import Foundation
import Accelerate

// MARK: - 參數（與 PC 版相同）

public enum ASSearchConfig {
    nonisolated(unsafe) public static var weights: [String: Float] = [
        "semantic": 0.45,
        "image": 0.30,
        "entity": 0.35,
        "count": 0.20,
        "relation": 0.30,
        "type": 0.15,
    ]
    nonisolated(unsafe) public static var rerankTopN = 50
    static let groupCount = 6               // 「一群」「很多」解析成 6
    static let unverified: Float = 0.5      // 兩端都對到、但圖裡沒有路徑：建圖常漏邊，不否決
    static let opposite: Float = 0.05       // 方向完全相反
    static let reversedActionFactor: Float = 0.6
    static let hopDecay: Float = 0.85
    static let relationCandidates = 3
}

// MARK: - 文字組合（compose_document / compose_entity）

enum ASText {
    static func document(_ g: ASSceneGraph) -> String {
        let names = g.entities.map { $0.count > 1 ? "\($0.name)×\($0.count)" : $0.name }.filter { !$0.isEmpty }
        let parts: [String] = [
            g.explanation,
            g.event.isEmpty ? "" : "活動：\(g.event)",
            g.scene.location.isEmpty ? "" : "地點：\(g.scene.location)",
            g.scene.timeOfDay.isEmpty ? "" : "時間：\(g.scene.timeOfDay)",
            g.emotion.tags.isEmpty ? "" : "氛圍：\(g.emotion.tags.joined(separator: "、"))",
            g.appContext,
            g.visibleTextSummary,
            names.isEmpty ? "" : "內容：\(names.joined(separator: "、"))",
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: "；")
    }

    static func entity(_ e: ASEntity) -> String {
        let attrs = e.attributes.filter { !$0.isEmpty }.joined(separator: "、")
        let concept = e.concept.isEmpty ? "" : "（\(e.concept)）"
        return "\(e.name)\(concept)" + (attrs.isEmpty ? "" : "：\(attrs)")
    }
}

// MARK: - 照片索引（assemble_image_index）

struct ASImageIndex {
    let id: String
    let contentType: String
    let docText: String
    let docVec: [Float]
    let entIDs: [String]
    let entVecs: [[Float]]
    let entCategories: [String]
    let entCounts: [Int]
    /// 清洗後的邊（去除自我指向、指向不存在主體的關係）
    let edges: [ASRelation]
    /// 無向鄰接表，建索引時算好一次
    let neighbors: [String: Set<String>]

    init(stored s: ASStoredImage) {
        // 只保留有向量的主體，順序與 graph.entities 相同
        let ents = s.graph.entities.filter { s.entityVecs[$0.id] != nil }
        id = s.path
        contentType = s.graph.contentType
        docText = ASText.document(s.graph)
        docVec = s.docVec
        entIDs = ents.map(\.id)
        entVecs = ents.map { s.entityVecs[$0.id]! }
        entCategories = ents.map(\.category)
        entCounts = ents.map { $0.count > 0 ? $0.count : 1 }

        let nodeIDs = Set(s.graph.entities.map(\.id))
        edges = s.graph.relations.filter { $0.subject != $0.object && nodeIDs.contains($0.subject) && nodeIDs.contains($0.object) }
        var nb: [String: Set<String>] = [:]
        for e in edges {
            nb[e.subject, default: []].insert(e.object)
            nb[e.object, default: []].insert(e.subject)
        }
        neighbors = nb
    }

    /// u 與 v 之間的所有邊；forward = 邊的方向是 u → v
    func edgesBetween(_ u: String, _ v: String) -> [(ASRelation, Bool)] {
        edges.compactMap { e in
            if e.subject == u && e.object == v { return (e, true) }
            if e.subject == v && e.object == u { return (e, false) }
            return nil
        }
    }
}

// MARK: - 查詢索引（build_query_index）

struct ASQueryIndex {
    let text: String
    let fullVec: [Float]
    let facetVecs: [[Float]]
    let entities: [ASParsedEntity]
    let entVecs: [[Float]]
    let relations: [(s: Int, predicate: String, o: Int, type: String)]
    let contentType: String

    init(text: String, parsed: ASParsedQuery, embedder: ASTextEmbedding) throws {
        let ents = parsed.entities.filter { !$0.text.isEmpty }
        var textToIndex: [String: Int] = [:]
        for (k, e) in ents.enumerated() where textToIndex[e.text] == nil { textToIndex[e.text] = k }

        var actions = [[String]](repeating: [], count: ents.count)
        var rels: [(Int, String, Int, String)] = []
        for r in parsed.relations {
            guard let s = textToIndex[r.subject] else { continue }
            if r.object.isEmpty {
                // 不及物動作（散步、睡覺）：併進主詞的描述，讓實體比對去處理
                actions[s].append(r.predicate)
                continue
            }
            if let o = textToIndex[r.object] {
                rels.append((s, r.predicate, o, r.relationType))
            }
        }

        let entTexts: [String] = ents.enumerated().map { k, e in
            var head = e.text
            if !e.concept.isEmpty { head += "（\(e.concept)）" }
            let extra = e.attributes.filter { !$0.isEmpty } + actions[k]
            return head + (extra.isEmpty ? "" : "：\(extra.joined(separator: "、"))")
        }

        let moodText = parsed.mood.joined(separator: "、")
        let facets = [parsed.scene.location, parsed.scene.timeOfDay, parsed.event, moodText].filter { !$0.isEmpty }

        // 一次送進模型：整句、情境面向、實體
        let all = try embedder.embed([text] + facets + entTexts)
        self.text = text
        fullVec = all[0]
        facetVecs = Array(all[1..<(1 + facets.count)])
        entVecs = Array(all[(1 + facets.count)...])
        entities = ents
        relations = rels.map { (s: $0.0, predicate: $0.1, o: $0.2, type: $0.3) }
        contentType = parsed.contentType
    }
}

// MARK: - 關係類別（移植自 v9 relation_class / relation_type_score）

enum ASRelationRules {
    static let classKeywords: [(String, [String])] = [
        ("containment", ["包含於內部", "裡面", "裡", "內", "裝", "盛", "含", "之中", "inside"]),
        ("holding", ["持", "拿", "握", "手持", "抱", "holding"]),
        ("support", ["上方", "上面", "放置於", "放在", "擺在", "位於上", "on top"]),
        ("adjacent", ["旁邊", "附近", "緊鄰", "相鄰", "旁側", "next to", "near"]),
        ("depth", ["前方", "後方", "較靠近鏡頭", "較遠", "前面", "後面", "前景", "背景"]),
    ]

    static func relationClass(_ predicate: String) -> String? {
        let text = predicate.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        // 順序刻意讓 containment、holding 先於 support
        for (cls, words) in classKeywords where words.contains(where: { text.contains($0) }) {
            return cls
        }
        return nil
    }

    static func relationTypeScore(queryType: String, edgeType: String, queryPred: String, edgePred: String) -> Float {
        let qc = relationClass(queryPred), ec = relationClass(edgePred)
        if let qc, let ec {
            if qc == ec { return 1.0 }
            let near: Set<String> = ["support", "adjacent", "containment", "holding"]
            if near.contains(qc) && near.contains(ec) { return 0.35 }
            return 0.1
        }
        if queryType.isEmpty { return 0.6 }
        if queryType == edgeType { return 1.0 }
        let pair: Set<String> = [queryType, edgeType]
        if pair.isSubset(of: ["spatial", "possession"]) { return 0.45 }
        if pair.isSubset(of: ["action", "comparison"]) { return 0.30 }
        return 0.08
    }

    // 有方向性的空間關係（directional_class）。below 先判斷，避免「在...下方」被誤判
    static let directionalKeywords: [(String, [String])] = [
        ("below", ["下方", "下面", "底下", "之下", "under", "below"]),
        ("above", ["上方", "上面", "放在", "擺在", "放置於", "位於上", "on top", "above"]),
        ("front", ["前方", "前面", "較靠近鏡頭", "前景"]),
        ("back", ["後方", "後面", "較遠", "背景"]),
    ]
    static let inverse = ["above": "below", "below": "above", "front": "back", "back": "front"]

    static func directionalClass(_ predicate: String) -> String? {
        let text = predicate.lowercased()
        if let c = relationClass(text), c == "containment" || c == "holding" { return nil }
        for (cls, words) in directionalKeywords where words.contains(where: { text.contains($0) }) {
            return cls
        }
        return nil
    }

    /// _edge_score：forward = 邊的方向和查詢一致
    static func edgeScore(queryType: String, queryPred: String, edge: ASRelation, forward: Bool) -> Float {
        let qc = directionalClass(queryPred)
        var ec = directionalClass(edge.predicate)
        if let e = ec, !forward { ec = inverse[e] }
        if let qc, let ec {
            if qc == ec { return 1.0 }
            if inverse[qc] == ec { return ASSearchConfig.opposite }
        }
        var score = relationTypeScore(queryType: queryType, edgeType: edge.relationType,
                                      queryPred: queryPred, edgePred: edge.predicate)
        if !forward && (edge.relationType == "action" || edge.relationType == "possession") {
            score *= ASSearchConfig.reversedActionFactor
        }
        return score
    }
}

// MARK: - 計分

enum ASScoring {
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return vDSP.dot(a, b)
    }

    static func calibrate(_ x: Float, floor: Float) -> Float {
        min(max((x - floor) / (1 - floor), 0), 1)
    }

    /// score_semantic
    static func semantic(_ q: ASQueryIndex, _ im: ASImageIndex, floor: Float) -> Float {
        let whole = calibrate(dot(q.fullVec, im.docVec), floor: floor)
        guard !q.facetVecs.isEmpty else { return whole }
        let facet = q.facetVecs.map { calibrate(dot($0, im.docVec), floor: floor) }.reduce(0, +) / Float(q.facetVecs.count)
        return 0.5 * whole + 0.5 * facet
    }

    /// entity_similarity：查詢實體數 × 照片實體數
    static func entitySimilarity(_ q: ASQueryIndex, _ im: ASImageIndex, floor: Float) -> [[Float]] {
        q.entVecs.map { qv in im.entVecs.map { calibrate(dot(qv, $0), floor: floor) } }
    }

    /// score_entity
    static func entity(_ sim: [[Float]]) -> Float {
        guard !sim.isEmpty, let first = sim.first, !first.isEmpty else { return 0 }
        return sim.map { $0.max() ?? 0 }.reduce(0, +) / Float(sim.count)
    }

    /// score_count：沒有任何查詢實體指定數量時回傳 nil（不啟用）
    static func count(_ q: ASQueryIndex, _ im: ASImageIndex, sim: [[Float]]) -> Float? {
        var scores: [Float] = []
        for (k, e) in q.entities.enumerated() where e.count > 0 {
            let want = e.count
            let observed: Int
            if !e.category.isEmpty {
                observed = zip(im.entCounts, im.entCategories).filter { $0.1 == e.category }.map(\.0).reduce(0, +)
            } else if let row = sim[safe: k], !row.isEmpty, let best = row.indices.max(by: { row[$0] < row[$1] }) {
                observed = im.entCounts[best]
            } else {
                observed = 0
            }
            if observed == 0 {
                scores.append(0)
            } else if want >= ASSearchConfig.groupCount {
                scores.append(min(Float(observed) / Float(want), 1))
            } else {
                scores.append(1 / (1 + Float(abs(observed - want))))
            }
        }
        return scores.isEmpty ? nil : scores.reduce(0, +) / Float(scores.count)
    }

    /// _path_score：2 步以內的所有路徑，找不到回傳 nil
    static func pathScore(_ im: ASImageIndex, from a: String, to b: String, queryType: String, queryPred: String) -> Float? {
        var paths: [[String]] = []
        let na = im.neighbors[a] ?? []
        if na.contains(b) { paths.append([a, b]) }
        for m in na where m != b && (im.neighbors[m]?.contains(b) ?? false) {
            paths.append([a, m, b])
        }
        let queryIsDepth = ASRelationRules.relationClass(queryPred) == "depth"
        var best: Float?
        for path in paths {
            var hops: [Float] = []
            var valid = true
            for i in 0..<(path.count - 1) {
                var datas = im.edgesBetween(path[i], path[i + 1])
                if !queryIsDepth {
                    datas = datas.filter { ASRelationRules.relationClass($0.0.predicate) != "depth" }
                }
                if datas.isEmpty { valid = false; break }
                hops.append(datas.map {
                    ASRelationRules.edgeScore(queryType: queryType, queryPred: queryPred, edge: $0.0, forward: $0.1)
                }.max()!)
            }
            guard valid, !hops.isEmpty else { continue }
            let s = (hops.reduce(0, +) / Float(hops.count)) * pow(ASSearchConfig.hopDecay, Float(path.count - 2))
            best = max(best ?? s, s)
        }
        return best
    }

    /// score_relation：查詢沒有關係時回傳 nil（不啟用）
    static func relation(_ q: ASQueryIndex, _ im: ASImageIndex, sim: [[Float]]) -> Float? {
        guard !q.relations.isEmpty else { return nil }
        guard !im.entIDs.isEmpty else { return 0 }
        let top = ASSearchConfig.relationCandidates
        func candidates(_ row: [Float]) -> [Int] {
            Array(row.indices.sorted { row[$0] > row[$1] }.prefix(top))
        }
        var scores: [Float] = []
        for r in q.relations {
            let sCands = candidates(sim[r.s]), oCands = candidates(sim[r.o])
            var best: Float = 0
            for a in sCands {
                for b in oCands {
                    let anchor = sqrt(sim[r.s][a] * sim[r.o][b])
                    if anchor == 0 { continue }
                    if a == b {
                        // 同一個主體：只有它是多個個體的群組（例如「兩位女生」）才可能成立，但無法驗證
                        if r.s == r.o && im.entCounts[a] >= 2 {
                            best = max(best, anchor * ASSearchConfig.unverified)
                        }
                        continue
                    }
                    let p = pathScore(im, from: im.entIDs[a], to: im.entIDs[b], queryType: r.type, queryPred: r.predicate)
                    best = max(best, anchor * (p ?? ASSearchConfig.unverified))
                }
            }
            scores.append(best)
        }
        return scores.reduce(0, +) / Float(scores.count)
    }

    static func fuse(_ parts: [String: Float]) -> Float {
        let w = ASSearchConfig.weights
        let total = parts.keys.reduce(Float(0)) { $0 + (w[$1] ?? 0) }
        guard total > 0 else { return 0 }
        return parts.reduce(Float(0)) { $0 + (w[$1.key] ?? 0) * $1.value } / total
    }
}

// MARK: - 搜尋（search）

public struct ASSearchResult: Sendable {
    /// PHAsset.localIdentifier
    public let localIdentifier: String
    public let score: Float
    /// 各比對面向的分數，例如 ["semantic": 0.52, "entity": 0.48, "count": 1.0]
    public let channelScores: [String: Float]
    /// 這張照片的整圖描述，方便除錯或顯示「為什麼找到這張」
    public let description: String
}

enum ASHybridSearch {
    static func search(_ q: ASQueryIndex, index: [ASImageIndex], floor: Float) -> [ASSearchResult] {
        var stage1: [(Int, Float)] = []
        var details: [[String: Float]] = []
        var sims: [[[Float]]] = []
        for (i, im) in index.enumerated() {
            var parts: [String: Float] = ["semantic": ASScoring.semantic(q, im, floor: floor)]
            let sim = ASScoring.entitySimilarity(q, im, floor: floor)
            if !q.entities.isEmpty { parts["entity"] = ASScoring.entity(sim) }
            stage1.append((i, ASScoring.fuse(parts)))
            details.append(parts)
            sims.append(sim)
        }

        // 同分時依 id 排序，確保每次結果相同
        let ordered = stage1.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : index[$0.0].id < index[$1.0].id }
        var finalScores = stage1.map { ($0.0, $0.1 - 1) }  // 沒進前 N 名的排在重排結果之後

        for (i, _) in ordered.prefix(ASSearchConfig.rerankTopN) {
            let im = index[i]
            var parts = details[i]
            if let c = ASScoring.count(q, im, sim: sims[i]) { parts["count"] = c }
            if let r = ASScoring.relation(q, im, sim: sims[i]) { parts["relation"] = r }
            if !q.contentType.isEmpty { parts["type"] = im.contentType == q.contentType ? 1 : 0 }
            finalScores[i] = (i, ASScoring.fuse(parts))
            details[i] = parts
        }

        return finalScores
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : index[$0.0].id < index[$1.0].id }
            .map { i, s in
                ASSearchResult(localIdentifier: index[i].id, score: s,
                               channelScores: details[i], description: index[i].docText)
            }
    }
}

fileprivate extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

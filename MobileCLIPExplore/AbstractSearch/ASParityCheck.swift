//
//  ASParityCheck.swift
//  抽象語意搜尋模組（v10）
//
//  確認 Swift 版的搜尋演算法和 PC 版 hybrid_search_v10.py 算出完全相同的分數。
//
//  使用方式：
//    1. 在 PC 上執行 export_parity_fixture.py，產生 parity_fixture.json
//    2. 把 parity_fixture.json 拖進 Xcode 專案（勾選加入 App target）
//    3. 在 App 裡呼叫一次，例如：
//         let url = Bundle.main.url(forResource: "parity_fixture", withExtension: "json")!
//         print(try ASParityCheck.run(fixtureURL: url))
//
//  這個檢查不需要 Apple Intelligence，也不需要相簿權限，模擬器上就能跑。
//  只驗證搜尋演算法本身；建圖與查詢解析由模型決定，兩邊本來就不會一樣。
//

import Foundation

public enum ASParityCheck {
    /// 回傳報告文字；全部一致時第一行是「通過」
    public static func run(fixtureURL: URL, tolerance: Float = 1e-4) throws -> String {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let embedder = LookupEmbedder(table: fixture.vectors, floor: fixture.simFloor)

        let saved = ASSearchConfig.rerankTopN
        ASSearchConfig.rerankTopN = fixture.rerankTopN
        defer { ASSearchConfig.rerankTopN = saved }

        let index = fixture.images.map {
            ASImageIndex(stored: ASStoredImage(path: $0.id, graph: $0.graph, docVec: $0.docVec, entityVecs: $0.entVecs))
        }

        var lines: [String] = []
        var compared = 0, mismatches = 0
        var missingTexts = Set<String>()

        // 先確認文字組合方式一致：Swift 組出來的照片描述，必須是 Python 轉過向量的同一段文字
        for img in fixture.images {
            let doc = ASText.document(img.graph)
            if fixture.vectors[doc] == nil { missingTexts.insert("照片描述 \(img.id)：\(doc)") }
            for e in img.graph.entities where fixture.vectors[ASText.entity(e)] == nil {
                missingTexts.insert("主體描述 \(img.id)/\(e.id)：\(ASText.entity(e))")
            }
        }

        for q in fixture.queries {
            embedder.missing.removeAll()
            let qi: ASQueryIndex
            do {
                qi = try ASQueryIndex(text: q.text, parsed: q.parsed, embedder: embedder)
            } catch {
                lines.append("✗ \(q.text)：建立查詢失敗 \(error)")
                mismatches += 1
                continue
            }
            missingTexts.formUnion(embedder.missing.map { "查詢「\(q.text)」：\($0)" })

            let results = ASHybridSearch.search(qi, index: index, floor: fixture.simFloor)
            var worst: (id: String, diff: Float, detail: String)?
            for r in results {
                guard let exp = q.expected[r.localIdentifier] else { continue }
                compared += 1
                let diff = abs(r.score - exp.score)
                var detail = String(format: "總分 Swift %.5f / Python %.5f", r.score, exp.score)
                let keys = Set(r.channelScores.keys).union(exp.channels.keys).sorted()
                if Set(r.channelScores.keys) != Set(exp.channels.keys) {
                    detail += "；啟用的面向不同 Swift \(r.channelScores.keys.sorted()) / Python \(exp.channels.keys.sorted())"
                }
                for k in keys {
                    let a = r.channelScores[k] ?? -1, b = exp.channels[k] ?? -1
                    if abs(a - b) > tolerance { detail += String(format: "；%@ Swift %.5f / Python %.5f", k, a, b) }
                }
                if diff > tolerance || Set(r.channelScores.keys) != Set(exp.channels.keys) {
                    mismatches += 1
                    if worst == nil || diff > worst!.diff { worst = (r.localIdentifier, diff, detail) }
                }
            }
            if let w = worst {
                lines.append("✗ \(q.text)：\(w.id) \(w.detail)")
            } else {
                lines.append("✓ \(q.text)")
            }
        }

        var header = mismatches == 0 && missingTexts.isEmpty
            ? "通過：\(fixture.queries.count) 條查詢、\(compared) 筆分數與 Python 版一致"
            : "不一致：\(mismatches) 筆分數不同，\(missingTexts.count) 段文字組合方式不同（共比對 \(compared) 筆）"
        if !missingTexts.isEmpty {
            header += "\n文字組合不同（Swift 組出來的文字，Python 沒有這段）：\n"
                + missingTexts.sorted().prefix(10).map { "  - \($0)" }.joined(separator: "\n")
        }
        return ([header, ""] + lines).joined(separator: "\n")
    }

    // MARK: - 測試資料格式

    private struct Fixture: Decodable {
        let simFloor: Float
        let rerankTopN: Int
        let vectors: [String: [Float]]
        let images: [Image]
        let queries: [Query]

        enum CodingKeys: String, CodingKey {
            case vectors, images, queries
            case simFloor = "sim_floor"
            case rerankTopN = "rerank_top_n"
        }
    }

    private struct Image: Decodable {
        let id: String
        let graph: ASSceneGraph
        let docVec: [Float]
        let entVecs: [String: [Float]]

        enum CodingKeys: String, CodingKey {
            case id, graph
            case docVec = "doc_vec"
            case entVecs = "ent_vecs"
        }
    }

    private struct Query: Decodable {
        let id: String
        let text: String
        let parsed: ASParsedQuery
        let expected: [String: Expected]
    }

    private struct Expected: Decodable {
        let score: Float
        let channels: [String: Float]
    }

    /// 用查表代替真正的模型，確保兩邊用的向量完全相同
    private final class LookupEmbedder: ASTextEmbedding, @unchecked Sendable {
        let table: [String: [Float]]
        var simFloor: Float
        var missing: [String] = []
        init(table: [String: [Float]], floor: Float) {
            self.table = table
            simFloor = floor
        }
        var modelName: String { "parity-lookup" }
        var dimension: Int { table.values.first?.count ?? 0 }
        func prepare() async throws {}
        func embed(_ texts: [String]) throws -> [[Float]] {
            texts.map { t in
                if let v = table[t] { return v }
                missing.append(t)
                return [Float](repeating: 0, count: dimension)
            }
        }
    }
}

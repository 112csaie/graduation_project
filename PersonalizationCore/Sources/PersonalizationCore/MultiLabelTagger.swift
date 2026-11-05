// MultiLabelTagger.swift
//
// 以「既有照片向量 × 分類文字向量」做多標籤比對。
//
// 重要說明（避免誇大模型能力）：
// - 這裡只使用 MobileCLIP-S2 的零樣本向量相似度，等同於「這張照片像不像『a photo of X』」。
// - 它不具備情境理解能力：無法知道照片是不是「簽名會」、「情侶合照」這類情境或關係。
//   這類分類在目錄中被標記為 assisted / derived / manualOnly，最多只會成為「待確認」候選。
// - 門檻值沿用專案既有的實測數字：
//     * 0.21 —— DatabaseManager 既有單一分類門檻（classificationThreshold），作為「候選」下限。
//     * 0.25 —— Classification/app_ph.py 實驗使用的 THRESHOLD，作為「自動確認」下限。
//   專案中沒有標註過的驗證資料集，因此這些門檻是保守的初始值，應依實際標註結果再調整。

import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

struct TaggingThresholds: Equatable {
    /// 沒有設定偏好時，自動確認的最低相似度（沿用 app_ph.py 實驗的 0.25）。
    var acceptScore: Float = 0.25
    /// 使用者選取的大分類、或興趣相關的細分類：門檻降低（更容易歸進你在意的分類）。
    var preferredAcceptBonus: Float = 0.01
    /// 使用者沒有選取的大分類：門檻提高（仍會辨識，但只收很有把握的結果，減少不相關的誤判）。
    var unpreferredAcceptPenalty: Float = 0.03
    /// 自動確認的標籤必須與最高分相差不超過此值，避免把「明顯較弱」的標籤也視為確定。
    var acceptMarginFromBest: Float = 0.03
    /// 每張照片最多自動確認的 tag 數。
    var maxAccepted: Int = 3
    /// 每張照片最多 1 個「待確認」：只保留模型真的無法自行判斷、需要使用者回答的問題。
    var maxCandidates: Int = 1
    /// 排除規則的容許差距：混淆節點的分數只要不低於「本節點 − 此值」就排除。
    var suppressMargin: Float = 0.01
    /// 一眼就看得出來的分類（貓、狗…）可以比最高分低這麼多：照片裡同時有沙發、咖啡廳時，貓狗常不是最高分。
    var distinctMarginFromBest: Float = 0.06

    /// 預設值套用桌面「相簿主題設定」資料夾的全域門檻調整（沒有調整時就是上面的數值）
    static let `default` = TaxonomyTuning.current.apply(to: TaggingThresholds())
}

enum TagStatus: String, Codable, CaseIterable {
    case accepted
    case candidate
    case rejected
}

enum TagSource: String, Codable, CaseIterable {
    case auto
    case manual
}

struct TagSuggestion: Equatable {
    let nodeId: String
    let score: Float
    let status: TagStatus   // 只會是 accepted 或 candidate
}

struct MultiLabelTagger {

    /// 標記器版本：目錄或門檻改變時遞增，App 會用既有照片向量重新比對（不會重算照片向量）。
    /// 動物種類：一張照片只標最像的一種。MobileCLIP 看到狗時「貓」的分數也常常很接近，
    /// 以前兩個都標上；真的同時拍到貓和狗的照片很少，寧可少標一個。
    static let animalSpecies: Set<String> = ["cat", "dog", "rabbit", "small_pet", "reptile", "bird"]

    static func version(catalog: TaxonomyCatalog, thresholds: TaggingThresholds = .default) -> String {
        "mlt-3/catalog-\(catalog.catalogVersion)/a\(thresholds.acceptScore)-p\(thresholds.preferredAcceptBonus)-u\(thresholds.unpreferredAcceptPenalty)"
            + (catalog.tuningSignature.isEmpty ? "" : "/t-\(catalog.tuningSignature)")
            + (LearnedTagClassifiers.signature.isEmpty ? "" : "/c-\(LearnedTagClassifiers.signature)")
    }

    let catalog: TaxonomyCatalog
    let thresholds: TaggingThresholds
    /// nodeId → 該節點所有 prompt 的（已正規化）文字向量。
    let promptEmbeddings: [String: [[Float]]]
    /// 所有文字向量排成的矩陣：一張照片和全部描述的相似度一次算完。
    let matrix: PromptMatrix
    /// 可以用畫面比對的節點（visual / assisted，而且有文字向量），事先挑好，不必每張照片重算。
    private let scorableNodes: [TaxonomyNode]
    private let derivedNodes: [TaxonomyNode]
    private let topLevelById: [String: String]
    /// 用標記資料訓練過的判斷器（見 LearnedTagClassifiers）：有的分類改用它判斷，沒有的照舊用文字描述比對
    let classifiers: [String: LearnedTagClassifier]

    init(catalog: TaxonomyCatalog, promptEmbeddings: [String: [[Float]]], thresholds: TaggingThresholds = .default,
         classifiers: [String: LearnedTagClassifier] = LearnedTagClassifiers.all) {
        self.catalog = catalog
        self.classifiers = classifiers
        self.promptEmbeddings = promptEmbeddings
        self.thresholds = thresholds
        let matrix = PromptMatrix(promptEmbeddings)
        self.matrix = matrix
        let taggable = catalog.taggableNodes
        self.scorableNodes = taggable.filter {
            ($0.recognition == .visual || $0.recognition == .assisted) && matrix.rowsByKey[$0.id] != nil
        }
        self.derivedNodes = taggable.filter { $0.recognition == .derived && !$0.requiresAnyOf.isEmpty }
        var tops: [String: String] = [:]
        for node in taggable { tops[node.id] = catalog.topLevelId(of: node.id) }
        self.topLevelById = tops
    }

    /// 是否已經有足夠的文字向量可以做比對。
    var isReady: Bool { !promptEmbeddings.isEmpty }

    /// 對一張照片（已正規化的向量）產生多個 tag 建議。
    ///
    /// 規則（v2）：
    /// - 已確認：可由畫面直接判斷的分類（visual），分數達門檻且接近最高分，最多 3 個。
    ///   門檻依偏好調整：你選的大分類／興趣相關細分類 0.24、沒選的 0.28、沒有任何偏好 0.25。
    /// - 待確認（每張最多 1 個）：只在模型「看得到但無法確定情境」時才問使用者——
    ///   (1) 情境類分類（演唱會、主題咖啡廳…）分數 ≥ 0.25，且屬於你在意的分類；
    ///   (2) 組合情境（旅行合照…）的組成 tag 都已確認，且屬於你在意的分類。
    ///   分數不夠的一般分類直接略過，不再丟給使用者確認。
    /// - Parameters:
    ///   - preferredTopLevelIds: 使用者選取的大分類。
    ///   - boostedNodeIds: 使用者興趣相關的細分類。兩者皆空代表沒有偏好。
    func suggestTags(for imageEmbedding: [Float],
                     preferredTopLevelIds: Set<String> = [],
                     boostedNodeIds: Set<String> = []) -> [TagSuggestion] {
        guard !imageEmbedding.isEmpty else { return [] }
        let hasPreferences = !preferredTopLevelIds.isEmpty || !boostedNodeIds.isEmpty

        func isPreferred(_ node: TaxonomyNode) -> Bool {
            guard hasPreferences else { return true }
            if boostedNodeIds.contains(node.id) { return true }
            return topLevelById[node.id].map { preferredTopLevelIds.contains($0) } ?? false
        }

        /// 這個分類的基本門檻：有自己的門檻（主題設定資料夾）就用自己的，否則用全域門檻
        func baseThreshold(_ node: TaxonomyNode) -> Float { node.acceptScore ?? thresholds.acceptScore }

        func acceptThreshold(_ node: TaxonomyNode) -> Float {
            let base = baseThreshold(node)
            guard hasPreferences else { return base }
            return isPreferred(node)
                ? base - thresholds.preferredAcceptBonus
                : base + thresholds.unpreferredAcceptPenalty
        }

        // 1. 視覺比對：每個節點取所有 prompt 的最高相似度（全部描述一次矩陣運算算完）。
        guard let rowScores = matrix.scores(for: imageEmbedding) else { return [] }
        var scored: [(node: TaxonomyNode, score: Float)] = []
        scored.reserveCapacity(scorableNodes.count)
        for node in scorableNodes {
            if let best = matrix.best(node.id, in: rowScores) { scored.append((node, best)) }
        }
        scored.sort { $0.score > $1.score }
        guard let bestScore = scored.first?.score else { return [] }

        var accepted: [TagSuggestion] = []
        var question: TagSuggestion?
        let scoreById = Dictionary(scored.map { ($0.node.id, $0.score) }, uniquingKeysWith: max)

        /// 排除規則：
        /// - 容易混淆的節點（例如聊天截圖之於漫畫截圖）一樣像或更像時，不自動確認；
        /// - 照片比較像「容易被誤認的畫面」（例如單腳站著擺姿勢之於跑步）時，也不算。
        func isSuppressed(_ node: TaxonomyNode, score: Float) -> Bool {
            if node.suppressedBy.contains(where: { (scoreById[$0] ?? -1) >= score - thresholds.suppressMargin }) { return true }
            return confuserScore(node, rowScores) >= score - thresholds.suppressMargin
        }

        // 0. 有訓練過判斷器的分類：機率 ≥ 標上門檻 → 標上；< 拿掉門檻 → 一定不是，不標；
        //    介於兩者之間 → 照舊用下面的文字描述比對（判斷器沒把握時不會因此少標）
        //    要照片文字佐證的分類（收據、票根）：用你標記的照片訓練過、判斷器很確定時也直接標上；
        //    沒把握時照舊要等照片文字（見 PhotoTextHints.combine）
        var learned: [(suggestion: TagSuggestion, probability: Float)] = []
        var decidedByClassifier = Set<String>()
        for item in scored where item.node.recognition == .visual {
            guard let classifier = classifiers[item.node.id],
                  let probability = classifier.probability(imageEmbedding) else { continue }
            if probability >= classifier.threshold || probability < classifier.rejectBelow {
                decidedByClassifier.insert(item.node.id)
            }
            if probability >= classifier.threshold {
                learned.append((TagSuggestion(nodeId: item.node.id, score: item.score, status: .accepted), probability))
            }
        }
        learned.sort { $0.probability > $1.probability }
        for entry in learned where accepted.count < thresholds.maxAccepted {
            if Self.animalSpecies.contains(entry.suggestion.nodeId)
                && accepted.contains(where: { Self.animalSpecies.contains($0.nodeId) }) { continue }
            accepted.append(entry.suggestion)
        }

        for item in scored {
            // 要有照片文字佐證的分類（收據發票）：畫面像只用來觸發文字辨識，不在這裡標上（見 PhotoTextHints.combine）
            if item.node.requiresText { continue }
            // 判斷器已經決定的分類（很確定是、或一定不是）不再用文字描述比對
            if decidedByClassifier.contains(item.node.id) { continue }
            if item.node.recognition == .visual {
                // 一眼就看得出來的分類（貓、狗…）：不因為沒選那個大分類而提高門檻，也容許比最高分低一些
                let threshold = item.node.distinct
                    ? min(acceptThreshold(item.node), baseThreshold(item.node) - thresholds.preferredAcceptBonus)
                    : acceptThreshold(item.node)
                let margin = item.node.distinct ? thresholds.distinctMarginFromBest : thresholds.acceptMarginFromBest
                if accepted.count < thresholds.maxAccepted,
                   !isSuppressed(item.node, score: item.score),
                   // 動物種類只標最像的一種（分數由高到低處理，先標上的就是最像的）：狗的照片不會同時變成貓、兔子
                   !(Self.animalSpecies.contains(item.node.id) && accepted.contains { Self.animalSpecies.contains($0.nodeId) }),
                   item.score >= threshold,
                   bestScore - item.score <= margin {
                    accepted.append(TagSuggestion(nodeId: item.node.id, score: item.score, status: .accepted))
                }
            } else if item.node.recognition == .assisted,
                      question == nil,
                      thresholds.maxCandidates > 0,
                      item.score >= baseThreshold(item.node),
                      isPreferred(item.node),
                      !isSuppressed(item.node, score: item.score) {
                // 看得到相關畫面（舞台、燈光…），但無法確定情境 → 問使用者
                question = TagSuggestion(nodeId: item.node.id, score: item.score, status: .candidate)
            }
        }

        // 2. 組合情境：組成 tag 全部「已確認」才推論，例如 合照 + 地標 → 旅行合照（待確認）。
        if question == nil, thresholds.maxCandidates > 0 {
            let present = Dictionary(accepted.map { ($0.nodeId, $0.score) }, uniquingKeysWith: max)
            for node in derivedNodes where isPreferred(node) {
                let groupScores = node.requiresAnyOf.map { group in group.compactMap { present[$0] }.max() }
                if groupScores.allSatisfy({ $0 != nil }), let minScore = groupScores.compactMap({ $0 }).min() {
                    question = TagSuggestion(nodeId: node.id, score: minScore, status: .candidate)
                    break
                }
            }
        }

        return accepted + (question.map { [$0] } ?? [])
    }

    /// 照片與這個節點「容易被誤認的畫面」最高的相似度；沒有設定時為 -1。
    private func confuserScore(_ node: TaxonomyNode, _ rowScores: [Float]) -> Float {
        matrix.best(TaxonomyNode.confuserKey(node.id), in: rowScores) ?? -1
    }

    /// 一個分類和這張照片的相似度（這個分類所有描述取最高）。標記模式挑「最需要人判斷」的照片時用。
    func nodeScore(_ nodeId: String, for imageEmbedding: [Float]) -> Float? {
        guard let prompts = promptEmbeddings[nodeId], !prompts.isEmpty else { return nil }
        return prompts.map { Self.dot($0, imageEmbedding) }.max()
    }

    /// 這個分類目前用的自動確認門檻（沒有偏好時）
    func defaultAcceptScore(for nodeId: String) -> Float {
        catalog.node(nodeId)?.acceptScore ?? thresholds.acceptScore
    }

    /// 向量都已 L2 正規化，因此點積 = cosine similarity（與 DatabaseManager.cosineSimilarity 一致）。
    /// 照片「最像」的幾個分類（不論是否達到確認門檻），給回憶草稿當作畫面線索；只回傳和最高分相近的。
    func topGuesses(for imageEmbedding: [Float], limit: Int = 3,
                    minScore: Float = 0.18, marginFromBest: Float = 0.03) -> [(nodeId: String, score: Float)] {
        guard !imageEmbedding.isEmpty, limit > 0, let rowScores = matrix.scores(for: imageEmbedding) else { return [] }
        var scored: [(nodeId: String, score: Float)] = []
        for node in scorableNodes {
            guard let best = matrix.best(node.id, in: rowScores) else { continue }
            // 比較像容易誤認的畫面時，不當成線索
            guard confuserScore(node, rowScores) < best - thresholds.suppressMargin else { continue }
            scored.append((node.id, best))
        }
        scored.sort { $0.score > $1.score }
        guard let top = scored.first?.score, top >= minScore else { return [] }
        return Array(scored.prefix { $0.score >= max(minScore, top - marginFromBest) }.prefix(limit))
    }

    /// 照片看起來像一張有字的紙或卡片（最像的幾個分類裡有票根、收據、證件、菜單、文件…）。
    /// 這類照片才自動辨識文字，由文字決定是哪一種。
    func looksLikePaper(_ imageEmbedding: [Float], paperNodeIds: Set<String> = PhotoTextHints.paperLikeNodeIds) -> Bool {
        topGuesses(for: imageEmbedding, limit: 3, minScore: 0.2, marginFromBest: 0.03)
            .contains { paperNodeIds.contains($0.nodeId) }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        #if canImport(Accelerate)
        var sum: Float = 0
        vDSP_dotpr(a, 1, b, 1, &sum, vDSP_Length(a.count))
        return sum
        #else
        var sum: Float = 0
        for index in 0..<a.count {
            sum += a[index] * b[index]
        }
        return sum
        #endif
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return vector }
        return vector.map { $0 / length }
    }
}

// MARK: - 從使用者的回答學習

/// 使用者回答過的照片當作每個分類的範例：按「是」／手動加入 = 正例，按「不是」／移除 = 反例。
/// 和「我的 IP」相同的照片 × 照片比對（ReferenceMatcher），只是套用在一般分類上：
/// - 和某張反例很像（例如同一場畢業典禮的其他照片）、而且比任何正例都更像 → 不放進那個分類
/// - 和正例非常像（例如你家同一隻貓）、而且比反例更像 → 直接放進那個分類
/// 只用既有照片向量，不重算；每個分類各自累積，用得越多越準。
struct TagFeedbackThresholds: Equatable {
    /// 與某一張正例的相似度達此值 → 加入（幾乎是同一個東西、同一個場景）
    var acceptTop1: Float = 0.86
    /// 與最像的兩張正例平均達此值 → 加入（和多張範例都很像）
    var acceptTop2Mean: Float = 0.82
    /// 與某一張反例的相似度達此值 → 拿掉
    var rejectTop1: Float = 0.84
    /// 正例、反例要分得出高下：差距小於此值時不動
    var margin: Float = 0.02
    /// 每個分類最多用幾張範例（最近回答的優先）
    var maxExamplesPerNode: Int = 200

    static let `default` = TagFeedbackThresholds()
}

struct TagFeedback {
    let thresholds: TagFeedbackThresholds
    private let matrix: PromptMatrix
    private let positiveNodes: [String]
    private let negativeNodes: [String]

    static func positiveKey(_ nodeId: String) -> String { "+" + nodeId }
    static func negativeKey(_ nodeId: String) -> String { "-" + nodeId }

    /// - Parameters:
    ///   - positives / negatives: 節點 → 範例照片向量（已 L2 正規化），最近的在前
    init(positives: [String: [[Float]]], negatives: [String: [[Float]]],
         thresholds: TagFeedbackThresholds = .default) {
        self.thresholds = thresholds
        var rows: [String: [[Float]]] = [:]
        for (node, vectors) in positives where !vectors.isEmpty {
            rows[Self.positiveKey(node)] = Array(vectors.prefix(thresholds.maxExamplesPerNode))
        }
        for (node, vectors) in negatives where !vectors.isEmpty {
            rows[Self.negativeKey(node)] = Array(vectors.prefix(thresholds.maxExamplesPerNode))
        }
        matrix = PromptMatrix(rows)
        positiveNodes = positives.filter { !$0.value.isEmpty }.keys.sorted()
        negativeNodes = negatives.filter { !$0.value.isEmpty }.keys.sorted()
    }

    var isEmpty: Bool { matrix.rowCount == 0 }

    /// 依使用者的回答調整這張照片的自動結果（手動標籤由資料庫另外保護，不受影響）。
    func apply(_ suggestions: [TagSuggestion], imageEmbedding: [Float]) -> [TagSuggestion] {
        guard !isEmpty, let scores = matrix.scores(for: imageEmbedding) else { return suggestions }
        var result = suggestions

        func top2(_ key: String) -> (best: Float, second: Float, count: Int) {
            guard let range = matrix.rowsByKey[key] else { return (-1, -1, 0) }
            var best: Float = -1, second: Float = -1
            for index in range {
                let value = scores[index]
                if value > best { second = best; best = value } else if value > second { second = value }
            }
            return (best, second, range.count)
        }

        // 1. 很像使用者說過「不是」的照片 → 拿掉
        for node in negativeNodes {
            let negative = top2(Self.negativeKey(node)).best
            let positive = top2(Self.positiveKey(node)).best
            if negative >= thresholds.rejectTop1, negative > positive + thresholds.margin {
                result.removeAll { $0.nodeId == node }
            }
        }

        // 2. 很像使用者說過「是」的照片 → 加入（或把待確認改成確認）
        for node in positiveNodes {
            let positive = top2(Self.positiveKey(node))
            let negative = top2(Self.negativeKey(node)).best
            let mean = positive.count >= 2 ? (positive.best + positive.second) / 2 : positive.best
            guard positive.best >= thresholds.acceptTop1 || (positive.count >= 2 && mean >= thresholds.acceptTop2Mean),
                  positive.best > negative + thresholds.margin else { continue }
            if let index = result.firstIndex(where: { $0.nodeId == node }) {
                result[index] = TagSuggestion(nodeId: node, score: max(result[index].score, positive.best), status: .accepted)
            } else {
                result.append(TagSuggestion(nodeId: node, score: positive.best, status: .accepted))
            }
        }
        return result
    }
}

// MARK: - 文字向量矩陣

/// 所有文字向量排成一個矩陣（每列一句描述），一張照片和全部描述的相似度用一次矩陣乘法算完。
/// 比逐句計算快很多：重新分類上萬張照片時差別最明顯。結果和逐句點積相同。
struct PromptMatrix {
    /// 向量長度（以最常見的長度為準；長度不同的向量不納入）
    let dimension: Int
    let rowCount: Int
    /// key（節點 ID，或「節點ID#not」）→ 在矩陣中的列
    let rowsByKey: [String: Range<Int>]
    private let values: [Float]   // rowCount × dimension，逐列排列

    init(_ embeddings: [String: [[Float]]]) {
        var lengthCounts: [Int: Int] = [:]
        for vectors in embeddings.values {
            for vector in vectors where !vector.isEmpty { lengthCounts[vector.count, default: 0] += 1 }
        }
        let dimension = lengthCounts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 0
        var values: [Float] = []
        var rows: [String: Range<Int>] = [:]
        var count = 0
        for key in embeddings.keys.sorted() {
            let vectors = (embeddings[key] ?? []).filter { $0.count == dimension }
            guard !vectors.isEmpty else { continue }
            rows[key] = count..<(count + vectors.count)
            for vector in vectors { values.append(contentsOf: vector) }
            count += vectors.count
        }
        self.dimension = dimension
        self.rowCount = count
        self.rowsByKey = rows
        self.values = values
    }

    /// 每一列與照片向量的相似度（點積）；照片向量長度不符時回傳 nil。
    func scores(for image: [Float]) -> [Float]? {
        guard dimension > 0, rowCount > 0, image.count == dimension else { return nil }
        var output = [Float](repeating: 0, count: rowCount)
        #if canImport(Accelerate)
        vDSP_mmul(values, 1, image, 1, &output, 1, vDSP_Length(rowCount), 1, vDSP_Length(dimension))
        #else
        for row in 0..<rowCount {
            var sum: Float = 0
            let base = row * dimension
            for index in 0..<dimension { sum += values[base + index] * image[index] }
            output[row] = sum
        }
        #endif
        return output
    }

    /// 這個 key 所有列中最高的相似度；沒有這個 key 時回傳 nil。
    func best(_ key: String, in scores: [Float]) -> Float? {
        guard let range = rowsByKey[key], !range.isEmpty, range.upperBound <= scores.count else { return nil }
        var best = -Float.greatestFiniteMagnitude
        for index in range where scores[index] > best { best = scores[index] }
        return best
    }
}

// MARK: - 向量 <-> BLOB

enum EmbeddingCodec {
    /// 與既有 PhotoFeatures.image_embedding 相同的格式：連續的 Float32（本機位元組序）。
    static func encode(_ vector: [Float]) -> [UInt8] {
        vector.withUnsafeBufferPointer { buffer in
            Array(UnsafeRawBufferPointer(buffer))
        }
    }

    static func decode(_ bytes: [UInt8]) -> [Float] {
        let count = bytes.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        result.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<(count * MemoryLayout<Float>.size)]))
            }
        }
        return result
    }
}

// MARK: - 訓練過的分類判斷器

/// 一個分類的判斷器：用組員標記的照片（是／不是）在 Mac 上訓練的邏輯斯迴歸（見 Scripts/train_tag_classifiers.py）。
/// 輸入是 App 已經算好的照片向量，不重新分析照片；機率 ≥ threshold 就標上。
struct LearnedTagClassifier: Equatable {
    let nodeId: String
    let weights: [Float]
    let bias: Float
    /// 標上的機率門檻（訓練時依驗證資料選，讓準確率達到目標）
    let threshold: Float
    /// 拿掉的門檻：機率低於它就一定不是（訓練時選，保留 95% 的「是」）。介於兩者之間交給文字描述比對
    var rejectBelow: Float = 0

    var dimension: Int { weights.count }

    func probability(_ imageEmbedding: [Float]) -> Float? {
        guard imageEmbedding.count == weights.count, !weights.isEmpty else { return nil }
        let z = MultiLabelTagger.dot(weights, imageEmbedding) + bias
        return 1 / (1 + exp(-z))
    }
}

enum LearnedTagClassifiers {
    /// 內建的判斷器（TagClassifierData.swift，由訓練腳本產生）
    static let all: [String: LearnedTagClassifier] = parse(TagClassifierData.json)
    /// 判斷器版本：改變時 App 會用既有照片向量重新分類
    static var signature: String { all.isEmpty ? "" : TagClassifierData.version }

    /// {"classifiers": {"photocard": {"w": "<base64 Float32>", "b": -1.2, "t": 0.7, "r": 0.1}, ...}}
    static func parse(_ json: String) -> [String: LearnedTagClassifier] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["classifiers"] as? [String: Any] else { return [:] }
        var result: [String: LearnedTagClassifier] = [:]
        for (nodeId, value) in items {
            guard let item = value as? [String: Any],
                  let encoded = item["w"] as? String, let raw = Data(base64Encoded: encoded),
                  let bias = (item["b"] as? NSNumber)?.floatValue,
                  let threshold = (item["t"] as? NSNumber)?.floatValue else { continue }
            let weights = EmbeddingCodec.decode([UInt8](raw))
            guard !weights.isEmpty else { continue }
            let reject = min((item["r"] as? NSNumber)?.floatValue ?? 0, threshold)
            result[nodeId] = LearnedTagClassifier(nodeId: nodeId, weights: weights, bias: bias, threshold: threshold,
                                                  rejectBelow: reject)
        }
        return result
    }
}

// MARK: - 匯出標記資料（給組員一起訓練判斷器）

/// 一筆回答：這張照片是不是這個分類
struct TrainingLabel: Equatable {
    let assetId: String
    let nodeId: String
    let isPositive: Bool
    /// 照片向量（已正規化）
    let embedding: [Float]
}

/// 匯出檔（JSON）。只有照片向量（512 個數字）和答案，不含照片；照片 ID 也換成雜湊，看不出是哪張照片。
/// {"format": "selfie-labels-1", "contributor": "邱庭俞", "catalogVersion": 17, "dimension": 512, "exportedAt": "...",
///  "items": [{"id": "a1b2…", "node": "photocard", "label": 1, "e": "<base64 Float32>"}]}
enum TrainingLabelExport {
    static let format = "selfie-labels-1"

    static func make(_ labels: [TrainingLabel], contributor: String, catalogVersion: Int, now: Date = Date()) throws -> Data {
        let iso = ISO8601DateFormatter()
        let items: [[String: Any]] = labels.map { label in
            ["id": hashedId(label.assetId), "node": label.nodeId, "label": label.isPositive ? 1 : 0,
             "e": Data(EmbeddingCodec.encode(label.embedding)).base64EncodedString()]
        }
        let root: [String: Any] = [
            "format": format,
            "contributor": contributor,
            "catalogVersion": catalogVersion,
            "dimension": labels.first?.embedding.count ?? 0,
            "exportedAt": iso.string(from: now),
            "items": items,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// 照片 ID 的雜湊（FNV-1a 64 位元，兩次不同種子）：同一張照片每次匯出都一樣，用來去除重複；看不出原本的 ID
    static func hashedId(_ assetId: String) -> String {
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash: UInt64 = 0xcbf29ce484222325 ^ seed
            for byte in assetId.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
            return hash
        }
        return String(format: "%016llx%016llx", fnv(0), fnv(0x9e3779b97f4a7c15))
    }
}

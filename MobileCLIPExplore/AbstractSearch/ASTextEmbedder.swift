//
//  ASTextEmbedder.swift
//  抽象語意搜尋模組（v10）
//
//  文字向量，取代 PC 版的 multilingual-e5-small。
//  NLContextualEmbedding 輸出的是每個 token 的向量，這裡取平均（mean pooling）
//  再做 L2 正規化，之後兩個向量的內積就等於 cosine 相似度。
//
//  若之後要換成其他模型（例如把 e5 轉成 Core ML），只要另外實作 ASTextEmbedding 協定即可。
//

import Foundation
import NaturalLanguage

public protocol ASTextEmbedding: AnyObject, Sendable {
    /// 存進資料庫時用來區分不同模型的向量
    var modelName: String { get }
    var dimension: Int { get }
    /// 「完全不相關」的兩段文字通常拿到的 cosine。用來把相似度校正到 0～1（對應 PC 版的 sim_floor）
    var simFloor: Float { get set }
    /// 下載並載入模型資產；第一次使用前呼叫
    func prepare() async throws
    /// 回傳已經 L2 正規化的向量
    func embed(_ texts: [String]) throws -> [[Float]]
}

public enum ASEmbeddingError: Error, LocalizedError {
    case modelNotFound
    case assetsUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound: return "找不到支援繁體中文的 NLContextualEmbedding 模型"
        case .assetsUnavailable(let s): return "文字向量模型資產無法使用：\(s)"
        }
    }
}

public final class ASContextualEmbedder: ASTextEmbedding, @unchecked Sendable {
    private let embedding: NLContextualEmbedding
    private let language: NLLanguage
    private let lock = NSLock()
    private var floor: Float

    /// - Parameter simFloor: 尚未校正前的預設值。建好至少 50 張照片後，
    ///   ASAbstractSearchService 會自動用資料庫裡的照片描述校正一次。
    public init(simFloor: Float = 0.5) throws {
        if let e = NLContextualEmbedding(language: .traditionalChinese) {
            embedding = e
            language = .traditionalChinese
        } else if let e = NLContextualEmbedding(script: .traditionalChinese) {
            embedding = e
            language = .traditionalChinese
        } else if let e = NLContextualEmbedding(language: .simplifiedChinese) {
            embedding = e
            language = .simplifiedChinese
        } else {
            throw ASEmbeddingError.modelNotFound
        }
        floor = simFloor
    }

    public var modelName: String { "NLContextualEmbedding:\(embedding.modelIdentifier)" }
    public var dimension: Int { embedding.dimension }

    public var simFloor: Float {
        get { lock.withLock { floor } }
        set { lock.withLock { floor = newValue } }
    }

    public func prepare() async throws {
        if !embedding.hasAvailableAssets {
            let result: NLContextualEmbedding.AssetsResult = try await withCheckedThrowingContinuation { cont in
                embedding.requestAssets { result, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: result)
                    }
                }
            }
            guard result == .available else {
                throw ASEmbeddingError.assetsUnavailable(String(describing: result))
            }
        }
        try lock.withLock { try embedding.load() }
    }

    public func embed(_ texts: [String]) throws -> [[Float]] {
        try lock.withLock {
            try texts.map { try embedOne($0) }
        }
    }

    private func embedOne(_ raw: String) throws -> [Float] {
        let dim = embedding.dimension
        // 中文大約一個字一個 token；保守截斷，避免超過模型的最大長度
        let limit = max(16, embedding.maximumSequenceLength - 8)
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        guard !text.isEmpty else { return [Float](repeating: 0, count: dim) }

        let result = try embedding.embeddingResult(for: text, language: language)
        var sum = [Double](repeating: 0, count: dim)
        var n = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<min(dim, vector.count) { sum[i] += vector[i] }
            n += 1
            return true
        }
        guard n > 0 else { return [Float](repeating: 0, count: dim) }
        var v = sum.map { Float($0 / Double(n)) }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }
}

// ConversationService.swift
//
// 最近的對話：Agent 頁的聊天紀錄存在手機（PhotoAI.sqlite 的 AgentConversations／AgentMessages 表）。
// 照片只存識別碼，接著聊時再從相簿讀出縮圖；不複製、不修改照片。

import Foundation
import Photos
import UIKit

final class ConversationService {
    static let shared = ConversationService()
    private let queue = DispatchQueue(label: "com.photoai.conversations", qos: .utility)

    private init() {}

    private func context() -> (store: PersonalizationStore, userId: String)? {
        guard let store = DatabaseManager.shared.personalization,
              let userId = LocalUserSession.currentUserId, !userId.isEmpty else { return nil }
        return (store, userId)
    }

    /// 在背景儲存整段對話（每次有新訊息時呼叫）
    func save(conversationId: String, messages: [StoredChatMessage]) {
        guard !messages.isEmpty, let ctx = context() else { return }
        queue.async {
            try? ctx.store.saveConversation(userId: ctx.userId, conversationId: conversationId, messages: messages)
        }
    }

    func list() async -> [ConversationSummary] {
        guard let ctx = context() else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (try? ctx.store.conversations(userId: ctx.userId)) ?? [])
            }
        }
    }

    func messages(conversationId: String) async -> [StoredChatMessage] {
        guard let ctx = context() else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (try? ctx.store.conversationMessages(userId: ctx.userId,
                                                                                    conversationId: conversationId)) ?? [])
            }
        }
    }

    func delete(conversationId: String) {
        guard let ctx = context() else { return }
        queue.async { try? ctx.store.deleteConversation(userId: ctx.userId, conversationId: conversationId) }
    }

    /// 從相簿讀出對話中的照片（照片已被刪除時略過）
    static func loadImages(assetIds: [String]) async -> [UIImage] {
        var images: [UIImage] = []
        for id in assetIds {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { continue }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            let image: UIImage? = await withCheckedContinuation { continuation in
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1200, height: 1200),
                                                      contentMode: .aspectFit, options: options) { image, _ in
                    continuation.resume(returning: image)
                }
            }
            if let image { images.append(image) }
        }
        return images
    }
}

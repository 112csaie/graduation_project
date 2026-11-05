// ConversationStore.swift
//
// 最近的對話（migration v9 的 AgentConversations／AgentMessages 表）：Agent 頁的聊天紀錄存在手機，
// 關掉 App 後可以從「最近的對話」接著聊。照片只存識別碼，不複製照片。
//
// 本檔案只依賴 Foundation 與 SQLite.swift，可在 macOS 用 swift test 驗證。

import Foundation
import SQLite

struct StoredChatMessage: Equatable {
    let isUser: Bool
    let text: String
    let bubbleText: String?
    let quotedTopic: String?
    /// 相簿照片的識別碼（可以重新讀出照片）
    let assetIds: [String]
    /// 這則訊息附的圖片張數（含沒有識別碼、無法重新讀出的圖片）
    let imageCount: Int
}

struct ConversationSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
    let messageCount: Int
    let updatedAt: String?
}

extension PersonalizationStore {

    /// 最多保留幾段對話（較舊的自動刪除）
    static let maxConversations = 50

    /// 用整段訊息覆寫一段對話（新的對話會建立）。標題取第一則使用者訊息。
    func saveConversation(userId: String, conversationId: String, messages: [StoredChatMessage]) throws {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        guard !messages.isEmpty else { return }
        let firstUser = messages.first { $0.isUser }
        let titleSource = (firstUser?.bubbleText ?? firstUser?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleSource.isEmpty ? (firstUser?.imageCount ?? 0 > 0 ? "（照片）" : "對話") : String(titleSource.prefix(40))
        try write {
            try exec("""
            INSERT INTO AgentConversations (user_id, conversation_id, title) VALUES (?, ?, ?)
            ON CONFLICT(user_id, conversation_id) DO UPDATE SET title = excluded.title, updated_at = CURRENT_TIMESTAMP
            """, userId, conversationId, title)
            try exec("DELETE FROM AgentMessages WHERE user_id = ? AND conversation_id = ?", userId, conversationId)
            for (seq, message) in messages.enumerated() {
                let ids = (try? JSONEncoder().encode(message.assetIds)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try exec("""
                INSERT INTO AgentMessages
                    (user_id, conversation_id, seq, is_user, text, bubble_text, quoted_topic, asset_ids, image_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, userId, conversationId, Int64(seq), Int64(message.isUser ? 1 : 0), message.text,
                     message.bubbleText, message.quotedTopic, ids, Int64(message.imageCount))
            }
            // 只保留最近的對話
            try exec("""
            DELETE FROM AgentMessages WHERE user_id = ? AND conversation_id IN (
                SELECT conversation_id FROM AgentConversations WHERE user_id = ?
                ORDER BY updated_at DESC, rowid DESC LIMIT -1 OFFSET ?)
            """, userId, userId, Int64(Self.maxConversations))
            try exec("""
            DELETE FROM AgentConversations WHERE user_id = ? AND conversation_id IN (
                SELECT conversation_id FROM AgentConversations WHERE user_id = ?
                ORDER BY updated_at DESC, rowid DESC LIMIT -1 OFFSET ?)
            """, userId, userId, Int64(Self.maxConversations))
        }
    }

    /// 最近的對話（新到舊）
    func conversations(userId: String) throws -> [ConversationSummary] {
        try query("""
        SELECT c.conversation_id, c.title, c.updated_at,
               (SELECT COUNT(*) FROM AgentMessages m WHERE m.user_id = c.user_id AND m.conversation_id = c.conversation_id),
               (SELECT m.text FROM AgentMessages m WHERE m.user_id = c.user_id AND m.conversation_id = c.conversation_id
                AND m.is_user = 0 ORDER BY m.seq DESC LIMIT 1)
        FROM AgentConversations c WHERE c.user_id = ?
        ORDER BY c.updated_at DESC, c.rowid DESC
        """, userId).compactMap { row in
            guard let id = row[0] as? String else { return nil }
            return ConversationSummary(id: id, title: row[1] as? String ?? "對話",
                                       preview: String((row[4] as? String ?? "").prefix(80)),
                                       messageCount: Int(row[3] as? Int64 ?? 0),
                                       updatedAt: row[2] as? String)
        }
    }

    func conversationMessages(userId: String, conversationId: String) throws -> [StoredChatMessage] {
        try query("""
        SELECT is_user, text, bubble_text, quoted_topic, asset_ids, image_count FROM AgentMessages
        WHERE user_id = ? AND conversation_id = ? ORDER BY seq
        """, userId, conversationId).map { row in
            let idsText = row[4] as? String ?? "[]"
            let ids = (try? JSONDecoder().decode([String].self, from: Data(idsText.utf8))) ?? []
            return StoredChatMessage(isUser: (row[0] as? Int64 ?? 0) == 1, text: row[1] as? String ?? "",
                                     bubbleText: row[2] as? String, quotedTopic: row[3] as? String,
                                     assetIds: ids, imageCount: Int(row[5] as? Int64 ?? 0))
        }
    }

    func deleteConversation(userId: String, conversationId: String) throws {
        try write {
            try exec("DELETE FROM AgentMessages WHERE user_id = ? AND conversation_id = ?", userId, conversationId)
            try exec("DELETE FROM AgentConversations WHERE user_id = ? AND conversation_id = ?", userId, conversationId)
        }
    }
}

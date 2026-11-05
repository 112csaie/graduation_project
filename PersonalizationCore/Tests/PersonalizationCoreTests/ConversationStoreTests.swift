import XCTest
@testable import PersonalizationCore

/// 最近的對話：儲存、讀回、覆寫、刪除、各帳號分開、只保留最近 50 段。
final class ConversationStoreTests: XCTestCase {

    private var store: PersonalizationStore!
    private var userId: String!

    override func setUpWithError() throws {
        store = try TestDatabase.makeStore()
        userId = try store.resolveUser(email: "chat@example.com", displayName: nil)
    }

    override func tearDown() { store = nil }

    private func message(_ isUser: Bool, _ text: String, ids: [String] = [], images: Int = 0) -> StoredChatMessage {
        StoredChatMessage(isUser: isUser, text: text, bubbleText: nil, quotedTopic: nil, assetIds: ids, imageCount: images)
    }

    func testSaveLoadAndOverwrite() throws {
        try store.saveConversation(userId: userId, conversationId: "c1", messages: [
            message(true, "這是什麼？", ids: ["A"], images: 1),
            message(false, "看起來是生乳捲"),
        ])
        var list = try store.conversations(userId: userId)
        XCTAssertEqual(list.map(\.title), ["這是什麼？"])
        XCTAssertEqual(list.first?.preview, "看起來是生乳捲")
        XCTAssertEqual(list.first?.messageCount, 2)
        XCTAssertEqual(try store.conversationMessages(userId: userId, conversationId: "c1").first?.assetIds, ["A"])

        // 同一段對話繼續聊：整段覆寫，不重複
        try store.saveConversation(userId: userId, conversationId: "c1", messages: [
            message(true, "這是什麼？", ids: ["A"], images: 1),
            message(false, "看起來是生乳捲"),
            message(true, "記住"),
            message(false, "已存成筆記"),
        ])
        list = try store.conversations(userId: userId)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.messageCount, 4)
        XCTAssertEqual(list.first?.preview, "已存成筆記")
    }

    func testSeparatedByUserAndDelete() throws {
        let other = try store.resolveUser(email: "other@example.com", displayName: nil)
        try store.saveConversation(userId: userId, conversationId: "c1", messages: [message(true, "hi")])
        XCTAssertTrue(try store.conversations(userId: other).isEmpty)
        try store.deleteConversation(userId: userId, conversationId: "c1")
        XCTAssertTrue(try store.conversations(userId: userId).isEmpty)
        XCTAssertTrue(try store.conversationMessages(userId: userId, conversationId: "c1").isEmpty)
    }

    func testKeepsOnlyRecentConversations() throws {
        for index in 0..<(PersonalizationStore.maxConversations + 3) {
            try store.saveConversation(userId: userId, conversationId: "c\(index)", messages: [message(true, "第 \(index) 段")])
        }
        let list = try store.conversations(userId: userId)
        XCTAssertEqual(list.count, PersonalizationStore.maxConversations)
        XCTAssertFalse(list.contains { $0.id == "c0" }, "最舊的對話自動刪除")
        XCTAssertEqual(list.first?.id, "c\(PersonalizationStore.maxConversations + 2)")
    }

    func testPhotoOnlyMessageTitle() throws {
        try store.saveConversation(userId: userId, conversationId: "c1", messages: [message(true, "", images: 1)])
        XCTAssertEqual(try store.conversations(userId: userId).first?.title, "（照片）")
    }
}

import XCTest
@testable import PersonalizationCore

/// 從使用者的回答學習：按「不是」的照片當反例、按「是」的當正例，很像的照片自動分對。
final class TagFeedbackTests: XCTestCase {

    private func image(_ weights: [Int: Float]) -> [Float] {
        var v = [Float](repeating: 0, count: 16)
        for (axis, weight) in weights { v[axis] = weight }
        return MultiLabelTagger.normalized(v)
    }

    func testPhotoLikeARejectedOneLosesThatTag() {
        // 使用者說「這張派對照片不是演唱會」
        let feedback = TagFeedback(positives: [:], negatives: ["concert": [image([1: 1])]])
        let suggestions = [TagSuggestion(nodeId: "concert", score: 0.3, status: .candidate),
                           TagSuggestion(nodeId: "party", score: 0.3, status: .accepted)]
        // 同一場派對的另一張照片（相似度約 0.95）
        let result = feedback.apply(suggestions, imageEmbedding: image([1: 1, 2: 0.3]))
        XCTAssertNil(result.first { $0.nodeId == "concert" })
        XCTAssertNotNil(result.first { $0.nodeId == "party" }, "其他分類不受影響")

        // 不像的照片照常
        XCTAssertEqual(feedback.apply(suggestions, imageEmbedding: image([3: 1])), suggestions)
    }

    func testPhotoLikeAConfirmedOneGetsThatTag() {
        // 使用者確認過「這是貓」（自家的貓）
        let feedback = TagFeedback(positives: ["cat": [image([4: 1])]], negatives: [:])
        let result = feedback.apply([], imageEmbedding: image([4: 1, 5: 0.3]))
        XCTAssertEqual(result.first { $0.nodeId == "cat" }?.status, .accepted)

        let candidate = feedback.apply([TagSuggestion(nodeId: "cat", score: 0.22, status: .candidate)],
                                       imageEmbedding: image([4: 1, 5: 0.2]))
        XCTAssertEqual(candidate.first { $0.nodeId == "cat" }?.status, .accepted, "待確認改成確認")

        XCTAssertTrue(feedback.apply([], imageEmbedding: image([5: 1])).isEmpty, "不像的照片不會被加上")
    }

    func testAmbiguousFeedbackChangesNothing() {
        // 同樣像正例和反例 → 不動
        let feedback = TagFeedback(positives: ["cat": [image([0: 1])]], negatives: ["cat": [image([1: 1])]])
        let suggestions = [TagSuggestion(nodeId: "cat", score: 0.3, status: .accepted)]
        XCTAssertEqual(feedback.apply(suggestions, imageEmbedding: image([0: 1, 1: 1])), suggestions)
    }

    func testStoreCollectsAnswersAndSignatureChanges() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "feedback@example.com", displayName: nil)
        try TestDatabase.insertPhoto(store.db, assetId: "yes", owner: userId, embedding: TestDatabase.vector(1))
        try TestDatabase.insertPhoto(store.db, assetId: "no", owner: userId, embedding: TestDatabase.vector(2))

        let before = try store.feedbackSignature(userId: userId)
        try store.addOrConfirmTag(userId: userId, assetId: "yes", nodeId: "cat")
        try store.rejectTag(userId: userId, assetId: "no", nodeId: "concert")
        let after = try store.feedbackSignature(userId: userId)
        XCTAssertNotEqual(before, after, "回答改變 → 版本不同 → 重新分類")

        let examples = try store.feedbackExamples(userId: userId)
        XCTAssertEqual(examples.positives["cat"]?.count, 1)
        XCTAssertEqual(examples.negatives["concert"]?.count, 1)
        XCTAssertTrue(examples.positives["concert"] == nil)
    }
}

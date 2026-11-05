// AppRouter.swift
//
// 跨頁面的導覽：例如在照片頁按「問 Agent 這張照片」→ 切到 Agent 分頁，並把照片放進輸入列。

import SwiftUI

extension Notification.Name {
    /// 要切到 Agent 對話：疊在上面的照片頁、筆記頁、照片瀏覽都先關掉，對話才看得到
    static let closeOverlaysForAgent = Notification.Name("CloseOverlaysForAgent")
}

final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// 底部分頁：見 AppTab（0 照片、1 相簿、2 Agent、3 我的）
    @Published var selectedTab: Int = 0

    /// 要帶進 Agent 輸入列的照片（AgentView 接手後清掉）
    @Published var pendingAgentPhotoId: String?

    /// 要在 Agent 頁打開的「最近的對話」（AgentView 接手後清掉）
    @Published var pendingConversationId: String?

    /// 點了購物清單的到達通知：在最上層打開購物清單
    @Published var showShoppingList = false

    private init() {}

    func openShoppingList() {
        NotificationCenter.default.post(name: .closeOverlaysForAgent, object: nil)
        showShoppingList = true
    }

    func askAgent(aboutPhoto assetId: String) {
        NotificationCenter.default.post(name: .closeOverlaysForAgent, object: nil)
        pendingAgentPhotoId = assetId
        selectedTab = AppTab.agent
    }

    /// 從「我的」頁打開一段最近的對話
    func openConversation(_ id: String) {
        NotificationCenter.default.post(name: .closeOverlaysForAgent, object: nil)
        pendingConversationId = id
        selectedTab = AppTab.agent
    }
}

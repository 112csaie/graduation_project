// RecentConversationsView.swift
//
// 最近的對話：點一段接著聊，左滑刪除（只刪 App 存的聊天紀錄，筆記與照片不受影響）。

import SwiftUI

struct RecentConversationsView: View {
    let currentConversationId: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [ConversationSummary] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().tint(Theme.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if conversations.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.text.opacity(0.3))
                        Text("還沒有對話紀錄")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.text.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(conversations) { conversation in
                            Button(action: {
                                onSelect(conversation.id)
                                dismiss()
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(conversation.title)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(Theme.text)
                                            .lineLimit(1)
                                        if conversation.id == currentConversationId {
                                            Text("目前")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(Theme.onAccent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Theme.accent)
                                                .clipShape(Capsule())
                                        }
                                        Spacer()
                                        Text(Self.formatDate(conversation.updatedAt))
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.text.opacity(0.4))
                                    }
                                    if !conversation.preview.isEmpty {
                                        Text(conversation.preview)
                                            .font(.system(size: 13))
                                            .foregroundColor(Theme.text.opacity(0.55))
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Theme.surface(0.12))
                            .swipeActions {
                                Button(role: .destructive) {
                                    ConversationService.shared.delete(conversationId: conversation.id)
                                    conversations.removeAll { $0.id == conversation.id }
                                } label: {
                                    Label("刪除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("最近的對話")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            conversations = await ConversationService.shared.list()
            isLoading = false
        }
    }

    /// SQLite CURRENT_TIMESTAMP（UTC）→ 今天顯示時間，其他顯示日期
    static func formatDate(_ raw: String?) -> String {
        guard let raw else { return "" }
        guard let date = AppDateFormatters.sqliteUTC.date(from: raw) else { return raw }
        return (Calendar.current.isDateInToday(date) ? AppDateFormatters.time : AppDateFormatters.monthDay).string(from: date)
    }
}

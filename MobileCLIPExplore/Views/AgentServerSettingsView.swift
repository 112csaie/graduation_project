// AgentServerSettingsView.swift
//
// 設定 › Agent 伺服器：顯示目前連到哪台後端、重新尋找、或手動輸入位址。
// 平常不用設定：後端啟動後會在區域網路廣播自己，App 自動找到。

import SwiftUI

struct AgentServerSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var status: AgentServerLocator.Status?
    @State private var isSearching = false
    @State private var manualText = ""
    @State private var hasManual = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statusCard
                        manualCard
                        helpCard
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Agent 伺服器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            manualText = AgentServerLocator.shared.manualURL ?? ""
            hasManual = !manualText.isEmpty
            await search()
        }
    }

    // MARK: 目前狀態

    private var statusCard: some View {
        card {
            HStack(spacing: 10) {
                if isSearching {
                    ProgressView().tint(Theme.text)
                    Text("尋找中…").foregroundColor(Theme.text)
                } else if let url = status?.url {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.highlight)
                    Text(url).foregroundColor(Theme.text).textSelection(.enabled)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text("找不到伺服器").foregroundColor(Theme.text)
                }
            }
            .font(.system(size: 16, weight: .semibold))

            if !isSearching, let source = status?.source {
                Text("來源：\(source.rawValue)")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text.opacity(0.6))
            }

            button(isSearching ? "尋找中…" : "重新尋找", primary: !hasManual) {
                Task { await search() }
            }
            .disabled(isSearching || hasManual)
            .opacity(isSearching || hasManual ? 0.4 : 1)
        }
    }

    // MARK: 手動位址

    private var manualCard: some View {
        card {
            Text("手動輸入位址")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("自動找不到時才需要填，例如 192.168.0.12:8000。填了之後一律使用這個位址，清除後改回自動尋找。")
                .font(.system(size: 12))
                .foregroundColor(Theme.text.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            TextField("例如 192.168.0.12:8000", text: $manualText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Theme.text.opacity(0.08))
                .cornerRadius(8)
                .foregroundColor(Theme.text)
            HStack(spacing: 10) {
                button("儲存", primary: true) {
                    Task {
                        await AgentServerLocator.shared.setManualURL(manualText)
                        manualText = AgentServerLocator.shared.manualURL ?? ""
                        hasManual = !manualText.isEmpty
                        await search()
                    }
                }
                .disabled(AgentServerLocator.normalize(manualText) == nil)
                .opacity(AgentServerLocator.normalize(manualText) == nil ? 0.4 : 1)
                button("清除", primary: false) {
                    Task {
                        await AgentServerLocator.shared.setManualURL(nil)
                        manualText = ""
                        hasManual = false
                        await search()
                    }
                }
                .disabled(!hasManual)
                .opacity(hasManual ? 1 : 0.4)
            }
        }
    }

    private var helpCard: some View {
        card {
            Text("自動尋找怎麼運作")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            TipList(points: [
                .init("wifi", "手機和電腦連同一個 Wi-Fi，開著後端（api_server.py）就會自動找到"),
                .init("arrow.triangle.swap", "換網路、換 IP 都不用改設定"),
                .init("hand.raised", "第一次尋找時 iPhone 會問「區域網路」權限，請選允許"),
                .init("personalhotspot", "校園或公司 Wi-Fi 找不到時：改用手機個人熱點，或在上方手動輸入 IP"),
            ], collapsible: false)
        }
    }

    // MARK: 工具

    private func search() async {
        isSearching = true
        status = await AgentServerLocator.shared.refresh()
        isSearching = false
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .themeCard(radius: 22)
    }

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(primary ? Theme.onAccent : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(primary ? Theme.accent : Theme.text.opacity(0.12))
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

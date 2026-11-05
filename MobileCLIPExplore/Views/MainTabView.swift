import SwiftUI
import UIKit

/// 底部分頁：0 照片、1 相簿、2 Agent、3 我的、4 最愛（設定在「我的」裡）
/// 畫面上的順序是 照片、相簿、Agent（中間凸起）、最愛、我的；編號沿用以前的，只在後面加「最愛」。
enum AppTab {
    static let photos = 0
    static let albums = 1
    static let agent = 2
    static let me = 3
    static let favorites = 4
}

struct MainTabView: View {
    @ObservedObject private var router = AppRouter.shared
    @EnvironmentObject private var syncVM: PhotoSyncViewModel
    /// 第一次打開 Agent 時同意隱私說明（Agent 是 App 裡唯一會把照片送出手機的功能）
    @AppStorage(AgentConsentSheet.storageKey) private var agentConsent = false
    @State private var showAgentConsent = false
    @State private var tabBeforeAgent = AppTab.photos
    private var selectedTab: Int { router.selectedTab }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            // ZStack + opacity 讓各分頁同時存活於 hierarchy，
            // 切換 tab 不會銷毀 View，狀態（捲動位置、已選標籤等）全部保留
            ZStack {
                DashboardView(role: .photos)
                    .opacity(selectedTab == AppTab.photos ? 1 : 0)
                    .allowsHitTesting(selectedTab == AppTab.photos)

                DashboardView(role: .albums)
                    .opacity(selectedTab == AppTab.albums ? 1 : 0)
                    .allowsHitTesting(selectedTab == AppTab.albums)

                AgentView()
                    .opacity(selectedTab == AppTab.agent ? 1 : 0)
                    .allowsHitTesting(selectedTab == AppTab.agent)

                FavoritesTabView()
                    .opacity(selectedTab == AppTab.favorites ? 1 : 0)
                    .allowsHitTesting(selectedTab == AppTab.favorites)

                ProfileHubView(isTab: true)
                    .environmentObject(syncVM)
                    .opacity(selectedTab == AppTab.me ? 1 : 0)
                    .allowsHitTesting(selectedTab == AppTab.me)
            }
            .padding(.bottom, 76)

            BottomNavBar(selectedTab: $router.selectedTab)
        }
        .onChange(of: router.selectedTab) { old, new in
            UIApplication.shared.dismissKeyboard()
            if new == AppTab.agent && !agentConsent {
                tabBeforeAgent = old == AppTab.agent ? AppTab.photos : old
                showAgentConsent = true
            }
        }
        .sheet(isPresented: $showAgentConsent) {
            AgentConsentSheet(onAgree: {
                agentConsent = true
                showAgentConsent = false
            }, onDecline: {
                showAgentConsent = false
                router.pendingAgentPhotoId = nil
                router.selectedTab = tabBeforeAgent
            })
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $router.showShoppingList) { ShoppingListView() }
    }
}


// MARK: - 第一次使用 Agent 的隱私說明

/// 第一次打開 Agent：說清楚哪些內容會送出手機，同意後才開始使用。不同意就回到原本的分頁。
struct AgentConsentSheet: View {
    static let storageKey = "agentPrivacyConsent"
    let onAgree: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    SelfieGlyph(size: 34, color: Theme.onAccent)
                        .frame(width: 60, height: 60)
                        .background(Theme.accent)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("使用 Agent 前")
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundColor(Theme.text)
                        Text("請看一下哪些內容會送出手機")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.secondaryText)
                    }
                }
                .padding(.top, 8)

                block(icon: "paperplane", title: "會送出的內容", points: [
                    .init("text.bubble", "你/妳在 Agent 打的問題"),
                    .init("photo", "你/妳附上的那一張照片（只有按下送出時）"),
                    .init("book.closed", "和問題有關的幾篇筆記內容，讓回答更準"),
                ])
                block(icon: "server.rack", title: "送到哪裡", points: [
                    .init("server.rack", "selfIE 開發者架設的後端"),
                    .init("cpu", "後端會再交給它設定的 AI 模型產生回答"),
                ])
                block(icon: "lock", title: "不會送出的", points: [
                    .init("photo.stack", "相簿裡其他照片，不會在背景上傳"),
                    .init("tag", "分類、tag、相簿和搜尋都在手機上完成"),
                    .init("location.slash", "不會追蹤你/妳的位置"),
                ])

                Text("之後可以在「我的 › 設定 › 隱私」再看一次。")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryText)

                VStack(spacing: 10) {
                    Button(action: onAgree) {
                        Text("同意並開始使用")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button(action: onDecline) {
                        Text("先不要")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationCornerRadius(32)
    }

    private func block(icon: String, title: String, points: [TipList.Point]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.text)
            TipList(points: points, collapsible: false)
        }
    }
}

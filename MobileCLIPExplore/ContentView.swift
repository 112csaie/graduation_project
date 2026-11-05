import SwiftUI

struct ContentView: View {
    @AppStorage("isLoggedIn") var isLoggedIn = false
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .chinese // 🌟 讀取全域語言設定
    @AppStorage("savedEmail") private var savedEmail = ""
    @AppStorage("userName") private var userName = ""

    /// App 層注入的同一個實例（以前這裡另外建一個，會多載入一份影像模型）
    @EnvironmentObject private var syncVM: PhotoSyncViewModel

    /// 註冊／登入後的兩階段個人化設定（興趣定位 → 大分類）。可以跳過，之後在設定頁修改。
    @State private var showOnboarding = false

    @AppStorage(AppearanceMode.storageKey) private var appearanceMode = AppearanceMode.dark.rawValue

    var body: some View {
        Group { // 🌟 用 Group 包覆，方便統一注入環境變數
            if isLoggedIn {
                if showOnboarding {
                    PersonalizationSetupView(mode: .onboarding) {
                        withAnimation { showOnboarding = false }
                    }
                } else {
                    MainTabView()
                        .environmentObject(syncVM)
                }
            } else {
                LoginView(isLoggedIn: $isLoggedIn)
            }
        }
        .environment(\.locale, .init(identifier: appLanguage.rawValue)) // 🌟 強制全 App 套用當前語言
        // 整個 App 統一風格：灰藍配色（Theme）、圓體字、按鈕顏色；
        // 深色模式：開啟（黑色）／關閉（米色）／跟隨系統，在「我的」右上角或設定裡切換
        .fontDesign(.rounded)
        .tint(Theme.tint)
        .preferredColorScheme((AppearanceMode(rawValue: appearanceMode) ?? .dark).colorScheme)
        .animation(.easeInOut, value: isLoggedIn) // 讓登入/登出有平滑的漸變動畫
        .onAppear { refreshPersonalizationSession() }
        .onChange(of: isLoggedIn) { _, _ in refreshPersonalizationSession() }
    }

    private func refreshPersonalizationSession() {
        guard isLoggedIn else {
            showOnboarding = false
            return
        }
        let service = PersonalizationService.shared
        // 升級前就已登入的使用者：補建本機帳號 ID（與既有登入流程相容，不要求重新登入）。
        service.restoreSessionIfNeeded(email: savedEmail, displayName: userName)
        showOnboarding = service.needsOnboarding()
        // App 一開啟就在背景準備分類文字向量，之後掃描時可以立刻邊掃邊分類
        service.prepareTaggerInBackground()
    }
}

#Preview {
    ContentView()
        .environmentObject(BackgroundSyncCoordinator.shared.syncViewModel)
}

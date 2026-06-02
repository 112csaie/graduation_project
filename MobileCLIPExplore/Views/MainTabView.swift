import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Int = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            // ZStack + opacity 讓三個 View 同時存活於 hierarchy，
            // 切換 tab 不會銷毀 View，狀態（捲動位置、已選標籤等）全部保留
            ZStack {
                DashboardView()
                    .opacity(selectedTab == 0 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 0)

                AgentView()
                    .opacity(selectedTab == 1 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 1)

                SettingView()
                    .opacity(selectedTab == 2 ? 1 : 0)
                    .allowsHitTesting(selectedTab == 2)
            }
            .padding(.bottom, 70)

            BottomNavBar(selectedTab: $selectedTab)
        }
    }
}

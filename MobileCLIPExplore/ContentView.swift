import SwiftUI

struct ContentView: View {
    @AppStorage("isLoggedIn") var isLoggedIn = false
    @StateObject private var syncVM = PhotoSyncViewModel()

    var body: some View {
        if isLoggedIn {
            MainTabView()
                .environmentObject(syncVM)
        } else {
            LoginView(isLoggedIn: $isLoggedIn)
        }
    }
}

#Preview {
    ContentView()
}

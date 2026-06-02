import SwiftUI

struct SettingView: View {
    @AppStorage("isLoggedIn") var isLoggedIn = false
    @EnvironmentObject var syncVM: PhotoSyncViewModel

    @State private var showClearCacheAlert = false
    @State private var showSignOutAlert    = false
    @State private var cacheCleared       = false
    @State private var dbSize             = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {

                        // ── 使用者資料卡片 ──────────────────────────
                        userProfileCard
                            .padding(.top, 16)

                        // ── 同步狀態區塊 ──────────────────────────
                        settingSection(title: "Library") {
                            // Sync Data
                            Button(action: {
                                if !syncVM.isSyncing { syncVM.startSync() }
                            }) {
                                SettingRow(
                                    icon: "arrow.triangle.2.circlepath",
                                    title: "Sync Photo Library",
                                    subtitle: syncVM.isSyncing
                                        ? "Syncing \(syncVM.syncedCount) / \(syncVM.totalCount)..."
                                        : "Scan & index new photos",
                                    showSpinner: syncVM.isSyncing
                                )
                            }

                            Divider().background(Color.white.opacity(0.1))

                            // Storage info
                            SettingRow(
                                icon: "internaldrive",
                                title: "Database Size",
                                subtitle: dbSize,
                                showChevron: false
                            )
                        }

                        // ── 一般設定 ──────────────────────────────
                        settingSection(title: "General") {
                            Button(action: openSystemSettings) {
                                SettingRow(icon: "bell", title: "Notifications")
                            }

                            Divider().background(Color.white.opacity(0.1))

                            Button(action: openSystemSettings) {
                                SettingRow(icon: "lock.shield", title: "Privacy & Security")
                            }

                            Divider().background(Color.white.opacity(0.1))

                            Button(action: openSystemSettings) {
                                SettingRow(icon: "photo.on.rectangle", title: "Photo Library Access")
                            }
                        }

                        // ── 危險操作 ──────────────────────────────
                        settingSection(title: "Data") {
                            Button(action: { showClearCacheAlert = true }) {
                                SettingRow(
                                    icon: "trash",
                                    title: "Clear Cache",
                                    subtitle: cacheCleared ? "Cache cleared" : "Free up temporary storage",
                                    tintColor: .orange
                                )
                            }
                        }

                        // ── 登出 ──────────────────────────────────
                        Button(action: { showSignOutAlert = true }) {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                Text("Sign Out")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.red.opacity(0.12))
                            .cornerRadius(14)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)

                    }
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear { dbSize = measureDBSize() }
        .alert("Sign Out", isPresented: $showSignOutAlert) {
            Button("Sign Out", role: .destructive) { isLoggedIn = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be returned to the login screen.")
        }
        .alert("Clear Cache", isPresented: $showClearCacheAlert) {
            Button("Clear", role: .destructive) {
                clearCache()
                cacheCleared = true
                dbSize = measureDBSize()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Temporary files and HTTP cache will be removed. Your photos, embeddings, and notes are unaffected.")
        }
    }

    // MARK: - App 品牌卡片

    private var userProfileCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.3, green: 0.5, blue: 1.0),
                                 Color(red: 0.55, green: 0.25, blue: 1.0)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 56, height: 56)
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("User")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            Spacer()
        }
        .padding(20)
        .background(Color.white.opacity(0.07))
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }

    // MARK: - 區塊容器

    @ViewBuilder
    private func settingSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                content()
            }
            .background(Color.white.opacity(0.07))
            .cornerRadius(14)
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Actions

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func clearCache() {
        URLCache.shared.removeAllCachedResponses()

        // 清理 tmp 目錄
        let tmp = FileManager.default.temporaryDirectory
        if let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            items.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private func measureDBSize() -> String {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "N/A"
        }
        let dbURL = docs.appendingPathComponent("PhotoAI.sqlite")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dbURL.path),
              let bytes = attrs[.size] as? Int64
        else { return "N/A" }

        if bytes < 1_048_576 {
            return "\(bytes / 1024) KB"
        } else {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
    }


}

// MARK: - SettingRow 元件

struct SettingRow: View {
    let icon: String
    let title: String
    var subtitle: String = ""
    var tintColor: Color = .white
    var showChevron: Bool = true
    var showSpinner: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(tintColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(tintColor)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            Spacer()

            if showSpinner {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.8)
            } else if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

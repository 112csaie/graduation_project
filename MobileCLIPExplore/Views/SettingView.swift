import SwiftUI
import UIKit

// MARK: - 語言列舉（全域）
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case chinese = "zh-Hant"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "繁體中文"
        }
    }
}

struct SettingView: View {
    @AppStorage("isLoggedIn")   var isLoggedIn   = false
    @AppStorage("appLanguage")  var appLanguage: AppLanguage = .chinese
    @AppStorage("userName")     var userName     = ""
    @AppStorage(AIRouter.Preference.storageKey) private var aiPreference = AIRouter.Preference.device.rawValue
    @AppStorage(DatabaseManager.syncSystemFavoritesKey) private var syncSystemFavorites = true
    @AppStorage("savedEmail")   var savedEmail   = ""

    @EnvironmentObject var syncVM: PhotoSyncViewModel

    @State private var showClearCacheAlert = false
    @State private var showSignOutAlert    = false
    @State private var cacheCleared       = false
    @State private var dbSize             = ""
    @State private var showFMTest         = false
    @State private var showCategoryPreferences = false
    @State private var showAgentServer = false
    @AppStorage(AppearanceMode.storageKey) private var appearanceMode = AppearanceMode.dark.rawValue

    private var isEN: Bool { appLanguage == .english }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {

                    // ── 使用者資料卡片 ──
                    userProfileCard
                        .padding(.top, 20)

                    // ── 圖庫 ──
                    settingSection(title: isEN ? "LIBRARY" : "圖庫") {
                        // 同步照片
                        Button(action: {
                            if !syncVM.isSyncing { syncVM.startSync() }
                        }) {
                            SettingRow(
                                icon: "arrow.triangle.2.circlepath",
                                title: isEN ? "Sync Photo Library" : "同步照片圖庫",
                                subtitle: syncVM.isSyncing
                                    ? (isEN ? "Syncing \(syncVM.syncedCount) / \(syncVM.totalCount)..."
                                            : "同步中 \(syncVM.syncedCount) / \(syncVM.totalCount)...")
                                    : (isEN ? "Scan & index new photos" : "掃描並建立新照片索引"),
                                showSpinner: syncVM.isSyncing
                            )
                        }

                        settingDivider

                        // 補全地點資料
                        Button(action: {
                            syncVM.startLocationBackfill()
                        }) {
                            SettingRow(
                                icon: "location.fill.viewfinder",
                                title: isEN ? "Backfill Location Data" : "補全地點資料",
                                subtitle: isEN ? "Re-geocode photos missing location text" : "為舊照片補齊反向地理編碼（地點文字）"
                            )
                        }

                        settingDivider

                        // 資料庫大小
                        SettingRow(
                            icon: "internaldrive",
                            title: isEN ? "Database Size" : "資料庫大小",
                            subtitle: dbSize,
                            showChevron: false
                        )

                        settingDivider

                        // 智慧搜尋（抽象語意搜尋）狀態
                        Button { showFMTest = true } label: {
                            SettingRow(
                                icon: "text.magnifyingglass",
                                title: "智慧搜尋",
                                subtitle: "Apple Intelligence 照片分析進度與診斷"
                            )
                        }
                        .sheet(isPresented: $showFMTest) {
                            AbstractSearchStatusView()
                        }
                    }

                    // ── 個人化分類 ──
                    settingSection(title: isEN ? "PERSONALIZATION" : "個人化") {
                        Button { showCategoryPreferences = true } label: {
                            SettingRow(
                                icon: "square.grid.2x2",
                                title: isEN ? "Category Preferences" : "分類偏好",
                                subtitle: isEN ? "Interests and photo categories" : "興趣定位與優先整理的照片分類"
                            )
                        }
                        .sheet(isPresented: $showCategoryPreferences) {
                            PersonalizationSetupView(mode: .settings) {
                                showCategoryPreferences = false
                            }
                        }

                        settingDivider

                        // 標記照片是不是某個分類，匯出給組員一起訓練判斷器（只匯出特徵數字，不含照片）
                        NavigationLink(destination: TagLabelingView()) {
                            SettingRow(icon: "checkmark.square",
                                       title: isEN ? "Help Train Categories" : "協助訓練分類",
                                       subtitle: isEN ? "Label photos and export for training" : "標記照片是不是某個分類，匯出給組員訓練")
                        }
                    }

                    // ── 一般設定 ──
                    settingSection(title: isEN ? "GENERAL" : "一般") {
                        NavigationLink(destination: PrivacyView()) {
                            SettingRow(icon: "lock", title: isEN ? "Privacy" : "隱私",
                                       subtitle: AIRouter.onDevice ? "照片和文字都留在手機上" : "哪些在手機上、哪些會送到後端")
                        }

                        settingDivider

                        // 清單整理、回憶筆記：手機上（最隱私）或開發者的後端（較準確）
                        if OnDeviceAI.isAvailable {
                            Menu {
                                Picker("清單整理與回憶筆記", selection: $aiPreference) {
                                    ForEach(AIRouter.Preference.allCases) { option in
                                        Text(option.title).tag(option.rawValue)
                                    }
                                }
                            } label: {
                                SettingRow(
                                    icon: "cpu",
                                    title: isEN ? "AI Processing" : "清單整理與回憶筆記",
                                    subtitle: (AIRouter.Preference(rawValue: aiPreference) ?? .device).title
                                )
                            }

                            settingDivider
                        }

                        // 深色模式：開啟（黑色）／關閉（米色）／跟隨系統
                        Menu {
                            Picker("深色模式", selection: $appearanceMode) {
                                ForEach(AppearanceMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                        } label: {
                            SettingRow(
                                icon: "circle.lefthalf.filled",
                                title: isEN ? "Dark Mode" : "深色模式",
                                subtitle: (AppearanceMode(rawValue: appearanceMode) ?? .dark).title
                                    + (isEN ? "" : "・關閉時是米色")
                            )
                        }

                        settingDivider

                        // 「照片」App 的喜好項目 → App 的最愛（只讀取，不會改系統相簿）
                        // 開關放在列裡面（和其他列的箭頭同一個位置），不會貼到卡片邊緣
                        SettingRow(icon: "heart.text.square", title: "同步「照片」的喜好項目",
                                   subtitle: "在「照片」App 按愛心的照片也會放進最愛",
                                   toggle: $syncSystemFavorites)
                        .onChange(of: syncSystemFavorites) { _, on in
                            if on { DispatchQueue.global(qos: .utility).async { DatabaseManager.shared.syncSystemFavorites() } }
                        }

                        settingDivider

                        // 相簿存取
                        Button(action: openSystemSettings) {
                            SettingRow(
                                icon: "photo.on.rectangle",
                                title: isEN ? "Photo Library Access" : "相簿存取權限"
                            )
                        }

                        settingDivider

                        // Agent 後端位址（自動尋找，必要時手動輸入）
                        Button { showAgentServer = true } label: {
                            SettingRow(
                                icon: "network",
                                title: isEN ? "Agent Server" : "Agent 伺服器",
                                subtitle: isEN ? "Found automatically on the same Wi-Fi" : "同一個 Wi-Fi 自動尋找，必要時手動輸入"
                            )
                        }
                        .sheet(isPresented: $showAgentServer) {
                            AgentServerSettingsView()
                        }
                    }

                    // ── 資料 ──
                    settingSection(title: isEN ? "DATA" : "資料") {
                        Button(action: { showClearCacheAlert = true }) {
                            SettingRow(
                                icon: "trash",
                                title: isEN ? "Clear Cache" : "清除快取",
                                subtitle: cacheCleared
                                    ? (isEN ? "Cache cleared" : "快取已清除")
                                    : (isEN ? "Free up temporary storage" : "釋放暫存空間"),
                                tintColor: .orange
                            )
                        }
                    }

                    // ── 版本資訊 ──
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        VStack(spacing: 4) {
                            SelfieWordmark(size: 22)
                            Text("\(AppBrand.slogan)・v\(version)")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // ── 登出 ──
                    Button(action: { showSignOutAlert = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text(isEN ? "Sign Out" : "登出")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
        }
        .onAppear { dbSize = measureDBSize() }
        // 登出確認：和其他選擇畫面一樣，從下方升起
        .sheet(isPresented: $showSignOutAlert) {
            SignOutSheet(name: userName) {
                // 只回到開始頁；手機上的資料都保留，再進來就接著用
                showSignOutAlert = false
                PersonalizationService.shared.signOut()
                isLoggedIn = false
            }
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(32)
        }
        .alert(isEN ? "Clear Cache" : "清除快取", isPresented: $showClearCacheAlert) {
            Button(isEN ? "Clear" : "清除", role: .destructive) {
                clearCache()
                cacheCleared = true
                dbSize = measureDBSize()
            }
            Button(isEN ? "Cancel" : "取消", role: .cancel) {}
        } message: {
            Text(isEN
                 ? "Temporary files and HTTP cache will be removed. Your photos, embeddings, and notes are unaffected."
                 : "暫存檔案與 HTTP 快取將被移除。您的照片、特徵值與筆記不受影響。")
        }
    }

    // MARK: - 使用者卡片

    private var userProfileCard: some View {
        HStack(spacing: 16) {
            // 頭貼（和「我的」頁同一個，在那裡點頭貼可以重新設計）
            UserAvatarView(name: userName, size: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(userName.isEmpty ? (isEN ? "User" : "使用者") : userName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.text)
                if !savedEmail.isEmpty {
                    Text(savedEmail)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.text.opacity(0.5))
                }
            }

            Spacer()
        }
        .padding(20)
        .background(Theme.text.opacity(0.07))
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }

    private var avatarInitial: String {
        let name = userName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "U" : String(name.prefix(1)).uppercased()
    }

    // MARK: - 區塊容器

    @ViewBuilder
    private func settingSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.text.opacity(0.35))
                .padding(.horizontal, 20)

            VStack(spacing: 0) {
                content()
            }
            .background(Theme.text.opacity(0.07))
            .cornerRadius(14)
            .padding(.horizontal, 20)
        }
    }

    private var settingDivider: some View {
        Divider()
            .background(Theme.text.opacity(0.08))
            .padding(.leading, 58)
    }

    // MARK: - Actions

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        let tmp = FileManager.default.temporaryDirectory
        if let items = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) {
            items.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private func measureDBSize() -> String {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return "N/A" }

        // WAL 模式下，最近寫入的資料暫存在 -wal 檔，一起算
        let paths = ["PhotoAI.sqlite", "PhotoAI.sqlite-wal", "PhotoAI.sqlite-shm"].map { docs.appendingPathComponent($0).path }
        let sizes = paths.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? Int64 }
        guard !sizes.isEmpty else { return "N/A" }
        let bytes = sizes.reduce(0, +)

        return bytes < 1_048_576
            ? "\(bytes / 1024) KB"
            : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - SettingRow

struct SettingRow: View {
    let icon: String
    let title: String
    var subtitle: String = ""
    var tintColor: Color = Theme.text
    var showChevron: Bool = true
    var showSpinner: Bool = false
    /// 有給的話，右邊顯示開關（取代箭頭）
    var toggle: Binding<Bool>? = nil

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
                        .foregroundColor(Theme.text.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if let toggle {
                Toggle("", isOn: toggle)
                    .labelsHidden()
                    .tint(Theme.tint)
            } else if showSpinner {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.text))
                    .scaleEffect(0.8)
            } else if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text.opacity(0.3))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}


// MARK: - 登出確認

/// 登出確認：頭貼、一句說明（資料都留在手機上），下面是登出（紅色）和取消
struct SignOutSheet: View {
    let name: String
    let onSignOut: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            UserAvatarView(name: name, size: 64)
                .padding(.top, 28)
            Text("要登出嗎？")
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(Theme.text)
            Text("照片、tag 和筆記都會留在這支手機上，不會刪除。\n下次打開 selfIE 就能接著用。")
                .font(.system(size: 14))
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(action: { dismiss() }) {
                    Text("取消")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.card)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
                }
                Button(action: onSignOut) {
                    Text("登出")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.red.opacity(0.85))
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}

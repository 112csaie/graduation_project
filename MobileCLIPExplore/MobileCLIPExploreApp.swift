import SwiftUI
import BackgroundTasks
import UIKit
import CoreLocation
import UserNotifications
import GoogleSignIn // 👈 1. 頂部必須引入這個

@main
struct MobileCLIPExploreApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    
    // 1. 全 App 共用同一個 SyncViewModel（背景同步也用它）：每個實例都會載入一次 MobileCLIP 影像模型，
    //    以前 App、ContentView、背景同步各建一個，記憶體裡同時有三份模型。
    @StateObject private var syncVM = BackgroundSyncCoordinator.shared.syncViewModel
    
    // 2. 引入語言設定
    @AppStorage("appLanguage") var appLanguage: AppLanguage = .chinese

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 3. 注入 EnvironmentObject 給所有子視圖使用
                .environmentObject(syncVM)
                // 4. 強制整個 App 根據設定切換語言
                .environment(\.locale, .init(identifier: appLanguage.rawValue))
                
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                
                .onAppear {
                    BackgroundSyncCoordinator.shared.schedule()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        BackgroundSyncCoordinator.shared.schedule()
                        // 智慧搜尋：進背景就停（系統會限制背景的 Foundation Models），改排充電時的背景任務接續。
                        // 使用者在 App 裡按的「暫停」只到離開 App 為止，回來時照預設自動接續。
                        AbstractSearchCoordinator.shared.cancelBuild()
                        AbstractSearchCoordinator.shared.clearUserPause()
                        PhotoTextCoordinator.shared.cancelPaperScan()
                        AbstractSearchCoordinator.shared.scheduleBackgroundBuild()
                    } else if newPhase == .active {
                        // 回到 App：從沒分析完的照片接續（已分析的會略過）
                        AbstractSearchCoordinator.shared.scheduleBuild()
                        // 看起來像票根、收據、證件的照片：辨識文字決定分類（只辨識這類照片）
                        PhotoTextCoordinator.shared.schedulePaperScan(delay: 2)
                        // 想去清單：看看最近拍的照片有沒有在清單地點附近（只讀取拍攝時間與位置）
                        WishListService.shared.checkVisitsIfNeeded()
                        // 有沒有連上電腦（Agent 後端）：介面事先標示需要電腦的功能
                        AgentConnection.shared.check()
                        // 從其他 App 分享進來的截圖：整理進購物清單／想去清單（連不上電腦時留著下次再試）
                        SharedInboxProcessor.shared.processIfNeeded()
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // 以前的版本有購物清單的「到達提醒」（顯著位置變更）：已經拿掉，停掉舊版留下的位置監測
        CLLocationManager().stopMonitoringSignificantLocationChanges()
        BackgroundSyncCoordinator.shared.register()
        // 在「照片」App 刪了照片後回來：自動從畫面拿掉（只清理 App 自己的資料）
        PhotoLibraryDeletionWatcher.shared.start()
        // 手機降溫、關掉低耗電模式後，自動接續先前暫停的背景整理
        DeviceLoad.startObserving()
        // 抽象語意搜尋：充電時在背景接續建圖（必須在啟動完成前註冊）
        AbstractSearchCoordinator.shared.registerBackgroundTask()
        // 針對繁體中文使用者：一次性把介面語言切換為繁體中文（之後仍可在設定中更改）
        let migrationKey = "didMigrateToTraditionalChineseUI"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            UserDefaults.standard.set(AppLanguage.chinese.rawValue, forKey: "appLanguage")
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
        return true
    }

    /// App 開著時也顯示通知
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

final class BackgroundSyncCoordinator {
    static let shared = BackgroundSyncCoordinator()

    private let taskIdentifier = "com.elaine.MobileCLIPExplore.photosync.processing"
    /// 全 App 唯一的 PhotoSyncViewModel（前景掃描、背景同步、重新分析共用，模型只載入一次）
    let syncViewModel = PhotoSyncViewModel()
    private var worker: PhotoSyncViewModel { syncViewModel }

    private init() {}

    /// 供「重新分析」使用，沿用同一個已載入模型的 worker，避免重複載入 CoreML 模型。
    func reanalyzeAsset(assetId: String) -> Bool {
        worker.reanalyzeAsset(assetId: assetId)
    }

    /// 旅行中還沒有地名的旅程：優先查詢地區（RegionResolver 會去重複、限速並在限流後重試）。
    func resolveTripRegions(assetIds: [String]) {
        RegionResolver.shared.enqueue(assetIds, priority: true)
    }

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            self.handle(processingTask)
        }
    }

    func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)

        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("背景同步任務已排程")
        } catch {
            print("背景同步排程失敗: \(error)")
        }
    }

    private func handle(_ task: BGProcessingTask) {
        schedule()

        let expirationState = LockedFlag()
        task.expirationHandler = {
            expirationState.value = true
        }

        DispatchQueue.global(qos: .utility).async {
            let summary = self.worker.performBackgroundSync(
                scanLimit: 20,
                classificationLimit: 50,
                shouldContinue: { !expirationState.value }
            )

            let success = !expirationState.value
            print("背景同步完成：新增 embedding \(summary.embeddedCount) 張，分類 \(summary.classifiedCount) 張，success=\(success)")
            task.setTaskCompleted(success: success)
        }
    }
}

final class LockedFlag {
    private let queue = DispatchQueue(label: "com.photoai.background.flag")
    private var storage = false

    var value: Bool {
        get { queue.sync { storage } }
        set { queue.sync { storage = newValue } }
    }
}

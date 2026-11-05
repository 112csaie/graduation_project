// SharedInboxProcessor.swift
//
// 整理「分享到 App」收件匣裡的截圖（見 Shared/SharedInbox.swift）：
// App 回到前景、或剛連上電腦時，逐一辨識文字 → 請 Agent 整理商品或地點 → 存進購物清單或想去清單。
// - 連不上電腦：留在收件匣，下次再試（清單頁會顯示「等待整理 N 張」）。
// - 整理不出東西（例如截圖裡沒有商品）：從收件匣移除，並告訴你哪一張。
// - 清單上「查看截圖」用的副本存在 App 自己的資料夾（SharedScreenshotStore），不存進相簿。

import Combine
import Foundation
import SwiftUI
import UIKit

final class SharedInboxProcessor: ObservableObject {
    static let shared = SharedInboxProcessor()

    /// 還在收件匣、等待整理的數量（依清單）
    @Published private(set) var pendingShopping = 0
    @Published private(set) var pendingWish = 0
    /// 最近一次整理的結果（顯示在清單頁上方）
    @Published private(set) var lastMessage: String?
    @Published private(set) var isProcessing = false

    private var running = false
    private let lock = NSLock()
    private var connectionObserver: AnyCancellable?

    private init() {
        // 剛連上電腦：整理還在等待的截圖
        connectionObserver = AgentConnection.shared.$state
            .removeDuplicates()
            .filter { $0 == .connected }
            .sink { [weak self] _ in self?.processIfNeeded() }
    }

    func refreshCounts() {
        let items = SharedInbox.pending()
        DispatchQueue.main.async {
            self.pendingShopping = items.filter { $0.kind == .shopping }.count
            self.pendingWish = items.filter { $0.kind == .wish }.count
        }
    }

    /// 整理收件匣（同時只會有一輪）
    func processIfNeeded() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        let items = SharedInbox.pending()
        guard !items.isEmpty, LocalUserSession.currentUserId != nil else {
            lock.unlock()
            refreshCounts()
            return
        }
        running = true
        lock.unlock()
        DispatchQueue.main.async { self.isProcessing = true }

        Task.detached(priority: .utility) {
            var messages: [String] = []
            for item in items {
                let outcome = await self.process(item)
                if let text = outcome.message { messages.append(text) }
                if outcome.stop { break }
            }
            self.lock.lock()
            self.running = false
            self.lock.unlock()
            self.refreshCounts()
            await MainActor.run {
                self.isProcessing = false
                if !messages.isEmpty { self.lastMessage = messages.joined(separator: "\n") }
            }
        }
    }

    private func process(_ item: SharedInbox.Item) async -> (message: String?, stop: Bool) {
        let image = SharedInbox.image(for: item)
        // IG、Threads、FB 的「分享」只給連結：連結打開要登入，伺服器看不到貼文內容
        if image == nil, item.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 8,
           let host = URL(string: item.url)?.host?.lowercased(),
           ["instagram.com", "threads.net", "threads.com", "facebook.com", "fb.com"].contains(where: { host.hasSuffix($0) }) {
            SharedInbox.remove(item)
            return ("IG 的分享只有連結、看不到貼文內容。請把貼文截圖，再從相簿把截圖分享到「加到清單」。", false)
        }
        // 文字：分享進來的文字＋網址＋截圖裡辨識到的字
        var parts = [item.text, item.url].filter { !$0.isEmpty }
        if let image {
            let recognized = PhotoTextRecognizer.recognize(image: image)
            if !recognized.isEmpty { parts.append(recognized) }
        }
        let text = parts.joined(separator: "\n")
        let ref = image.flatMap { SharedScreenshotStore.save($0, id: item.id) }
        do {
            switch item.kind {
            case .shopping:
                let result = try await ShoppingListService.shared.addItems(sharedText: text, image: image, sourceRef: ref)
                SharedInbox.remove(item)
                return (result.added.isEmpty ? "分享的截圖：清單裡已經有了" : "已加入購物清單：" + result.added.joined(separator: "、"), false)
            case .wish:
                let result = try await WishListService.shared.addPlaces(sharedText: text, image: image, sourceRef: ref)
                SharedInbox.remove(item)
                return (result.added.isEmpty ? "分享的截圖：清單裡已經有了" : "已加入想去清單：" + result.added.joined(separator: "、"), false)
            }
        } catch {
            if error is AgentServerError || (error as? URLError) != nil {
                // 連不上電腦：留著下次再試（副本也先刪掉，下次重新存）
                if let ref { SharedScreenshotStore.remove(ref) }
                return (nil, true)
            }
            // 整理不出東西：移除，告訴使用者
            if let ref { SharedScreenshotStore.remove(ref) }
            SharedInbox.remove(item)
            return ("分享到\(item.kind.title)的一張截圖沒有整理出內容：\(error.localizedDescription)", false)
        }
    }
}

// MARK: - 分享截圖的副本

/// 清單上「查看截圖」用的副本（App 自己的資料夾，不是相簿）。參照格式：shared:<檔名>
enum SharedScreenshotStore {
    static let prefix = "shared:"

    private static var folder: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let url = base.appendingPathComponent("SharedScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func isShared(_ ref: String?) -> Bool { ref?.hasPrefix(prefix) == true }

    /// 存一份縮小的副本，回傳參照（shared:<檔名>）
    static func save(_ image: UIImage, id: String) -> String? {
        guard let folder, let data = SharedInbox.downscaled(image, maxSide: 1600).jpegData(compressionQuality: 0.8) else { return nil }
        let name = id + ".jpg"
        guard (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return prefix + name
    }

    static func image(for ref: String) -> UIImage? {
        guard isShared(ref), let folder else { return nil }
        return UIImage(contentsOfFile: folder.appendingPathComponent(String(ref.dropFirst(prefix.count))).path)
    }

    static func remove(_ ref: String) {
        guard isShared(ref), let folder else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(String(ref.dropFirst(prefix.count))))
    }
}

/// 看分享進來的截圖副本（清單上的「查看截圖」）
struct SharedScreenshotView: View {
    let ref: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if let image = SharedScreenshotStore.image(for: ref) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Text("找不到這張截圖").foregroundColor(Theme.text.opacity(0.6))
                }
            }
            .navigationTitle("分享的截圖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

/// 清單頁上方：從分享加入、還在等待整理的數量與最近的結果
struct SharedInboxStatusRow: View {
    let kind: SharedInbox.Kind
    @ObservedObject private var processor = SharedInboxProcessor.shared

    private var pending: Int { kind == .shopping ? processor.pendingShopping : processor.pendingWish }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if pending > 0 {
                HStack(spacing: 8) {
                    if processor.isProcessing { ProgressView().scaleEffect(0.7).tint(Theme.text) }
                    else { Image(systemName: "tray.and.arrow.down").foregroundColor(Theme.text.opacity(0.7)) }
                    Text(processor.isProcessing ? "正在整理分享進來的 \(pending) 張截圖…" : "分享進來、等待整理：\(pending) 張（需要連上後端）")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.text.opacity(0.8))
                    Spacer()
                    if !processor.isProcessing {
                        Button("再試一次") { processor.processIfNeeded() }
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
            }
            if let message = processor.lastMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.highlight.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { processor.refreshCounts() }
    }
}

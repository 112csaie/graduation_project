// AbstractSearchStatusView.swift
//
// 設定 › 智慧搜尋：抽象語意搜尋（AbstractSearch 模組）的狀態與診斷。
// 取代舊的 FoundationModelTestView（舊版 SceneGraphs 資料表的診斷）。

import SwiftUI
import UIKit

struct AbstractSearchStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var coordinator = AbstractSearchCoordinator.shared
    @ObservedObject private var ocr = PhotoTextCoordinator.shared

    @State private var stats: ASIndexStats?
    @State private var parityReport: String?
    @State private var isRunningParity = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statusCard
                        indexCard
                        textCard
                        parityCard
                    }
                    .padding(20)
                }
            }
            .navigationTitle("智慧搜尋")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            await reloadStats()
            ocr.refreshStats()
        }
        // 停在這一頁、正在分析時，螢幕不自動關閉（關螢幕後系統會暫停 Apple Intelligence 的分析）
        .onAppear { UIApplication.shared.isIdleTimerDisabled = coordinator.isBuilding }
        .onChange(of: coordinator.isBuilding) { _, building in UIApplication.shared.isIdleTimerDisabled = building }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onReceive(NotificationCenter.default.publisher(for: .abstractSearchIndexUpdated)) { _ in
            Task { await reloadStats() }
        }
    }

    // MARK: 可用性

    private var statusCard: some View {
        card {
            HStack(spacing: 10) {
                Image(systemName: coordinator.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(coordinator.isAvailable ? Theme.highlight : .yellow)
                Text(coordinator.isAvailable ? "可以使用" : "目前無法使用")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.text)
            }
            Text(coordinator.unavailableReason ?? "用一句話找照片，例如「一隻在海邊散步的狗」。")
                .font(.system(size: 14))
                .foregroundColor(Theme.text.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            TipList(points: searchPoints)
        }
    }

    private var searchPoints: [TipList.Point] {
        var points = [
            TipList.Point("text.bubble", "Apple Intelligence 理解你/妳的句子，和每張照片的場景描述比對"),
            TipList.Point("iphone", "全部在手機上完成，不上傳照片"),
        ]
        if !coordinator.isAvailable {
            points.append(TipList.Point("magnifyingglass", "無法使用時，首頁搜尋仍會用照片特徵和 tag"))
        }
        return points
    }

    // MARK: 索引

    private var indexCard: some View {
        card {
            Text("照片分析")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)

            if let stats {
                row("可以搜尋", "\(stats.searchable) 張")
                row("已建立場景圖", "\(stats.built) 張")
                if stats.failed > 0 { row("分析失敗（下次重試）", "\(stats.failed) 張") }
            } else {
                Text(coordinator.isSupportedOS ? "讀取中…" : "需要 iOS 27 以上")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text.opacity(0.5))
            }

            if coordinator.isBuilding {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(coordinator.buildDone), total: Double(max(coordinator.buildTotal, 1)))
                        .tint(Theme.text)
                    Text("分析中 \(coordinator.buildDone) / \(coordinator.buildTotal)（只算還沒分析的照片）")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text.opacity(0.6))
                    if coordinator.reusedCount > 0 {
                        Text("幾乎一樣的照片直接沿用：\(coordinator.reusedCount) 張")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.text.opacity(0.6))
                    }
                }
            }
            // 速度：實際交給模型的照片，平均每張花多久（讀圖、模型）
            if let image = coordinator.averageImageSeconds, let model = coordinator.averageModelSeconds {
                row("平均每張", String(format: "%.1f 秒（讀圖 %.1f、模型 %.1f）", image + model, image, model))
                if coordinator.isBuilding, let remaining = coordinator.estimatedRemainingSeconds {
                    row("剩餘約", Self.durationText(remaining))
                }
            }
            if !coordinator.isBuilding, let message = coordinator.lastBuildMessage {
                Text("上次分析：\(message)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text.opacity(0.6))
            }

            TipList(title: "什麼時候會分析？", points: [
                .init("eye", "每張照片都要讓 Apple Intelligence 看一次"),
                .init("bolt", "App 開著時全速分析；停在這頁時螢幕不會自動關閉"),
                .init("pause.circle", "離開 App 就暫停，回來會接續"),
                .init("battery.100.bolt", "閒置、充電時，iOS 可能在背景慢慢分析"),
            ])

            HStack(spacing: 10) {
                if coordinator.isBuilding {
                    actionButton("暫停分析", primary: false) { coordinator.pauseByUser() }
                } else {
                    actionButton(coordinator.isPausedByUser ? "繼續分析" : "立即分析", primary: true) { coordinator.resumeByUser() }
                        .disabled(!coordinator.isAvailable)
                        .opacity(coordinator.isAvailable ? 1 : 0.4)
                }
            }
        }
    }

    // MARK: 照片文字辨識（OCR）

    private var textCard: some View {
        card {
            Text("照片文字辨識")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            if let stats = ocr.stats {
                row("已辨識", "\(stats.recognized) 張")
                row("有文字的照片", "\(stats.withText) 張")
            }
            TipList(points: [
                .init("hand.tap", "在照片頁按「辨識照片中的文字」才會辨識，不會掃整個相簿"),
                .init("iphone", "Apple Vision 在手機上讀出繁中、簡中、英文，不上傳照片"),
                .init("magnifyingglass", "辨識過的照片可以在首頁用文字搜尋"),
                .init("tag", "文字和畫面都符合的分類直接確認；只有文字提到的列入待確認"),
            ])
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoTextUpdated)) { _ in ocr.refreshStats() }
    }

    // MARK: 一致性檢查（開發用）

    private var parityCard: some View {
        card {
            Text("與 PC 版一致性檢查（開發用）")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("確認手機上的搜尋算出和 PC 版相同的結果。")
                .font(.system(size: 13))
                .foregroundColor(Theme.text.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            actionButton(isRunningParity ? "檢查中…" : "執行檢查", primary: false) {
                guard !isRunningParity else { return }
                isRunningParity = true
                Task.detached(priority: .userInitiated) {
                    let report = AbstractSearchCoordinator.shared.runParityCheck()
                    await MainActor.run {
                        parityReport = report
                        isRunningParity = false
                    }
                }
            }
            if let parityReport {
                Text(parityReport)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.text.opacity(0.8))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 工具

    static func durationText(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "不到 1 分鐘" }
        if minutes < 60 { return "\(minutes) 分鐘" }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "\(hours) 小時" : "\(hours) 小時 \(minutes % 60) 分鐘"
    }

    private func reloadStats() async {
        let value = await coordinator.indexStats()
        await MainActor.run { stats = value }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .themeCard(radius: 22)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(Theme.text.opacity(0.7))
            Spacer()
            Text(value).foregroundColor(Theme.text)
        }
        .font(.system(size: 14))
    }

    private func actionButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
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

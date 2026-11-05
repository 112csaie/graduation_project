// OrganizingCenterView.swift
//
// 整理進度：照片掃描與智慧搜尋分析集中顯示。
// tag 分類很快、會一直閃現，票根收據的文字辨識也不需要特別顯示，這兩項在背景安靜進行。
// 首頁頂端一條狀態列（有工作在跑才出現），點開看各項進度、暫停／繼續、設定智慧搜尋的分析範圍。
// 只讀取照片做分析，不會修改或刪除照片。

import SwiftUI
import UIKit

struct OrganizingStatusBar: View {
    @ObservedObject var syncVM: PhotoSyncViewModel
    @ObservedObject private var abstractSearch = AbstractSearchCoordinator.shared
    @State private var showCenter = false

    private var parts: [String] {
        var result: [String] = []
        if syncVM.isSyncing { result.append("掃描 \(Self.count(syncVM.syncedCount))/\(Self.count(syncVM.totalCount))") }
        if abstractSearch.isBuilding && abstractSearch.buildTotal > 0 {
            var text = "智慧分析 \(Self.count(abstractSearch.buildDone))/\(Self.count(abstractSearch.buildTotal))"
            if let remaining = abstractSearch.estimatedRemainingSeconds {
                text += "（約 \(AbstractSearchStatusView.durationText(remaining))）"
            }
            result.append(text)
        }
        return result
    }

    /// 千分位：3,216
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    var body: some View {
        // 外層一定要留在畫面上（就算沒有工作在跑）：進度頁是從這裡打開的，
        // 按「暫停」後狀態列消失，如果外層也跟著消失，打開的進度頁會被一起關掉。
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if !parts.isEmpty {
                Button(action: { showCenter = true }) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(Theme.text)
                            .scaleEffect(0.75)
                        Text("整理中：" + parts.joined(separator: "・"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.text.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.text.opacity(0.4))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.text.opacity(0.08))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: parts.isEmpty)
        .sheet(isPresented: $showCenter) {
            OrganizingCenterView(syncVM: syncVM)
        }
    }
}

struct OrganizingCenterView: View {
    @ObservedObject var syncVM: PhotoSyncViewModel
    @ObservedObject private var abstractSearch = AbstractSearchCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showSmartSearchDetail = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scanCard
                    smartSearchCard
                    TipList(title: "怎麼整理得比較快？", points: [
                        .init("bolt", "App 開著時最快；離開後系統只給少量背景時間"),
                        .init("sun.max", "停在這一頁時螢幕不會自動關閉"),
                        .init("powerplug", "可以接上電源放著讓它跑"),
                    ], collapsible: false)
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("整理進度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $showSmartSearchDetail) { AbstractSearchStatusView() }
    }

    // MARK: 照片掃描

    private var scanCard: some View {
        card(title: "照片掃描", icon: "photo.stack",
             detail: "算出照片特徵，用來搜尋、分類、整理相簿") {
            if syncVM.isSyncing {
                progressRow(done: syncVM.syncedCount, total: syncVM.totalCount)
            } else {
                statusText("目前沒有在掃描；有新照片時會自動開始。")
            }
            button(syncVM.isSyncing ? "暫停掃描" : "立即掃描") {
                if syncVM.isSyncing { syncVM.stopSync() } else { syncVM.startSync() }
            }
        }
    }

    // MARK: 智慧搜尋分析

    private var smartSearchCard: some View {
        card(title: "智慧搜尋分析", icon: "text.magnifyingglass",
             detail: "寫下每張照片的場景描述，用一句話找照片") {
            if !abstractSearch.isAvailable {
                statusText(abstractSearch.unavailableReason ?? "這支手機目前無法使用。")
            } else if abstractSearch.isBuilding {
                progressRow(done: abstractSearch.buildDone, total: abstractSearch.buildTotal)
                if let remaining = abstractSearch.estimatedRemainingSeconds {
                    statusText("剩下約 \(AbstractSearchStatusView.durationText(remaining))")
                }
            } else if abstractSearch.isPausedByUser {
                statusText("已暫停。按「繼續分析」繼續，或離開 App 再回來時自動接續。")
            } else {
                statusText(abstractSearch.lastBuildMessage.map { "上次：\($0)" } ?? "目前沒有在分析。")
            }

            if abstractSearch.isAvailable {
                HStack {
                    Text("分析範圍")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text.opacity(0.75))
                    Spacer()
                    Picker("分析範圍", selection: $abstractSearch.analysisRangeMonths) {
                        ForEach(AbstractSearchCoordinator.rangeOptions, id: \.months) { option in
                            Text(option.title).tag(option.months)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.text)
                }
                TipList(title: "分析範圍怎麼選？", points: [
                    .init("clock.arrow.circlepath", "照片很多時，可以先只分析最近的照片"),
                    .init("arrow.uturn.backward", "隨時可以改回「全部照片」，已分析的不會不見"),
                    .init("timer", "每張要幾秒鐘；分析完回憶筆記也會更具體"),
                ])
                HStack(spacing: 10) {
                    button(abstractSearch.isBuilding ? "暫停分析" : (abstractSearch.isPausedByUser ? "繼續分析" : "立即分析")) {
                        if abstractSearch.isBuilding { abstractSearch.pauseByUser() } else { abstractSearch.resumeByUser() }
                    }
                    button("詳細資訊") { showSmartSearchDetail = true }
                }
            }
        }
    }

    // MARK: 元件

    private func card<Content: View>(title: String, icon: String, detail: String,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            Text(detail)
                .font(.system(size: 13))
                .foregroundColor(Theme.text.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(radius: 22)
    }

    private func progressRow(done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(min(done, max(total, 1))), total: Double(max(total, 1)))
                .tint(Theme.text)
            Text("\(OrganizingStatusBar.count(done)) / \(OrganizingStatusBar.count(total))")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.text.opacity(0.7))
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(Theme.text.opacity(0.65))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Theme.text.opacity(0.12))
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

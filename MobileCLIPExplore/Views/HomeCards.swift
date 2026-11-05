// HomeCards.swift
//
// 首頁上方的兩張提示卡片：
// 1. SetupProgressCard：第一次使用（或大量新照片）時，用白話說明「現在已經可以用什麼、還在準備什麼」。
//    有工作在跑才出現；按「收起」之後只留頂端那一條整理狀態列。
// 2. CandidateReminderCard：累積了幾張「待確認 tag」時提醒你回答（不用特地進分類頁找）。
//    按「稍後」一天內不再出現。
// 兩張卡片都各自觀察狀態，掃描進度更新時只有卡片重畫，首頁其他部分不跟著重算。

import SwiftUI

// MARK: - 整理進度卡片

struct SetupProgressCard: View {
    @ObservedObject var syncVM: PhotoSyncViewModel
    @ObservedObject private var abstractSearch = AbstractSearchCoordinator.shared
    @ObservedObject private var connection = AgentConnection.shared
    @AppStorage("home.setupCardDismissed") private var dismissed = false

    @State private var tagging: (done: Int, total: Int)?
    @State private var preparing: (done: Int, total: Int)?
    @State private var showCenter = false

    private var isTagging: Bool {
        preparing != nil || (tagging.map { $0.done < $0.total } ?? false)
    }

    private var isBusy: Bool {
        syncVM.isSyncing || isTagging || (abstractSearch.isBuilding && abstractSearch.buildTotal > 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !dismissed && isBusy {
                card
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: dismissed || !isBusy)
        .onReceive(NotificationCenter.default.publisher(for: .personalizationTaggingProgress)) { note in
            if let done = note.userInfo?["preparing"] as? Int, let total = note.userInfo?["preparingTotal"] as? Int {
                preparing = done < total ? (done, total) : nil
            }
            if let done = note.userInfo?["done"] as? Int, let total = note.userInfo?["total"] as? Int {
                tagging = (done, total)
            }
        }
        .sheet(isPresented: $showCenter) { OrganizingCenterView(syncVM: syncVM) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("App 正在整理你/妳的照片")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.text)
                Spacer()
                Button("收起") { withAnimation { dismissed = true } }
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text.opacity(0.6))
            }
            Text("不用等全部完成，已經好的功能現在就能用。App 開著時整理得最快。")
                .font(.system(size: 12))
                .foregroundColor(Theme.text.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                row("用畫面搜尋照片", searchStatus)
                row("旅行相簿", syncVM.isSyncing ? .waiting("掃描完會自動整理") : .ready(nil))
                row("分類與 tag", tagStatus)
                row("智慧搜尋（用一句話找照片）", smartStatus)
                if AIRouter.onDevice {
                    row("回憶筆記、清單整理（在手機上）", .ready(nil))
                }
                if connection.state != .unknown && connection.state != .checking {
                    row(AIRouter.onDevice ? "Agent 對話" : "Agent、回憶筆記、清單整理",
                        connection.isOffline ? .needsComputer : .ready(nil))
                }
            }

            Button(action: { showCenter = true }) {
                HStack(spacing: 4) {
                    Text("查看詳細進度")
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.text.opacity(0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(radius: 22)
    }

    // MARK: 各項狀態

    private enum Status {
        case ready(String?)
        case working(String)
        case waiting(String)
        case unavailable(String)
        case needsComputer
    }

    private var searchStatus: Status {
        guard syncVM.isSyncing else { return .ready(nil) }
        if syncVM.syncedCount == 0 { return .working("掃描第一批照片中") }
        return .ready("新照片陸續加入（\(OrganizingStatusBar.count(syncVM.syncedCount))/\(OrganizingStatusBar.count(syncVM.totalCount))）")
    }

    private var tagStatus: Status {
        if let preparing { return .working("準備中 \(preparing.done)/\(preparing.total)") }
        if let tagging, tagging.done < tagging.total {
            return .working("分類中 \(OrganizingStatusBar.count(tagging.done))/\(OrganizingStatusBar.count(tagging.total))")
        }
        if syncVM.isSyncing { return .ready("掃描到的照片會邊掃邊分類") }
        return .ready(nil)
    }

    private var smartStatus: Status {
        guard abstractSearch.isAvailable else { return .unavailable("這支手機不支援，其他搜尋照常") }
        if abstractSearch.isBuilding && abstractSearch.buildTotal > 0 {
            var text = "分析中 \(OrganizingStatusBar.count(abstractSearch.buildDone))/\(OrganizingStatusBar.count(abstractSearch.buildTotal))"
            if let remaining = abstractSearch.estimatedRemainingSeconds {
                text += "，約 \(AbstractSearchStatusView.durationText(remaining))"
            }
            return .working(text + "；已分析的照片已經可以搜尋")
        }
        if abstractSearch.isPausedByUser { return .waiting("已暫停") }
        return .ready(nil)
    }

    private func row(_ title: String, _ status: Status) -> some View {
        let (icon, color, detail): (String, Color, String?) = {
            switch status {
            case .ready(let note): return ("checkmark.circle.fill", Theme.highlight, note.map { "可以用了・\($0)" } ?? "可以用了")
            case .working(let note): return ("hourglass", Color.yellow, note)
            case .waiting(let note): return ("clock", Theme.text.opacity(0.5), note)
            case .unavailable(let note): return ("minus.circle", Theme.text.opacity(0.4), note)
            case .needsComputer: return ("desktopcomputer", Color.orange, "需要連上開發者的後端（同一個 Wi-Fi）")
            }
        }()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 待確認 tag 提醒

/// 待確認 tag 的數量：首頁提醒卡片與「相簿」分頁的紅點共用。
/// tag 更新很頻繁，收到通知後延遲幾秒合併成一次，在背景讀取。
final class CandidateCounter: ObservableObject {
    static let shared = CandidateCounter()

    @Published private(set) var count = 0
    /// 待確認最多的幾個分類名稱（提醒卡片用）
    @Published private(set) var topNames: [String] = []
    private var pending: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .personalizationUpdated, object: nil, queue: .main) { [weak self] _ in
            self?.reload(delay: 3)
        }
        reload(delay: 1)
    }

    func reload(delay: Double = 0) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                guard let candidates = try? PersonalizationService.shared.candidateTags() else { return }
                let catalog = PersonalizationService.shared.catalog
                let byNode = Dictionary(grouping: candidates, by: \.nodeId)
                    .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
                let names = byNode.prefix(2).compactMap { catalog.node($0.key)?.nameZh }
                DispatchQueue.main.async {
                    self?.count = candidates.count
                    self?.topNames = names
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

struct CandidateReminderCard: View {
    /// 累積到幾張才提醒（太少不打擾）
    static let minimumCount = 5
    static let snoozeHours: Double = 24

    @AppStorage("home.candidateReminderSnoozedUntil") private var snoozedUntil: Double = 0
    @ObservedObject private var counter = CandidateCounter.shared

    private var isSnoozed: Bool { Date().timeIntervalSince1970 < snoozedUntil }
    private var count: Int { counter.count }
    private var topNames: [String] { counter.topNames }

    var body: some View {
        VStack(spacing: 0) {
            if count >= Self.minimumCount && !isSnoozed {
                card
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: count >= Self.minimumCount && !isSnoozed)
        .onAppear { counter.reload() }
    }
    /// 整張用亮色：比較像邀請，不像任務（點整張就去回答，右上角可以稍後再說）
    private var card: some View {
        NavigationLink(destination: CandidateTagReviewView()) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(Theme.onAccent)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(count) 張照片等你/妳認 tag")
                        .font(.system(size: 16, weight: .bold))
                    Text(topNames.isEmpty
                         ? "滑一滑回答是不是，之後很像的照片會自動分對"
                         : "這些是「\(topNames.joined(separator: "」「"))」嗎？滑一滑就好")
                        .font(.system(size: 12))
                        .opacity(0.75)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(Theme.onAccent)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: {
                withAnimation { snoozedUntil = Date().addingTimeInterval(Self.snoozeHours * 3600).timeIntervalSince1970 }
            }) {
                Text("稍後")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.onAccent.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .padding(6)
            .accessibilityLabel("稍後再提醒")
        }
    }
}

// InterestTrackerViews.swift
//
// 興趣紀錄：依使用者選的興趣顯示日曆（健身日曆、觀影與看展、演出足跡…），可以整理成月報筆記。
// - 「我的」頁：InterestTrackerSection（每個興趣一張卡，迷你日曆 + 本月統計）
// - 點開：InterestTrackerDetailView（月曆，有紀錄的日子顯示當天照片；整理成月報）
// 只讀取照片與 App 自己的分類資料，不修改、不刪除照片。

import SwiftUI

/// 一個興趣紀錄載入後的資料
struct TrackerSnapshot: Identifiable {
    var id: String { tracker.id }
    let tracker: InterestTracker
    let calendar: ActivityCalendar
    /// 身體相關的照片（體組成）：月報預設不放
    let sensitive: Set<String>
}

enum InterestTrackerLoader {
    /// 讀取要顯示的興趣紀錄（背景執行）
    static func loadAll() async -> [TrackerSnapshot] {
        await Task.detached(priority: .userInitiated) { () -> [TrackerSnapshot] in
            let service = PersonalizationService.shared
            let trackers = service.interestTrackers()
            let photos = service.interestTrackerPhotos(trackers)
            return trackers.map { tracker in
                let data = photos[tracker.id]
                return TrackerSnapshot(tracker: tracker,
                                       calendar: ActivityCalendar(photoDates: data?.dates ?? [:]),
                                       sensitive: data?.sensitive ?? [])
            }
        }.value
    }

    static func load(_ tracker: InterestTracker) async -> TrackerSnapshot {
        await Task.detached(priority: .userInitiated) { () -> TrackerSnapshot in
            let data = PersonalizationService.shared.interestTrackerPhotos([tracker])[tracker.id]
            return TrackerSnapshot(tracker: tracker,
                                   calendar: ActivityCalendar(photoDates: data?.dates ?? [:]),
                                   sensitive: data?.sensitive ?? [])
        }.value
    }
}

// MARK: - 「我的」頁區塊

struct InterestTrackerSection: View {
    @State private var snapshots: [TrackerSnapshot] = []
    @State private var isLoaded = false
    @State private var opened: TrackerSnapshot?
    @State private var showInactive = false

    /// 這個月有紀錄的排前面、直接顯示；沒有紀錄的收起來
    private var active: [TrackerSnapshot] {
        snapshots.filter { !$0.calendar.activeDays(inMonthOf: Date()).isEmpty }
    }
    private var inactive: [TrackerSnapshot] {
        snapshots.filter { $0.calendar.activeDays(inMonthOf: Date()).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("我的紀錄", systemImage: "calendar")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            if !isLoaded {
                ProgressView()
                    .tint(Theme.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else if snapshots.isEmpty {
                Text("在「興趣與分類偏好」選擇興趣後，這裡會出現對應的紀錄，例如健身日曆、觀影與看展。")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(active + (showInactive ? inactive : [])) { snapshot in
                        Button(action: { opened = snapshot }) {
                            TrackerCard(snapshot: snapshot)
                        }
                        .buttonStyle(.plain)
                    }
                    if active.isEmpty && !showInactive {
                        Text("這個月還沒有紀錄。")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !inactive.isEmpty {
                        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showInactive.toggle() } }) {
                            HStack(spacing: 4) {
                                Text(showInactive ? "收起本月沒有紀錄的項目" : "其他 \(inactive.count) 個本月沒有紀錄")
                                Image(systemName: showInactive ? "chevron.up" : "chevron.down")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.text.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.surface(0.1))
        .cornerRadius(16)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .personalizationUpdated)) { _ in Task { await reload() } }
        .sheet(item: $opened) { snapshot in
            InterestTrackerDetailView(tracker: snapshot.tracker, initial: snapshot)
        }
    }

    private func reload() async {
        let loaded = await InterestTrackerLoader.loadAll()
        await MainActor.run {
            snapshots = loaded
            isLoaded = true
        }
    }
}

/// 卡片：名稱、本月統計、這個月每天一格的迷你日曆
private struct TrackerCard: View {
    let snapshot: TrackerSnapshot
    private let today = Date()

    var body: some View {
        let calendar = snapshot.calendar.calendar
        let month = calendar.component(.month, from: today)
        let active = Set(snapshot.calendar.activeDays(inMonthOf: today))
        let streak = snapshot.calendar.weekStreak(asOf: today)
        let days = monthDays(calendar)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: snapshot.tracker.icon)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.text.opacity(0.85))
                    .frame(width: 22)
                Text(snapshot.tracker.titleZh)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.text.opacity(0.3))
            }
            HStack(spacing: 6) {
                Text(snapshot.tracker.summary(month: month, days: active.count))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text.opacity(0.7))
                if streak >= 2 {
                    Text("連續 \(streak) 週")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.onAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent)
                        .cornerRadius(6)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 16), spacing: 3) {
                ForEach(days, id: \.self) { day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(active.contains(day) ? Theme.highlight.opacity(0.85) : Theme.text.opacity(0.1))
                        .frame(height: 7)
                }
            }
        }
        .padding(12)
        .themeCard(radius: 22)
    }

    private func monthDays(_ calendar: Calendar) -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: today),
              let range = calendar.range(of: .day, in: .month, for: today) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: interval.start) }
    }
}

// MARK: - 月曆與月報

private struct DaySelection: Identifiable {
    let id: String
    let assetIds: [String]
}

struct InterestTrackerDetailView: View {
    let tracker: InterestTracker
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot: TrackerSnapshot?
    @State private var month: Date
    @State private var selectedDay: DaySelection?
    @State private var includeSensitive = false
    @State private var isDrafting = false
    @State private var draftMessage: String?
    @State private var savedTopic: String?
    @State private var openedNote: WikiItem?

    private let calendar = Calendar.current

    init(tracker: InterestTracker, initial: TrackerSnapshot? = nil) {
        self.tracker = tracker
        _snapshot = State(initialValue: initial)
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date())
    }

    /// 可以切換的月份：有紀錄的月份加上本月（由新到舊）
    private var months: [Date] {
        let current = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        let all = Set((snapshot?.calendar.months ?? []) + [current])
        return all.sorted(by: >)
    }

    private var monthNumber: Int { calendar.component(.month, from: month) }
    private var activeDays: [Date] { snapshot?.calendar.activeDays(inMonthOf: month) ?? [] }

    /// 月報要放的照片（預設不放身體相關的照片）
    private var reportAssetIds: [String] {
        guard let snapshot else { return [] }
        let ids = snapshot.calendar.assetIds(inMonthOf: month)
        return includeSensitive ? ids : ids.filter { !snapshot.sensitive.contains($0) }
    }

    private var monthHasSensitive: Bool {
        guard let snapshot, !snapshot.sensitive.isEmpty else { return false }
        return snapshot.calendar.assetIds(inMonthOf: month).contains { snapshot.sensitive.contains($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    monthHeader
                    statsRow
                    if snapshot == nil {
                        ProgressView().tint(Theme.text).frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        monthGrid
                    }
                    Text("依有拍照的日子計算；沒拍照的日子不會被記到。點有照片的日子可以看當天的照片。")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.text.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                    reportCard
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(tracker.titleZh)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            let fresh = await InterestTrackerLoader.load(tracker)
            await MainActor.run { snapshot = fresh }
        }
        // 在照片頁移除或加上 tag 後，日曆馬上跟著更新（移除的照片不再算進打卡）
        .onReceive(NotificationCenter.default.publisher(for: .personalizationUpdated)) { _ in
            Task {
                let fresh = await InterestTrackerLoader.load(tracker)
                await MainActor.run { snapshot = fresh }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeOverlaysForAgent)) { _ in dismiss() }
        .sheet(item: $selectedDay) { day in
            PhotoDetailModal(assetId: day.id, browseAssetIds: day.assetIds)
        }
        .sheet(item: $openedNote) { note in WikiNoteDetailView(item: note) }
    }

    // MARK: 月份與統計

    private var monthHeader: some View {
        let index = months.firstIndex(of: month) ?? 0
        let formatter = AppDateFormatters.yearMonth
        return HStack {
            Button(action: { if index + 1 < months.count { changeMonth(months[index + 1]) } }) {
                Image(systemName: "chevron.left")
            }
            .disabled(index + 1 >= months.count)
            Spacer()
            Text(formatter.string(from: month))
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.text)
            Spacer()
            Button(action: { if index > 0 { changeMonth(months[index - 1]) } }) {
                Image(systemName: "chevron.right")
            }
            .disabled(index == 0)
        }
        .font(.system(size: 17, weight: .semibold))
        .tint(Theme.text)
    }

    private func changeMonth(_ newMonth: Date) {
        month = newMonth
        includeSensitive = false
        draftMessage = nil
        savedTopic = nil
    }

    private var statsRow: some View {
        let isCurrentMonth = calendar.isDate(month, equalTo: Date(), toGranularity: .month)
        let streak = isCurrentMonth ? (snapshot?.calendar.weekStreak(asOf: Date()) ?? 0) : 0
        return HStack(spacing: 10) {
            stat("\(activeDays.count)", "有紀錄的日子")
            stat("\(snapshot?.calendar.assetIds(inMonthOf: month).count ?? 0)", "照片")
            if isCurrentMonth { stat("\(streak)", "連續週數") }
        }
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.text)
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Theme.text.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .themeCard(radius: 22)
    }

    // MARK: 月曆

    private var weekdaySymbols: [String] {
        let symbols = ["日", "一", "二", "三", "四", "五", "六"]
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var monthGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let dayCount = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let photosByDay = snapshot?.calendar.photosByDay ?? [:]
        let sensitive = snapshot?.sensitive ?? []

        return VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.text.opacity(0.4))
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<(leading + dayCount), id: \.self) { index in
                    if index < leading {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    } else if let day = calendar.date(byAdding: .day, value: index - leading, to: start) {
                        let ids = photosByDay[day] ?? []
                        // 封面優先用不是體組成的照片
                        let cover = ids.first { !sensitive.contains($0) } ?? ids.first
                        dayCell(day: day, cover: cover, ids: ids)
                    }
                }
            }
        }
    }

    private func dayCell(day: Date, cover: String?, ids: [String]) -> some View {
        let number = calendar.component(.day, from: day)
        let isToday = calendar.isDateInToday(day)
        return Button(action: {
            if let cover { selectedDay = DaySelection(id: cover, assetIds: ids) }
        }) {
            ZStack(alignment: .topLeading) {
                if let cover {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(PhotoThumbnailView(assetId: cover, pixelSize: 140))
                        .clipped()
                } else {
                    Theme.surface(0.11).aspectRatio(1, contentMode: .fit)
                }
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(cover == nil ? Theme.text.opacity(0.35) : .white)
                    .shadow(color: .black.opacity(0.8), radius: 2)
                    .padding(4)
            }
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isToday ? Theme.text.opacity(0.8) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(cover == nil)
    }

    // MARK: 月報

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(monthNumber) 月月報", systemImage: "doc.text.image")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("把這個月的照片整理成一篇筆記（\(tracker.reportTitle(month: monthNumber))），存在個人 Wiki。照片不會上傳，只送出日期、地點、分類與照片文字。")
                .font(.system(size: 12))
                .foregroundColor(Theme.text.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            if monthHasSensitive {
                Toggle(isOn: $includeSensitive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("包含體組成照片")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.text)
                        Text("預設不放進月報")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.text.opacity(0.45))
                    }
                }
                .tint(Theme.highlight)
            }

            Button(action: { Task { await draftReport() } }) {
                HStack(spacing: 8) {
                    if isDrafting { ProgressView().tint(Theme.onAccent).scaleEffect(0.8) }
                    Text(isDrafting ? "整理中…" : "整理成 \(monthNumber) 月月報")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Theme.accent.opacity(reportAssetIds.isEmpty || isDrafting ? 0.4 : 1))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(reportAssetIds.isEmpty || isDrafting)

            if let draftMessage {
                Text(draftMessage)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let savedTopic {
                Button("打開《\(savedTopic)》") {
                    Task {
                        let item = try? await WikiService.shared.item(topic: savedTopic)
                        await MainActor.run { openedNote = item }
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .tint(Theme.text)
            }
        }
        .padding(14)
        .background(Theme.surface(0.1))
        .cornerRadius(16)
    }

    private func draftReport() async {
        let ids = reportAssetIds
        guard !ids.isEmpty else { return }
        let year = calendar.component(.year, from: month)
        let note = """
        月報重點：\(tracker.reportFocusZh)
        期間：\(year) 年 \(monthNumber) 月
        活動天數：\(activeDays.count) 天（依有拍照的日子計算）
        """
        await MainActor.run {
            isDrafting = true
            draftMessage = nil
            savedTopic = nil
        }
        do {
            let result = try await PhotoMemoryService.draft(title: tracker.reportTitle(month: monthNumber), kind: "monthly",
                                                            assetIds: ids, userNote: note)
            await MainActor.run {
                isDrafting = false
                draftMessage = result.reply
                savedTopic = result.topic
            }
        } catch {
            await MainActor.run {
                isDrafting = false
                draftMessage = error.localizedDescription
            }
        }
    }
}

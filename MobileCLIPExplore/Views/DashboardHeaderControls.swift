// DashboardHeaderControls.swift
//
// 首頁上方的控制元件：模式選單（照片／主題／旅行／專屬）與掃描進度按鈕。
// 從 DashboardView.swift 拆出來（內容不變）。

import SwiftUI

enum DashboardGalleryMode: String, CaseIterable, Identifiable {
    case allPhotos = "照片"
    case dictionary = "分類"            // 個人化分類（依偏好分類、含各族群細分類）
    case metadata = "旅行"              // 自動產生的旅遊相簿
    case ip = "專屬"                   // 舊的「專屬」分頁：已合併進「我的相簿」（保留代號，舊程式碼仍可編譯）
    case mine = "我的相簿"              // 自己建的相簿：手動挑的＋專屬相簿（AI 依範例照片自動找）

    var id: String { rawValue }

    /// 「相簿」分頁的選項（「照片」是另一個分頁）。專屬相簿合併在「我的相簿」裡。
    static let albumModes: [DashboardGalleryMode] = [.dictionary, .metadata, .mine]
}

/// 「相簿」分頁上方的切換：分類／旅行／我的相簿（圓角小標籤，選中的是亮色）
struct AlbumModePicker: View {
    @Binding var mode: DashboardGalleryMode
    @ObservedObject private var candidates = CandidateCounter.shared

    var body: some View {
        HStack(spacing: 8) {
            ForEach(DashboardGalleryMode.albumModes) { item in
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { mode = item } }) {
                    HStack(spacing: 4) {
                        Text(item.rawValue)
                            .font(.system(size: 14, weight: mode == item ? .bold : .medium))
                            .lineLimit(1)
                        // 分類有待確認 tag 時顯示數量
                        if item == .dictionary && candidates.count > 0 {
                            Text("\(min(candidates.count, 99))")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red)
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundColor(mode == item ? Theme.onAccent : Theme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(mode == item ? Theme.accent : Theme.card)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(mode == item ? Color.clear : Theme.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 照片／主題／旅行／專屬 的下拉選單。獨立成 Equatable 的 View：
/// 只有目前模式改變時才重畫，掃描進度更新時選單不會被重建而自動關閉。
struct GalleryModeMenu: View, Equatable {
    let mode: DashboardGalleryMode
    let onSelect: (DashboardGalleryMode) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.mode == rhs.mode }

    var body: some View {
        Menu {
            ForEach(DashboardGalleryMode.allCases) { item in
                Button(action: { onSelect(item) }) {
                    if mode == item {
                        Label(item.rawValue, systemImage: "checkmark")
                    } else {
                        Text(item.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(mode.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.text.opacity(0.75))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.text.opacity(0.12))
            .cornerRadius(999)
        }
    }
}

/// 首頁右上角的掃描進度與開始／暫停按鈕。自己觀察 PhotoSyncViewModel，
/// 掃描進度更新時只有這裡重畫（以前整個首頁都會重畫，選單會被關掉）。
struct SyncStatusControl: View {
    @ObservedObject var syncVM: PhotoSyncViewModel

    var body: some View {
        HStack {
            // 數字顯示在下方的「整理中」狀態列，這裡只保留進度圈與暫停／開始按鈕
            Button(action: {
                if syncVM.isSyncing {
                    syncVM.stopSync() // 🌟 點擊暫停/停止
                } else {
                    syncVM.startSync() // 🌟 點擊開始
                }
            }) {
                ZStack {
                    // 進度環畫在方塊裡面（小一圈），不會被圓角方塊切到
                    if syncVM.isSyncing {
                        let progress = syncVM.totalCount > 0
                            ? CGFloat(syncVM.syncedCount) / CGFloat(syncVM.totalCount)
                            : 0
                        Circle()
                            .stroke(Theme.text.opacity(0.15), lineWidth: 3)
                            .frame(width: 30, height: 30)
                        Circle()
                            .trim(from: 0, to: max(0.03, progress))
                            .stroke(Theme.highlight, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 30, height: 30)
                            .animation(.easeInOut(duration: 0.3), value: progress)
                    }

                    // 中間圖示
                    Image(systemName: syncVM.isSyncing ? "pause.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: syncVM.isSyncing ? 11 : 16, weight: .bold))
                        .foregroundColor(Theme.text)
                }
                .frame(width: 44, height: 44)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
            }
        }
    }
}

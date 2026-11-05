// PhotoSelectionViews.swift
//
// 多選照片的共用元件（搜尋結果、分類／相簿、相似照片都用這一套）：
// - SelectionCheckmark：縮圖上的勾選圈
// - PhotoSelectionBar：選取時底部的動作列（加入我的相簿、分享、最愛、從這裡移除）
// - AddPhotosToAlbumSheet：一次把多張照片加入「我的相簿」（或建立新的）
// - PhotoShareLoader：讀取要分享的照片
// 「我的相簿」只記錄照片的參照，不會複製、移動或修改原始照片；「從這裡移除」也只影響 App 裡的分類或相簿。

import Photos
import SwiftUI
import UIKit

struct SelectionCheckmark: View {
    let selected: Bool

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(selected ? Theme.onAccent : .white.opacity(0.9), selected ? Theme.accent : Color.black.opacity(0.25))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .padding(8)
    }
}

/// 選取模式的狀態
struct PhotoSelectionState {
    var isSelecting = false
    var selected: Set<String> = []

    mutating func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    mutating func end() {
        isSelecting = false
        selected = []
    }

    /// 依畫面上的順序
    func ordered(_ visible: [String]) -> [String] { visible.filter { selected.contains($0) } }
}

struct PhotoSelectionBar: View {
    let count: Int
    let allSelected: Bool
    let onSelectAll: () -> Void
    let onAddToAlbum: () -> Void
    let onShare: () -> Void
    var onFavorite: (() -> Void)? = nil
    /// 例如「從此分類移除」「從相簿移除」；nil 不顯示
    var removeTitle: String? = nil
    var onRemove: (() -> Void)? = nil
    let onDone: () -> Void

    @State private var confirmRemove = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button(allSelected ? "取消全選" : "全選", action: onSelectAll)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Text(count == 0 ? "選擇照片" : "已選 \(count) 張")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("完成", action: onDone)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(Theme.text)

            HStack(spacing: 0) {
                action("加入相簿", icon: "rectangle.stack.badge.plus", action: onAddToAlbum)
                action("分享", icon: "square.and.arrow.up", action: onShare)
                if let onFavorite { action("最愛", icon: "heart", action: onFavorite) }
                if let removeTitle, onRemove != nil {
                    action(removeTitle, icon: "minus.circle", role: .destructive) { confirmRemove = true }
                }
            }
            .disabled(count == 0)
            .opacity(count == 0 ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface(0.12).opacity(0.97))
        .cornerRadius(18)
        .padding(.horizontal, 12)
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
        .confirmationDialog("\(removeTitle ?? "移除")（\(count) 張）？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(removeTitle ?? "移除", role: .destructive) { onRemove?() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只影響 App 裡的分類或相簿，照片本身不會被刪除。")
        }
    }

    private func action(_ title: String, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundColor(role == .destructive ? .red : Theme.text)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 選取動作（放在列表上方的同一列，不蓋住照片）

/// 選取模式時，放在「已選 N 張」和排序按鈕中間的一排圓形按鈕：全選、加入相簿、分享、最愛、移除。
struct PhotoSelectionInlineActions: View {
    let count: Int
    let allSelected: Bool
    let onSelectAll: () -> Void
    let onAddToAlbum: () -> Void
    let onShare: () -> Void
    var onFavorite: (() -> Void)? = nil
    var removeTitle: String? = nil
    var onRemove: (() -> Void)? = nil

    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 5) {
            circle(allSelected ? "checklist.unchecked" : "checklist", label: allSelected ? "取消全選" : "全選",
                   enabled: true, action: onSelectAll)
            circle("rectangle.stack.badge.plus", label: "加入相簿", enabled: count > 0, action: onAddToAlbum)
            circle("square.and.arrow.up", label: "分享", enabled: count > 0, action: onShare)
            if let onFavorite { circle("heart", label: "最愛", enabled: count > 0, action: onFavorite) }
            if let removeTitle, onRemove != nil {
                circle("minus", label: removeTitle, enabled: count > 0, destructive: true) { confirmRemove = true }
            }
        }
        .confirmationDialog("\(removeTitle ?? "移除")（\(count) 張）？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(removeTitle ?? "移除", role: .destructive) { onRemove?() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只影響 App 裡的分類或相簿，照片本身不會被刪除。")
        }
    }

    private func circle(_ icon: String, label: String, enabled: Bool, destructive: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(destructive ? .red : Theme.text)
                .frame(width: 34, height: 34)
                .background(Theme.card)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

// MARK: - 一次加入我的相簿

struct AddPhotosToAlbumSheet: View {
    let assetIds: [String]
    /// 完成後的訊息，例如「已加入「日本旅行」12 張」
    let onFinished: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var albums: [CustomAlbumSummary] = []
    @State private var newTitle = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List {
                Section("建立新的相簿") {
                    HStack {
                        TextField("例如：2026 日本旅行", text: $newTitle)
                        Button("建立") { create() }
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.system(size: 13)).foregroundColor(.orange)
                    }
                }
                Section("加入現有的相簿") {
                    if albums.isEmpty {
                        Text("還沒有我的相簿").foregroundColor(.secondary)
                    }
                    ForEach(albums) { album in
                        Button(action: { add(to: album) }) {
                            HStack {
                                Text(album.title).foregroundColor(.primary)
                                Spacer()
                                Text("\(album.photoCount) 張").font(.system(size: 13)).foregroundColor(.secondary)
                            }
                        }
                        .disabled(isWorking)
                    }
                }
                Section {
                    Text("只會記錄照片的參照，不會複製或移動照片檔案。已經在相簿裡的照片不會重複加入。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("加入我的相簿（\(assetIds.count) 張）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .task {
            albums = await Task.detached(priority: .userInitiated) { DatabaseManager.shared.fetchCustomAlbums() }.value
        }
    }

    private func add(to album: CustomAlbumSummary) {
        isWorking = true
        let ids = assetIds
        Task {
            await Task.detached(priority: .userInitiated) {
                DatabaseManager.shared.addPhotos(ids, toCustomAlbum: album.id)
            }.value
            await MainActor.run {
                onFinished("已加入「\(album.title)」")
                dismiss()
            }
        }
    }

    private func create() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        let ids = assetIds
        Task {
            let result: String? = await Task.detached(priority: .userInitiated) { () -> String? in
                if DatabaseManager.shared.customAlbumExists(named: title) { return "已經有名為「\(title)」的相簿，可以直接在下面選它。" }
                return DatabaseManager.shared.createCustomAlbum(title: title, assetIds: ids) == nil ? "無法建立相簿，請再試一次。" : nil
            }.value
            await MainActor.run {
                isWorking = false
                if let result {
                    errorMessage = result
                } else {
                    onFinished("已建立「\(title)」（\(ids.count) 張）")
                    dismiss()
                }
            }
        }
    }
}

// MARK: - 分享多張

/// 要分享的照片。用 .sheet(item:) 打開分享視窗：照片準備好才建立分享畫面，
/// 不會像 .sheet(isPresented:) 那樣拿到還沒更新的內容，打開一個空白的視窗。
struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

enum PhotoShareLoader {
    /// 一次最多分享的張數（太多張會佔用大量記憶體）
    static let maxCount = 30

    static func images(for assetIds: [String], maxSide: CGFloat = 2048) async -> [UIImage] {
        let ids = Array(assetIds.prefix(maxCount))
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byId: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in byId[asset.localIdentifier] = asset }
        var images: [UIImage] = []
        for id in ids {
            guard let asset = byId[id] else { continue }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            let image: UIImage? = await withCheckedContinuation { continuation in
                var resumed = false
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: maxSide, height: maxSide),
                                                      contentMode: .aspectFit, options: options) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !degraded || image == nil, !resumed else { return }
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
            if let image { images.append(image) }
        }
        return images
    }
}

/// 加入最愛：選取的照片只要有一張不是最愛，就全部設成最愛；全部都是最愛時全部取消
enum PhotoFavoriteBatch {
    static func toggle(_ assetIds: [String]) -> String {
        let db = DatabaseManager.shared
        let allFavorite = assetIds.allSatisfy { db.isFavorite(assetId: $0) }
        for id in assetIds where db.isFavorite(assetId: id) == allFavorite {
            db.toggleFavorite(assetId: id)
        }
        return allFavorite ? "已取消最愛（\(assetIds.count) 張）" : "已加入最愛（\(assetIds.count) 張）"
    }
}

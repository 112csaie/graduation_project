// DashboardAlbumCards.swift
//
// 首頁的相簿卡片與封面元件：圓角封面、亮色張數標籤、旅行的日期貼紙、分類的拼貼方塊（CollageTile）。

import SwiftUI
import Photos
import UIKit

struct CategoryAlbumSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let coverAssetId: String?
    let photoCount: Int
}

struct AddCustomAlbumCard: View {
    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.secondaryText, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .frame(width: 160, height: 160)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Theme.onAccent)
                        .frame(width: 42, height: 42)
                        .background(Theme.accent)
                        .clipShape(Circle())
                )
            Text("新相簿")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
        }
    }
}

/// 一般相簿卡：圓角封面，張數用亮色小標籤放在封面右下角
struct CategoryAlbumCard: View {
    let album: CategoryAlbumSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumCoverView(assetId: album.coverAssetId)
                .overlay(alignment: .bottomTrailing) {
                    AccentPill(text: "\(album.photoCount)").padding(8)
                }
            Text(album.title.capitalized)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .frame(width: 160, alignment: .leading)
    }
}

struct CustomAlbumCard: View {
    let album: CustomAlbumSummary

    var body: some View {
        CategoryAlbumCard(album: CategoryAlbumSummary(id: album.id, title: album.title,
                                                      coverAssetId: album.coverAssetId, photoCount: album.photoCount))
    }
}

/// 旅行相簿卡：封面左上角一張日期貼紙
struct MetadataAlbumCard: View {
    let album: MetadataAlbumSummary

    /// 貼紙只放地點、日期、天數；張數已經在右下角，不重複
    private var stickerText: String {
        album.subtitle
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix("張") && !$0.hasSuffix("張照片") }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumCoverView(assetId: album.coverAssetId)
                .overlay(alignment: .bottomTrailing) {
                    AccentPill(text: "\(album.photoCount)").padding(8)
                }
                .overlay(alignment: .topLeading) {
                    if !stickerText.isEmpty {
                        StickerLabel(text: stickerText)
                            .padding(8)
                    }
                }
            Text(album.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.text)
                .lineLimit(2)
                .padding(.horizontal, 2)
        }
        .frame(width: 160, alignment: .leading)
    }
}

/// 小貼紙（日期、地點）
struct StickerLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.onAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.accent)
            .clipShape(Capsule())
            .frame(maxWidth: 144, alignment: .leading)
    }
}

/// 拼貼用的照片方塊：照片填滿、下方淡淡的漸層，白字名稱＋亮色張數。大小由外面決定。
struct CollageTile: View {
    let title: String
    let count: Int?
    let assetId: String?
    /// 右上角的小圖示（例如專屬相簿的吊牌）
    var badge: String? = nil

    var body: some View {
        Theme.tile
            .overlay {
                if let assetId {
                    PhotoThumbnailView(assetId: assetId, pixelSize: 500)
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 24))
                        .foregroundColor(Theme.secondaryText)
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let count { AccentPill(text: "\(count)") }
                }
                .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.onAccent)
                        .frame(width: 26, height: 26)
                        .background(Theme.accent)
                        .clipShape(Circle())
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - 相簿封面元件
struct AlbumCoverView: View {
    let assetId: String?
    @State private var image: UIImage? = nil
    @State private var isMissing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.tile)
                .frame(width: 160, height: 160)

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .transition(.opacity)
            } else if isMissing {
                Image(systemName: "photo.slash")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(Theme.text.opacity(0.55))
            }
        }
        .onAppear { loadImage() }
        .onChange(of: assetId) { _, _ in loadImage() }
        .animation(.easeInOut(duration: 0.3), value: image)
    }

    private func loadImage() {
        guard let assetId = assetId else {
            image = nil
            isMissing = true
            return
        }

        image = nil
        isMissing = false
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else {
            isMissing = true
            return
        }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        manager.requestImage(
            for: asset,
            targetSize: CGSize(width: 280, height: 360),
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            if let result = result {
                DispatchQueue.main.async {
                    image = result
                    isMissing = false
                }
            } else {
                DispatchQueue.main.async {
                    image = nil
                    isMissing = true
                }
            }
        }
    }
}


// MARK: - 建立新相簿：AI 找或自己挑

enum NewAlbumKind { case ai, manual }

/// 從下方升起的選擇畫面：兩張大卡片，AI 找（亮色）或自己挑
struct NewAlbumChoiceSheet: View {
    let onChoose: (NewAlbumKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("建立新相簿")
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(Theme.text)
                .padding(.top, 26)
            choice(kind: .ai, icon: "tag.fill", title: "AI 幫我找照片",
                   detail: "給幾張範例（寵物、角色、收藏品…），AI 從圖庫找出同一個主角，之後拍的也會自動加進來。",
                   filled: true)
            choice(kind: .manual, icon: "hand.tap", title: "自己挑照片",
                   detail: "相簿只放你/妳選的照片，也可以用一句話先找出來再挑。",
                   filled: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
    }

    private func choice(kind: NewAlbumKind, icon: String, title: String, detail: String, filled: Bool) -> some View {
        Button(action: { onChoose(kind) }) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(filled ? Theme.accent : Theme.text)
                    .frame(width: 48, height: 48)
                    .background(filled ? Theme.onAccent : Theme.tile)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold))
                    Text(detail)
                        .font(.system(size: 13))
                        .opacity(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundColor(filled ? Theme.onAccent : Theme.text)
            .padding(16)
            .background(filled ? Theme.accent : Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(filled ? Color.clear : Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI
import Photos

/// 縮圖快取：同一張照片、同樣大小的縮圖只跟照片庫要一次；捲回來時直接顯示。
/// 只讀取照片，不修改照片。記憶體不足時系統會自動清掉快取。
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()
    /// 查詢 PHAsset 放在背景，不卡主執行緒（捲動時每格都要查一次）
    let queue = DispatchQueue(label: "com.photoai.thumbnail", qos: .userInitiated, attributes: .concurrent)

    private init() {
        cache.countLimit = 800
        cache.totalCostLimit = 120 * 1024 * 1024   // 約 120 MB
    }

    static func key(_ assetId: String, _ pixelSize: CGFloat) -> NSString {
        "\(assetId)|\(Int(pixelSize))" as NSString
    }

    func image(for key: NSString) -> UIImage? { cache.object(forKey: key) }

    func store(_ image: UIImage, for key: NSString) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key, cost: cost)
    }
}

struct PhotoThumbnailView: View {
    let assetId: String
    /// 要求的縮圖邊長（像素）。格子變大時（例如每行只顯示 2 張）要給大一點，不然會糊
    var pixelSize: CGFloat = 250
    @State private var image: UIImage? = nil
    @State private var isUnavailable = false
    /// 最近一次要求的照片（@State 存在 View 外面，callback 裡讀到的是最新值）
    @State private var requestedAssetId: String?
    /// 進行中的讀取；捲出畫面時取消，避免快速捲動時排一長串用不到的讀取
    @State private var requestId: PHImageRequestID?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isUnavailable {
                ZStack {
                    Theme.secondaryText.opacity(0.18)
                    Image(systemName: "photo.slash")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(Theme.text.opacity(0.65))
                }
            } else {
                Theme.secondaryText.opacity(0.3)
            }
        }

        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // scaledToFill 的圖片會超出格子；不裁切的話，超出的部分也能被點到，
        // 點一張照片常會打開上面或下面那張。裁切並把可點範圍限制在格子內。
        .clipped()
        .contentShape(Rectangle())
        .onAppear {
            fetchImage()
        }
        .onDisappear {
            cancelRequest()
        }
        .onChange(of: pixelSize) { _, _ in
            fetchImage(keepCurrent: true)   // 換解析度時先保留目前的圖，避免閃一下
        }
        // 同一個格子換成另一張照片（例如日曆切換月份、清單重新排序）：onAppear 不會再觸發，要自己重新讀取
        .onChange(of: assetId) { _, _ in
            fetchImage()
        }
    }

    private func cancelRequest() {
        if let requestId {
            ThumbnailCache.shared.manager.cancelImageRequest(requestId)
            self.requestId = nil
        }
    }

    private func fetchImage(keepCurrent: Bool = false) {
        cancelRequest()
        let requestedId = assetId
        let size = pixelSize
        requestedAssetId = requestedId
        isUnavailable = false

        let key = ThumbnailCache.key(requestedId, size)
        if let cached = ThumbnailCache.shared.image(for: key) {
            image = cached
            return
        }
        if !keepCurrent { image = nil }

        ThumbnailCache.shared.queue.async {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [requestedId], options: nil).firstObject else {
                DispatchQueue.main.async {
                    guard requestedId == self.requestedAssetId else { return }
                    self.image = nil
                    self.isUnavailable = true
                }
                return
            }

            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true // 允許從 iCloud 下載
            options.deliveryMode = .opportunistic // 先給低畫質，再給高畫質

            let id = ThumbnailCache.shared.manager.requestImage(
                for: asset, targetSize: CGSize(width: size, height: size), contentMode: .aspectFill, options: options
            ) { result, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if let result, !isDegraded { ThumbnailCache.shared.store(result, for: key) }
                DispatchQueue.main.async {
                    // 讀取期間格子已換成別張照片：丟掉舊結果，避免顯示錯的縮圖
                    guard requestedId == self.requestedAssetId else { return }
                    if let result {
                        self.image = result
                        self.isUnavailable = false
                    } else if (info?[PHImageCancelledKey] as? Bool) != true, self.image == nil {
                        self.isUnavailable = true
                    }
                    if !isDegraded { self.requestId = nil }
                }
            }
            DispatchQueue.main.async {
                if requestedId == self.requestedAssetId { self.requestId = id }
            }
        }
    }
}

import Photos
import UIKit
import CoreImage

struct ScannedPhoto {
    let assetId: String
    let metadata: String
    let cgImage: CGImage
}

@Observable
class PhotoLibraryScanner {
    private var framesContinuation: AsyncStream<ScannedPhoto>.Continuation?

    public func attach(continuation: AsyncStream<ScannedPhoto>.Continuation) {
        self.framesContinuation = continuation
    }

    public func startScanning() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                print("未取得相簿讀取權限")
                return
            }

            let allPhotos = PHAsset.fetchAssets(with: .image, options: nil)
            
            let imageManager = PHImageManager.default()
            let requestOptions = PHImageRequestOptions()
            requestOptions.isSynchronous = true // 完美避開 OOM
            requestOptions.deliveryMode = .highQualityFormat

            Task.detached {
                allPhotos.enumerateObjects { asset, index, stop in
                    let targetSize = CGSize(width: 256, height: 256)
                    let assetId = asset.localIdentifier
                    let metadata = asset.creationDate?.description ?? "Unknown Date"
                    
                    imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: requestOptions) { image, _ in
                        if let cgImage = image?.cgImage {
                            // 將三個重要資訊打包送出
                            let photoData = ScannedPhoto(assetId: assetId, metadata: metadata, cgImage: cgImage)
                            self.framesContinuation?.yield(photoData)
                        }
                    }
                }
                self.framesContinuation?.finish()
            }
        }
    }
}

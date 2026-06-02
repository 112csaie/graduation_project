import SwiftUI
import Photos

struct PhotoThumbnailView: View {
    let assetId: String
    @State private var image: UIImage? = nil
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // 還沒載入完成或找不到照片時，顯示你原來的灰色
                Color.gray.opacity(0.3)
            }
        }

        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onAppear {
            fetchImage()
        }
    }
    
    private func fetchImage() {
        // 透過 ID 尋找相簿裡的照片
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else { return }
        
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true // 允許從 iCloud 下載
        options.deliveryMode = .opportunistic // 先給低畫質，再給高畫質
        
        manager.requestImage(for: asset, targetSize: CGSize(width: 250, height: 250), contentMode: .aspectFill, options: options) { result, _ in
            if let result = result {
                DispatchQueue.main.async {
                    self.image = result
                }
            }
        }
    }
}

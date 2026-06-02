import Foundation
import Photos
import CoreML
import UIKit

class PhotoSyncViewModel: ObservableObject {
    
    @Published var isSyncing = false
    @Published var syncedCount = 0
    @Published var totalCount = 0
    
    private let imageModel = try? mobileclip_s2_image(configuration: MLModelConfiguration())

    func startSync() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            guard status == .authorized || status == .limited else {
                print("未取得相簿權限")
                return
            }
            
            DispatchQueue.main.async {
                self?.isSyncing = true
                self?.fetchAndProcessPhotos()
            }
        }
    }
    
    private func fetchAndProcessPhotos() {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let allAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
            
            // 🌟 1. 取得資料庫中「所有」已經處理過的 asset_id (包含被歸類為 -1 的)
            let scannedIds = DatabaseManager.shared.fetchAllScannedAssetIds() // 確保 DatabaseManager 有這個方法
            
            // 🌟 2. 快速過濾出「還沒掃描過」的新照片
            var unscannedAssets: [PHAsset] = []
            allAssets.enumerateObjects { (asset, _, _) in
                if !scannedIds.contains(asset.localIdentifier) {
                    unscannedAssets.append(asset)
                }
            }
            
            // 🌟 3. 如果沒有新照片，直接結束！不再浪費效能！
            guard !unscannedAssets.isEmpty else {
                DispatchQueue.main.async {
                    self.isSyncing = false
                    print("所有照片都已是最新的，無需掃描。")
                }
                return
            }
            DispatchQueue.main.async {
                self.totalCount = unscannedAssets.count
                self.syncedCount = 0
            }
            
            DispatchQueue.global(qos: .userInitiated).async {
                for asset in unscannedAssets {
                    let assetId = asset.localIdentifier
                    var metadataDict: [String: Any] = [:]
                    if let date = asset.creationDate { metadataDict["date"] = date.description }
                    if let location = asset.location {
                        metadataDict["latitude"] = location.coordinate.latitude
                        metadataDict["longitude"] = location.coordinate.longitude
                    }
                    
                    let metadata: String
                    if let jsonData = try? JSONSerialization.data(withJSONObject: metadataDict),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        metadata = jsonString
                    } else { metadata = "{}" }
                    
                    let semaphore = DispatchSemaphore(value: 0)
                    self.requestPixelBuffer(for: asset) { pixelBuffer in
                        defer { semaphore.signal() }
                        guard let pixelBuffer = pixelBuffer, let model = self.imageModel else { return }
                        
                        do {
                            let input = mobileclip_s2_imageInput(image: pixelBuffer)
                            let prediction = try model.prediction(input: input)
                            let rawEmbedding = prediction.final_emb_1
                            let normalizedArray = rawEmbedding.toFloatArray().normalized()
                            let embeddingData = Data(buffer: UnsafeBufferPointer(start: normalizedArray, count: normalizedArray.count))
                            
                            DatabaseManager.shared.insertPhotoFeature(
                                assetId: assetId,
                                metadata: metadata,
                                embeddingData: embeddingData
                            )
                            
                            DispatchQueue.main.async { self.syncedCount += 1 }
                        } catch {
                            print("照片 \(assetId) 推論失敗：\(error)")
                        }
                    }
                    semaphore.wait()
                }
                
                DispatchQueue.main.async {
                    self.isSyncing = false
                    print("掃描完成！共新增處理 \(self.syncedCount) 張照片。")
                }
            }
        }
    
    private func requestPixelBuffer(for asset: PHAsset, completion: @escaping (CVPixelBuffer?) -> Void) {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        
        let targetSize = CGSize(width: 256, height: 256)
        
        manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, _ in
            guard let uiImage = image, let cgImage = uiImage.cgImage else {
                completion(nil)
                return
            }
            let pixelBuffer = self.pixelBuffer(from: cgImage, size: targetSize)
            completion(pixelBuffer)
        }
    }
    
    private func pixelBuffer(from image: CGImage, size: CGSize) -> CVPixelBuffer? {
        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        var pxbuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width),
                                         Int(size.height),
                                         kCVPixelFormatType_32ARGB,
                                         options as CFDictionary,
                                         &pxbuffer)
        
        guard status == kCVReturnSuccess, let buffer = pxbuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, .init(rawValue: 0))
        let pxdata = CVPixelBufferGetBaseAddress(buffer)
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: pxdata,
                                width: Int(size.width),
                                height: Int(size.height),
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: rgbColorSpace,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        
        context?.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        CVPixelBufferUnlockBaseAddress(buffer, .init(rawValue: 0))
        
        return buffer
    }
}

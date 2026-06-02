import SwiftUI
import Photos
import CoreLocation

struct FullPhotoDetailView: View {
    let assetId: String
    @State private var image: UIImage? = nil
    
    // 解析後的資料 (改為 Optional，預設為 nil)
    @State private var tag: String? = nil
    @State private var dateString: String? = nil
    @State private var locationString: String? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                
                // 1. 滿版照片展示
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: UIScreen.main.bounds.width)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(white: 0.1))
                        .frame(height: 400)
                        .overlay(ProgressView().tint(.white))
                }
                
                // 2. 現代化資訊卡片 (動態顯示)
                VStack(spacing: 16) {
                    if let tag = tag, !tag.isEmpty, tag.lowercased() != "unknown" {
                        InfoRow(icon: "tag.fill", iconColor: .blue, title: "Tag", value: tag.capitalized)
                    }

                    if let date = dateString {
                        Divider().background(Color.white.opacity(0.2))
                        InfoRow(icon: "calendar", iconColor: .red, title: "Date", value: date)
                    }
                    
                    if let location = locationString {
                        Divider().background(Color.white.opacity(0.2))
                        InfoRow(icon: "mappin.and.ellipse", iconColor: .green, title: "Location", value: location)
                    }
                }
                .padding(20)
                .background(Color(white: 0.12))
                .cornerRadius(20)
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            loadImage()
            loadDetails()
        }
    }
    
    // MARK: - 載入圖片
    private func loadImage() {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else { return }
        
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        
        manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { result, _ in
            DispatchQueue.main.async { self.image = result }
        }
    }
    
    // MARK: - 載入與解析 Metadata
    private func loadDetails() {
        if let detail = DatabaseManager.shared.fetchPhotoDetail(assetId: assetId) {
            let t = detail.tag.trimmingCharacters(in: .whitespacesAndNewlines)
            self.tag = (t.isEmpty || t.lowercased() == "unknown") ? nil : t
            parseMetadata(detail.metadata)
        }
    }
    
    // MARK: - JSON 解析與經緯度轉換
    private func parseMetadata(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        // 1. 處理日期
        if let rawDate = dict["date"] as? String {
            self.dateString = formatRawDate(rawDate)
        }
        
        // 2. 處理經緯度 (轉換為真實地址)
        if let lat = dict["latitude"] as? Double, let lon = dict["longitude"] as? Double {
            reverseGeocode(latitude: lat, longitude: lon)
        }
    }
    
    // 轉換日期格式
    private func formatRawDate(_ raw: String) -> String {
        let formatter = DateFormatter()
        
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        if let date = formatter.date(from: raw) {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: raw) {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        
        return raw
    }
    
    // 經緯度反查地址
    private func reverseGeocode(latitude: Double, longitude: Double) {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            guard error == nil, let placemark = placemarks?.first else {
                DispatchQueue.main.async { self.locationString = "\(latitude), \(longitude)" }
                return
            }
            
            var addressParts: [String] = []
            if let city = placemark.locality { addressParts.append(city) }
            if let country = placemark.country { addressParts.append(country) }
            
            DispatchQueue.main.async {
                self.locationString = addressParts.isEmpty ? "\(latitude), \(longitude)" : addressParts.joined(separator: ", ")
            }
        }
    }
}

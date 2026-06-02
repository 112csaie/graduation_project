import SwiftUI
import Photos
import CoreLocation

struct PhotoDetailModal: View {
    let assetId: String
    @Environment(\.dismiss) var dismiss
    
    @State private var image: UIImage? = nil
    @State private var tag: String? = nil
    @State private var dateString: String? = nil
    @State private var locationString: String? = nil
    
    private var hasAnyInfo: Bool {
        tag != nil || dateString != nil || locationString != nil
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 照片顯示區
                    if let img = image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: UIScreen.main.bounds.height * 0.55)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: UIScreen.main.bounds.height * 0.55)
                            .overlay(ProgressView().tint(.white))
                    }
                    
                    // 資訊卡片區
                    if hasAnyInfo {
                        VStack(alignment: .leading, spacing: 16) {
                            if let validTag = tag {
                                InfoRow(icon: "tag.fill", iconColor: .blue, title: "Tag", value: validTag)
                            }
                            
                            if let date = dateString {
                                if tag != nil { Divider().background(Color.gray.opacity(0.3)) }
                                InfoRow(icon: "calendar", iconColor: .red, title: "Date", value: date)
                            }
                            
                            if let loc = locationString {
                                if dateString != nil || tag != nil { Divider().background(Color.gray.opacity(0.3)) }
                                InfoRow(icon: "mappin.and.ellipse", iconColor: .green, title: "Location", value: loc)
                            }
                        }
                        .padding()
                        .background(Color(white: 0.15))
                        .cornerRadius(16)
                        .padding(20)
                    }
                    Spacer()
                }
            }
            .navigationTitle(dateString ?? "Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                            Text("Back")
                        }
                    }
                }
            }
            .onAppear { loadDetails() }
        }
    }
    
    private func loadDetails() {
        // 🌟 1. 直接從原生相簿 (PHAsset) 撈取真實的時間與地點
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        if let asset = fetchResult.firstObject {
            
            // 取得真實日期
            if let creationDate = asset.creationDate {
                self.dateString = formatDate(creationDate)
            }
            
            // 取得真實地點
            if let location = asset.location {
                fetchLocationName(location: location)
            }
            
            // 取得高畫質照片
            let manager = PHImageManager.default()
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            
            manager.requestImage(for: asset, targetSize: CGSize(width: 1000, height: 1000), contentMode: .aspectFit, options: options) { img, _ in
                DispatchQueue.main.async { self.image = img }
            }
        }
        
        // 🌟 2. 只有 Tag 從資料庫撈 (如果有被 AI 掃描過的話)
        if let detail = DatabaseManager.shared.fetchPhotoDetail(assetId: assetId) {
            self.tag = (detail.tag == "Unknown" || detail.tag.isEmpty) ? nil : detail.tag.capitalized
        }
    }
    
    // 直接處理 Date 物件
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    // 直接處理 CLLocation 物件
    private func fetchLocationName(location: CLLocation) {
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            if let place = placemarks?.first {
                let city = place.locality ?? place.administrativeArea ?? ""
                let country = place.country ?? ""
                let combined = [city, country].filter { !$0.isEmpty }.joined(separator: ", ")
                
                DispatchQueue.main.async {
                    self.locationString = combined.isEmpty ? "\(location.coordinate.latitude), \(location.coordinate.longitude)" : combined
                }
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).foregroundColor(iconColor).font(.system(size: 20)).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).foregroundColor(.gray)
                Text(value).font(.system(size: 16)).foregroundColor(.white)
            }
            Spacer()
        }
    }
}

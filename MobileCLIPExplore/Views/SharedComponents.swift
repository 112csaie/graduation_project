import SwiftUI

// MARK: - 頂部頭像 (靠左)
struct HeaderSection: View {
    var body: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(Color(red: 0.85, green: 0.85, blue: 0.85))
                    .frame(width: 44, height: 44)
                
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 20)
            
            Spacer()
        }
    }
}

// MARK: - 卡片內的單張圖片框
struct AlbumItem: View {
    let assetId: String // 接收真實的 assetId
    
    var body: some View {
        // 使用你寫好的照片讀取元件
        PhotoThumbnailView(assetId: assetId)
    }
}

// MARK: - 分類卡片元件
struct CategoryCard: View {
    let title: String
    let assetIds: [String]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            // 卡片標題
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 15)
                .padding(.leading, 15)
            
            // 橫向滑動的照片列表
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 15) {
                    // 若有照片則顯示，若沒有則顯示空框 (符合你設計圖的樣式)
                    if assetIds.isEmpty {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.65, green: 0.65, blue: 0.65))
                            .frame(width: 120, height: 120)
                    } else {
                        ForEach(assetIds, id: \.self) { id in
                            PhotoThumbnailView(assetId: id)
                                .frame(width: 120, height: 120)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 15)
            }
        }

        .background(Color(red: 0.23, green: 0.23, blue: 0.23))
        .cornerRadius(12)
    }
}
// MARK: - 底部導覽列
struct BottomNavBar: View {
    // 🌟 接收外部傳進來的狀態：0=Home, 1=Agent, 2=Setting
    @Binding var selectedTab: Int
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.2))
            
            HStack {
                Spacer()
                NavBarItem(iconName: "house", tabIndex: 0, selectedTab: $selectedTab, isSystemIcon: false)
                Spacer()
                NavBarItem(iconName: "AI agent", tabIndex: 1, selectedTab: $selectedTab, isSystemIcon: false)
                Spacer()
                NavBarItem(iconName: "setting", tabIndex: 2, selectedTab: $selectedTab, isSystemIcon: false)
                Spacer()
            }
            .padding(.vertical, 15)
            .background(Color(red: 0.1, green: 0.1, blue: 0.1).ignoresSafeArea())
        }
    }
}

// MARK: - 底部導覽列按鈕
struct NavBarItem: View {
    let iconName: String
    let tabIndex: Int
    @Binding var selectedTab: Int
    var isSystemIcon: Bool = true
    
    var body: some View {
        Button(action: {
            // 🌟 點擊時，改變當前的分頁狀態
            selectedTab = tabIndex
        }) {
            if isSystemIcon {
                Image(systemName: iconName)
                    .font(.system(size: 24))
                    // 根據是否選中來改變顏色
                    .foregroundColor(selectedTab == tabIndex ? .white : .gray)
            } else {
                Image(iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    // 如果你的自訂圖標支援渲染，可以透過 opacity 區分選中狀態
                    .opacity(selectedTab == tabIndex ? 1.0 : 0.5)
            }
        }
    }
}

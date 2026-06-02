import SwiftUI
import PhotosUI

// MARK: - 1. 原生分享介面 (ShareSheet) 保持不變
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 2. 更新主畫面
struct CategoryDetailView: View {
    @Environment(\.dismiss) var dismiss
    let categoryTitle: String
    
    @ObservedObject var syncVM: PhotoSyncViewModel
    
    @State private var searchText: String = ""
    @State private var selectedTab: Int = 0
    @State private var photos: [(id: String, isFavorite: Bool, tag: String, date: String)] = []
    @State private var availableAlbums: [String] = []
    
    // 狀態控制：刪除確認與分享
    @State private var showDeleteAlert = false
    @State private var photoToDelete: String? = nil
    
    @State private var showShareSheet = false
    @State private var imageToShare: UIImage? = nil
    
    // 控制選取照片的陣列
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    
    var displayPhotos: [String] {
        let base = selectedTab == 1 ? photos.filter { $0.isFavorite } : photos
        guard !searchText.isEmpty else { return base.map { $0.id } }
        let q = searchText.lowercased()
        return base.filter {
            $0.tag.lowercased().contains(q) || $0.date.lowercased().contains(q)
        }.map { $0.id }
    }
    
    let columns = [GridItem(.flexible(), spacing: 15), GridItem(.flexible(), spacing: 15)]
    
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 20) {
                // --- 頂部導覽列 ---
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    
                    Text(categoryTitle)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    // 右上角加號按鈕 (選取照片)
                    PhotosPicker(selection: $selectedPhotoItems, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "plus")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                // --- 搜尋列 ---
                SearchBar(text: $searchText).padding(.horizontal, 20)

                // --- ALL / FAVORITE 切換標籤 ---
                HStack(spacing: 0) {
                    Button(action: { selectedTab = 0 }) {
                        Text("ALL").font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(selectedTab == 0 ? Color.white : Color.clear)
                            .foregroundColor(selectedTab == 0 ? .black : .white).cornerRadius(20)
                    }
                    Button(action: { selectedTab = 1 }) {
                        Text("FAVORITE").font(.system(size: 14, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(selectedTab == 1 ? Color.white : Color.clear)
                            .foregroundColor(selectedTab == 1 ? .black : .white).cornerRadius(20)
                    }
                }
                .padding(4).background(Color.white.opacity(0.2)).cornerRadius(24).padding(.horizontal, 20)
                
                // --- 照片網格 ---
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 15) {
                        ForEach(displayPhotos, id: \.self) { assetId in
                            ZStack(alignment: .topTrailing) {
                                NavigationLink(destination: FullPhotoDetailView(assetId: assetId)) {
                                    PhotoThumbnailView(assetId: assetId)
                                        .frame(height: 170)
                                        .cornerRadius(12)
                                        .clipped()
                                }
                                .buttonStyle(.plain)
                                
                                // 🌟 新增：最愛按鈕疊加在照片右上角
                                Button(action: {
                                    DatabaseManager.shared.toggleFavorite(assetId: assetId)
                                    loadPhotos() // 更新 UI
                                }) {
                                    let isFav = photos.first(where: { $0.id == assetId })?.isFavorite ?? false
                                    Image(systemName: isFav ? "heart.fill" : "heart")
                                        .font(.system(size: 20))
                                        .foregroundColor(isFav ? .red : .white)
                                        .padding(8)
                                        .clipShape(Circle())
                                        .padding(8)
                                }
                            }
                            .contextMenu {
                                Button(action: { prepareImageForSharing(assetId: assetId) }) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                Button(action: { DatabaseManager.shared.toggleFavorite(assetId: assetId); loadPhotos() }) {
                                    let isFav = photos.first(where: { $0.id == assetId })?.isFavorite ?? false
                                    Label(isFav ? "Remove Favorite" : "Favorite", systemImage: isFav ? "heart.slash" : "heart")
                                }
                                Menu {
                                    ForEach(availableAlbums.filter { $0.lowercased() != categoryTitle.lowercased() }, id: \.self) { album in
                                        Button(action: { DatabaseManager.shared.movePhoto(assetId: assetId, to: album); loadPhotos() }) {
                                            Text(album.capitalized)
                                        }
                                    }
                                } label: {
                                    Label("Move to other album", systemImage: "folder")
                                }
                                Button(role: .destructive, action: { photoToDelete = assetId; showDeleteAlert = true }) {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 100)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            loadPhotos()
            availableAlbums = DatabaseManager.shared.fetchAllCategories()
        }
        .onChange(of: syncVM.syncedCount) { _, _ in
            loadPhotos()
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            for item in newItems {
                if let assetId = item.itemIdentifier {
                    DatabaseManager.shared.movePhoto(assetId: assetId, to: categoryTitle)
                }
            }
            selectedPhotoItems.removeAll()
            loadPhotos()
        }
        .sheet(isPresented: $showShareSheet) {
            if let image = imageToShare {
                ShareSheet(items: [image])
            }
        }
        .confirmationDialog("確認刪除", isPresented: $showDeleteAlert, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = photoToDelete {
                    DatabaseManager.shared.deletePhoto(assetId: id)
                    loadPhotos()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this photo?")
        }
    }
    
    private func loadPhotos() {
        photos = DatabaseManager.shared.fetchPhotosWithDetails(for: categoryTitle)
    }
    
    private func prepareImageForSharing(assetId: String) {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else { return }
        
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        
        manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { result, _ in
            if let image = result {
                DispatchQueue.main.async {
                    self.imageToShare = image
                    self.showShareSheet = true
                }
            }
        }
    }
}

import SwiftUI
import Photos
import CoreML

struct DashboardView: View {
    @State private var searchText: String = ""
    @State private var searchResults: [String] = []
    @State private var groupedCategories: [(main: String, subs: [String])] = []
    @State private var hasAutoScanned = false
    @State private var isSearching: Bool = false
    @State private var hasSearched: Bool = false   // 使用者是否已按下搜尋
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var selectedResultAssetId: IdentifiableString? = nil
    @State private var showSyncBanner: Bool = false
    @State private var syncBannerCount: Int = 0

    @EnvironmentObject var syncVM: PhotoSyncViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {

                    // ── 同步完成 Banner ────────────────────────────
                    if showSyncBanner {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Synced \(syncBannerCount) new photos")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.1))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // ── 固定頂部：header + 標題 + 搜尋列 ──────────
                    VStack(alignment: .leading, spacing: 12) {

                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.white)

                            Spacer()

                            if syncVM.isSyncing {
                                Text("\(syncVM.syncedCount) / \(syncVM.totalCount)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.gray)
                            }

                            Button(action: {
                                if !syncVM.isSyncing { syncVM.startSync() }
                            }) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.white.opacity(0.2))
                                    .clipShape(Circle())
                                    .rotationEffect(Angle(degrees: syncVM.isSyncing ? 360 : 0))
                                    .animation(
                                        syncVM.isSyncing
                                            ? Animation.linear(duration: 1).repeatForever(autoreverses: false)
                                            : .default,
                                        value: syncVM.isSyncing
                                    )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)

                        Text(searchText.isEmpty ? "ALBUMS" : "SEARCH RESULTS")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)

                        SearchBar(text: $searchText, onSearch: {
                            executeSearch(query: searchText)
                        })
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                    }
                    .background(Color.black)

                    // ── 可捲動內容 ─────────────────────────────────
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 20) {

                            if !searchText.isEmpty {
                                // 搜尋結果
                                if !hasSearched {
                                    // 使用者還在打字，尚未按下搜尋
                                    VStack(spacing: 8) {
                                        Image(systemName: "return")
                                            .font(.system(size: 28))
                                            .foregroundColor(.white.opacity(0.25))
                                        Text("Press Return to search")
                                            .font(.system(size: 15))
                                            .foregroundColor(.white.opacity(0.35))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                                } else if isSearching {
                                    VStack(spacing: 15) {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .scaleEffect(1.2)
                                        Text("Analyzing...")
                                            .foregroundColor(.gray)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 50)
                                } else if searchResults.isEmpty {
                                    Text("No matches found")
                                        .foregroundColor(.gray)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.top, 40)
                                } else {
                                    LazyVGrid(
                                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                                        spacing: 15
                                    ) {
                                        ForEach(searchResults, id: \.self) { assetId in
                                            Button(action: {
                                                selectedResultAssetId = IdentifiableString(id: assetId)
                                            }) {
                                                PhotoThumbnailView(assetId: assetId)
                                                    .frame(height: 170)
                                                    .cornerRadius(12)
                                                    .clipped()
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                }

                            } else {
                                // 相簿分類
                                if groupedCategories.isEmpty && !syncVM.isSyncing {
                                    Text("No Albums Found")
                                        .foregroundColor(.gray)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.top, 40)
                                } else {
                                    ForEach(groupedCategories, id: \.main) { group in
                                        VStack(alignment: .leading, spacing: 15) {
                                            Text(group.main.capitalized)
                                                .font(.custom("SF Pro Text", size: 24).weight(.heavy))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 20)
                                                .padding(.top, 20)

                                            ScrollView(.horizontal, showsIndicators: false) {
                                                HStack(spacing: 15) {
                                                    ForEach(group.subs, id: \.self) { subCategory in
                                                        let allIds = DatabaseManager.shared.fetchPhotos(for: subCategory)
                                                        NavigationLink(
                                                            destination: CategoryDetailView(
                                                                categoryTitle: subCategory,
                                                                syncVM: syncVM
                                                            )
                                                        ) {
                                                            AlbumCoverView(assetId: allIds.first)
                                                                .id(allIds.first ?? subCategory)
                                                        }
                                                        .buttonStyle(.plain)
                                                    }
                                                }
                                                .padding(.horizontal, 20)
                                                .padding(.bottom, 20)
                                            }
                                        }
                                        .background(Color(white: 0.15))
                                        .cornerRadius(16)
                                        .padding(.horizontal, 20)
                                    }
                                }
                            }

                            Color.clear.frame(height: 20)
                        }
                        .padding(.top, 10)
                    }
                }
            }
        }
        .sheet(item: $selectedResultAssetId) { assetItem in
            PhotoDetailModal(assetId: assetItem.id)
        }
        .onAppear {
            loadCategories()
            if !hasAutoScanned && !syncVM.isSyncing {
                hasAutoScanned = true
                syncVM.startSync()
            }
        }
        .onChange(of: syncVM.syncedCount) { _, _ in loadCategories() }
        .onChange(of: syncVM.isSyncing) { _, isNowSyncing in
            if !isNowSyncing && syncVM.syncedCount > 0 {
                syncBannerCount = syncVM.syncedCount
                withAnimation { showSyncBanner = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { showSyncBanner = false }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DatabaseUpdated"))) { _ in
            loadCategories()
        }
        // 打字時重置搜尋狀態，避免顯示舊結果
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty {
                searchResults = []
                hasSearched = false
                isSearching = false
                searchTask?.cancel()
            } else {
                hasSearched = false
                searchResults = []
            }
        }
    }

    private func loadCategories() {
        groupedCategories = DatabaseManager.shared.fetchGroupedCategories()
    }

    private func executeSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            hasSearched = false
            return
        }
        hasSearched = true
        isSearching = true
        searchTask = Task {
            let results = await Task.detached(priority: .userInitiated) {
                return self.performMLSearch(query: trimmed)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    // 靜態快取：整個 App 生命週期只載入一次，避免每次搜尋都重新初始化
    private static let textModel: mobileclip_s2_text? = {
        try? mobileclip_s2_text(configuration: MLModelConfiguration())
    }()

    private func performMLSearch(query: String) -> [String] {
        var textEmbedding: [Float]? = nil
        do {
            let tokenizer = CLIPTokenizer()
            let tokenArray = tokenizer.encode_full(text: query)
            let tokenMultiArray = try MLMultiArray(shape: [1, 77], dataType: .int32)
            for (index, tokenID) in tokenArray.enumerated() {
                tokenMultiArray[index] = NSNumber(value: tokenID)
            }
            guard let textModel = Self.textModel else {
                print("Text model unavailable")
                return DatabaseManager.shared.searchPhotos(text: query, textEmbedding: nil)
            }
            let input = mobileclip_s2_textInput(text: tokenMultiArray)
            let prediction = try textModel.prediction(input: input)
            textEmbedding = prediction.final_emb_1.toFloatArray().normalized()
        } catch {
            print("文字模型推論失敗：\(error)")
        }
        return DatabaseManager.shared.searchPhotos(text: query, textEmbedding: textEmbedding)
    }
}

// MARK: - 相簿封面元件
struct AlbumCoverView: View {
    let assetId: String?
    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.3))
                .frame(width: 160, height: 160)

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity)
            }
        }
        .onAppear { loadImage() }
        .onChange(of: assetId) { _, _ in loadImage() }
        .animation(.easeInOut(duration: 0.3), value: image)
    }

    private func loadImage() {
        guard let assetId = assetId else { self.image = nil; return }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else { return }
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
                DispatchQueue.main.async { self.image = result }
            }
        }
    }
}

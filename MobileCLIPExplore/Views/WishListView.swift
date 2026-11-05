// WishListView.swift
//
// 想去清單：從截圖加入的店家／景點。點一下看當初的截圖（照片頁），「出發」用地圖打開；可以打勾「去過」、編輯、刪除。
// 編輯時可以改地區（例如在「其他地區」的地方填「桃園市」），清單會改分到那個縣市。
// 在附近拍的照片會自動打勾（WishListService.checkVisits）。

import MapKit
import SwiftUI

struct WishListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = WishListService.shared
    @ObservedObject private var connection = AgentConnection.shared
    @ObservedObject private var inbox = SharedInboxProcessor.shared
    @State private var viewingAssetId: IdentifiableString?
    @State private var editing: WishPlace?
    @State private var message: String?
    @AppStorage(MapOpener.preferenceKey) private var mapApp = MapOpener.App.apple.rawValue
    @ObservedObject private var translator = ListTranslator.shared

    private var want: [WishPlace] { service.places.filter { !$0.isVisited } }
    private var visited: [WishPlace] { service.places.filter(\.isVisited) }

    var body: some View {
        NavigationStack {
            Group {
                if service.places.isEmpty && inbox.pendingWish == 0 && inbox.lastMessage == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.text.opacity(0.3))
                        Text("還沒有想去的地方")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.text.opacity(0.6))
                        TipList(title: "怎麼加入", points: [
                            .init("photo", "店家或景點截圖（IG、地圖、LINE）的照片頁按「清單」→「想去」"),
                            .init("square.and.arrow.up", "或在其他 App 按「分享」→ selfIE"),
                            .init("checkmark.circle", "之後在附近拍的照片會自動打勾「去過」"),
                        ], collapsible: false)
                        .padding(.horizontal, 32)
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                } else {
                    List {
                        if inbox.pendingWish > 0 || inbox.lastMessage != nil {
                            SharedInboxStatusRow(kind: .wish)
                                .listRowBackground(Theme.surface(0.12))
                        }
                        if connection.isOffline && !AIRouter.onDevice {
                            AgentOfflineNotice(feature: "從截圖加入新的地方", stillWorks: "清單、打勾、用地圖打開")
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }
                        // 想去的地方依縣市分組（只有一個地區時不分）
                        let regions = WishRegion.group(want, hints: service.regionHints)
                        if regions.count > 1 {
                            ForEach(regions, id: \.region) { group in
                                Section("\(group.region)（\(group.places.count)）") { ForEach(group.places) { row($0) } }
                            }
                        } else if !want.isEmpty {
                            Section("想去（\(want.count)）") { ForEach(want) { row($0) } }
                        }
                        if !visited.isEmpty {
                            Section("去過（\(visited.count)）") { ForEach(visited) { row($0) } }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Theme.background)
                }
            }
            .translationTask(translator.configuration) { session in await translator.run(session) }
            .navigationTitle("想去清單")
            .sheet(item: $editing) { place in
                WishEditView(place: place) { changed in
                    if !changed { message = "清單裡已經有同名的地方了，沒有修改。" }
                }
            }
            .alert("想去清單", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Picker("點一下用哪個地圖打開", selection: $mapApp) {
                            ForEach(MapOpener.App.allCases, id: \.rawValue) { app in
                                Text(app.title).tag(app.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "map")
                    }
                    .accessibilityLabel("選擇地圖")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            service.reload()
            connection.check()
            Task { await service.checkVisits(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeOverlaysForAgent)) { _ in dismiss() }
        .sheet(item: $viewingAssetId) { item in
            // 分享進來的截圖存在 App 裡（不在相簿）
            if SharedScreenshotStore.isShared(item.id) {
                SharedScreenshotView(ref: item.id)
            } else {
                PhotoDetailModal(assetId: item.id)
            }
        }
    }

    private func row(_ place: WishPlace) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: { Task { await service.setVisited(place, visited: !place.isVisited) } }) {
                Image(systemName: place.isVisited ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(place.isVisited ? Theme.highlight : Theme.text.opacity(0.5))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .strikethrough(place.isVisited, color: Theme.text.opacity(0.5))
                let detail = [place.category == "其他" ? nil : place.category,
                              place.address.isEmpty ? (place.area.isEmpty ? nil : place.area) : place.address]
                    .compactMap { $0 }
                    .joined(separator: "・")
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundColor(Theme.text.opacity(0.5))
                }
                if !place.note.isEmpty {
                    TranslatedNoteText(text: place.note)
                }
                if let visitedAt = place.visitedAt {
                    Text(place.visitedAssetId == nil ? "\(visitedAt) 標記去過" : "\(visitedAt) 在附近拍了照片")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.highlight.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
            // 「出發」：用地圖打開；點這一列其他地方：看當初加入的那張截圖
            Button(action: { MapOpener.open(place) }) { GoButtonLabel() }
            .buttonStyle(.plain)
            .accessibilityLabel("用地圖打開 \(place.name)")
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.surface(0.12))
        .contentShape(Rectangle())
        .onTapGesture {
            if let source = place.sourceAssetId {
                viewingAssetId = IdentifiableString(id: source)
            } else {
                MapOpener.open(place)   // 手動加入、沒有截圖的：直接開地圖
            }
        }
        .contextMenu {
            Button(action: { MapOpener.open(place, in: .apple) }) { Label("用 Apple 地圖打開", systemImage: "map") }
            Button(action: { MapOpener.open(place, in: .google) }) { Label("用 Google 地圖打開", systemImage: "globe") }
            if let source = place.sourceAssetId {
                Button(action: { viewingAssetId = IdentifiableString(id: source) }) { Label("查看截圖", systemImage: "photo") }
            }
            if let visitedPhoto = place.visitedAssetId {
                Button(action: { viewingAssetId = IdentifiableString(id: visitedPhoto) }) { Label("查看去過的照片", systemImage: "camera") }
            }
            Button(action: { editing = place }) { Label("編輯", systemImage: "pencil") }
        }
        .swipeActions {
            Button(role: .destructive, action: { Task { await service.delete(place) } }) {
                Label("刪除", systemImage: "trash")
            }
            Button(action: { editing = place }) {
                Label("編輯", systemImage: "pencil")
            }
            .tint(Theme.info)
        }
    }
}

// MARK: - 編輯

/// 編輯想去的地方：名稱、地址、地區、類別、備註。
/// 改了名稱／地址／地區會用 Apple 地圖重新查位置，並重新判斷分在哪個縣市。
struct WishEditView: View {
    let place: WishPlace
    var onDone: ((Bool) -> Void)? = nil

    static let categories = ["餐廳", "咖啡廳", "甜點", "飲料", "酒吧", "景點", "展覽", "商店", "住宿", "其他"]

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var area = ""
    @State private var category = "其他"
    @State private var note = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("地方") {
                    TextField("名稱", text: $name)
                    Picker("類別", selection: $category) {
                        ForEach(Self.categories, id: \.self) { Text($0).tag($0) }
                        if !Self.categories.contains(category) { Text(category).tag(category) }
                    }
                }
                Section {
                    TextField("地區，例如：桃園市", text: $area)
                    TextField("地址", text: $address)
                } header: {
                    Text("在哪裡")
                } footer: {
                    Text("清單依地區分組；改了會重新查位置。")
                }
                Section("備註") {
                    TextField("備註", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("編輯")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("儲存") { save() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            name = place.name
            address = place.address
            area = place.area
            category = place.category.isEmpty ? "其他" : place.category
            note = place.note
        }
    }

    private func save() {
        saving = true
        Task {
            let changed = await WishListService.shared.update(place, name: name, address: address, area: area,
                                                               category: category, note: note)
            await MainActor.run {
                saving = false
                dismiss()
                onDone?(changed)
            }
        }
    }
}

// MARK: - 用外面的地圖打開

/// 想去清單的地點用 Apple 地圖或 Google 地圖打開（點一下用哪個由使用者選，記在 UserDefaults）。
/// 兩種地圖都用店名＋地址搜尋，有座標時以座標為中心。只把這些交給地圖 App，不送照片。
enum MapOpener {
    static let preferenceKey = "wishListMapApp"

    enum App: String, CaseIterable {
        case apple, google
        var title: String { self == .apple ? "Apple 地圖" : "Google 地圖" }
    }

    static var preferred: App {
        App(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .apple
    }

    static func open(_ place: WishPlace, in app: App? = nil) {
        let query = [place.name, place.address.isEmpty ? place.area : place.address]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Apple 和 Google 用同一組「店名＋地址」搜尋，並以同一個位置為中心，兩邊才會打開同一家店
        let coordinate = place.latitude.flatMap { lat in place.longitude.map { "\(lat),\($0)" } }
        switch app ?? preferred {
        case .apple:
            if let url = url("maps://?q=", query, suffix: coordinate.map { "&sll=\($0)&z=16" } ?? "") {
                UIApplication.shared.open(url)
            }
        case .google:
            // 有裝 Google 地圖 App 就用 App 打開，沒有就開網頁版（不需要事先宣告 URL scheme）
            let center = coordinate.map { "&center=\($0)&zoom=16" } ?? ""
            let web = url("https://www.google.com/maps/search/?api=1&query=", query)
            guard let appURL = url("comgooglemaps://?q=", query, suffix: center) else {
                if let web { UIApplication.shared.open(web) }
                return
            }
            UIApplication.shared.open(appURL, options: [:]) { opened in
                if !opened, let web { UIApplication.shared.open(web) }
            }
        }
    }

    private static func url(_ prefix: String, _ query: String, suffix: String = "") -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: prefix + encoded + suffix)
    }
}

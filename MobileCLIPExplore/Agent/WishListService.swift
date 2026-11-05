// WishListService.swift
//
// 想去清單：在截圖（IG 貼文、地圖、LINE 訊息）的照片頁按「加入想去清單」→
// 1. 讀出截圖文字（手機上的 OCR；沒有文字時才請後端看圖）
// 2. Agent 從文字整理出店家／景點名稱與地址
// 3. 用 Apple 地圖查座標（只送店名與地址，不送照片）
// 4. 存進手機（WishPlaces 表），並同步成一篇「想去清單」筆記
// 之後在地點附近 200 公尺內拍的照片 → 自動標成「去過」，那張照片也連到筆記。
// 只讀取照片與位置資訊，不修改、不刪除照片。

import Foundation
import MapKit
import Photos
import UIKit

enum WishListError: LocalizedError {
    case notSignedIn
    case noPlaces
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "請先登入。"
        case .noPlaces: return "這張照片裡沒有找到店名或景點。"
        case .imageUnavailable: return "讀不到這張照片（可能還在 iCloud 下載），請稍後再試。"
        }
    }
}

final class WishListService: ObservableObject {
    static let shared = WishListService()

    /// 同步出來的筆記主題
    static let noteTopic = "想去清單"

    @Published private(set) var places: [WishPlace] = []
    /// 地點 id → 用座標查到的行政區（例如「桃園市桃園區」），給想去清單依縣市分組用；存在手機上，查過就不再查
    @Published private(set) var regionHints: [String: String] =
        UserDefaults.standard.dictionary(forKey: "wishRegionHints") as? [String: String] ?? [:]
    private var resolvingRegions = false

    private var lastVisitCheck = Date.distantPast
    private let checkInterval: TimeInterval = 10 * 60

    private init() {}

    private func context() throws -> (store: PersonalizationStore, userId: String) {
        guard let store = DatabaseManager.shared.personalization,
              let userId = LocalUserSession.currentUserId, !userId.isEmpty else { throw WishListError.notSignedIn }
        return (store, userId)
    }

    var wantCount: Int { places.filter { !$0.isVisited }.count }

    func reload() {
        // 舊版把所有想去的地方寫在同一篇筆記：第一次執行時改成依地區分開（購物清單也一起建立）
        let migrationKey = "listNotesByRegion"
        if !UserDefaults.standard.bool(forKey: migrationKey), (try? context()) != nil {
            UserDefaults.standard.set(true, forKey: migrationKey)
            Task {
                await self.syncNote(extraAssetIds: [])
                await ShoppingListService.shared.syncNotes()
            }
        }
        let list = (try? context()).flatMap { try? $0.store.wishPlaces(userId: $0.userId) } ?? []
        Task { @MainActor in
            self.places = list
            self.resolveRegions()
        }
    }

    /// 地址認不出縣市（例如只有「春日路1434巷」）、但有座標的地點：用 Apple 地圖反查行政區。
    /// 只送座標，一次最多查 8 個，查到的存起來。
    @MainActor
    func resolveRegions() {
        guard !resolvingRegions else { return }
        let pending = places.filter { place in
            place.hasLocation && regionHints[place.id] == nil
                && WishRegion.name(area: place.area, address: place.address) == WishRegion.other
        }.prefix(8)
        guard !pending.isEmpty else { return }
        resolvingRegions = true
        Task { @MainActor in
            for place in pending {
                guard let lat = place.latitude, let lon = place.longitude else { continue }
                let location = CLLocation(latitude: lat, longitude: lon)
                let mark = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_Hant_TW")).first
                let text = [mark?.administrativeArea, mark?.subAdministrativeArea, mark?.locality]
                    .compactMap { $0 }.joined()
                if !text.isEmpty { regionHints[place.id] = text }
            }
            UserDefaults.standard.set(regionHints, forKey: "wishRegionHints")
            resolvingRegions = false
            await self.syncNote(extraAssetIds: [])   // 查到縣市後，筆記也改分到那個地區
        }
    }

    // MARK: 從截圖加入

    struct AddResult {
        let added: [String]
        let alreadyInList: [String]
    }

    func addPlaces(fromPhoto assetId: String) async throws -> AddResult {
        // 截圖文字：已辨識過就沿用，否則現在辨識這一張
        var text = PhotoTextCoordinator.shared.recognizedText(for: assetId)
        if text == nil { text = await PhotoTextCoordinator.shared.recognizeNow(assetId: assetId) }
        // 相機拍的照片（不是截圖）：多半是站在店門口拍招牌，照片的位置就是那家店附近
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject
        let isCameraPhoto = asset.map { !$0.mediaSubtypes.contains(.photoScreenshot) } ?? false
        return try await addPlaces(text: text ?? "", sourceRef: assetId, photoAssetId: assetId,
                                   photoLocation: isCameraPhoto ? asset?.location : nil, readSign: isCameraPhoto) {
            await Self.loadImage(assetId: assetId)
        }
    }

    /// 「用後端再整理一次」：用開發者的後端重新整理這張照片。
    /// 成功後才拿掉這張照片先前整理出、這次沒找到的地方（已打勾去過的保留）；失敗時清單不變。
    func redoPlaces(fromPhoto assetId: String) async throws -> AddResult {
        let current = (try? context()).flatMap { try? $0.store.wishPlaces(userId: $0.userId) } ?? []
        let previous = current.filter { $0.sourceAssetId == assetId && !$0.isVisited }
        let result = try await AIRouter.$forceBackend.withValue(true) {
            try await addPlaces(fromPhoto: assetId)
        }
        let kept = Set((result.added + result.alreadyInList).map { $0.lowercased() })
        for place in previous where !kept.contains(place.name.lowercased()) { await delete(place) }
        return result
    }

    /// 從分享進來的截圖或文字加入（不經過相簿）；sourceRef 是 SharedScreenshotStore 的參照（shared:…）或 nil
    func addPlaces(sharedText text: String, image: UIImage?, sourceRef: String?) async throws -> AddResult {
        try await addPlaces(text: text, sourceRef: sourceRef, photoAssetId: nil, photoLocation: nil, readSign: false) { image }
    }

    /// - Parameters:
    ///   - photoAssetId: 相簿裡的照片（會放進想去清單筆記）；分享進來的截圖為 nil
    ///   - loadImage: 沒有文字時才讀圖、請後端看圖
    ///   - photoLocation: 相機拍的照片的位置：查地點時以這附近為準，查不到就用這個位置
    ///   - readSign: 相機拍的招牌照片：另外請 AI 看招牌上的店名（藝術字常常辨識不出文字）
    private func addPlaces(text: String, sourceRef: String?, photoAssetId: String?, photoLocation: CLLocation?,
                           readSign: Bool, loadImage: () async -> UIImage?) async throws -> AddResult {
        let (store, userId) = try context()
        let text = await ShoppingListService.withExtraScripts(text, loadImage: loadImage)
        var analysis: String?
        if text.isEmpty {
            // 沒有文字（例如只有招牌的照片）：看圖描述（支援的手機在手機上看）
            guard let image = await loadImage() else { throw WishListError.imageUnavailable }
            analysis = try? await AIRouter.analyzeImage(image: image, prompt: "列出圖中出現的店家、餐廳或景點名稱與地址")
        } else if readSign, let image = await loadImage() {
            analysis = try? await AIRouter.analyzeImage(
                image: image, prompt: "這張照片裡主要那家店的招牌寫什麼？列出中文店名、英文店名和分店名稱（例如 XX 桃園店），看不清楚的不要猜")
        }

        // 整理出地點
        // 地圖截圖：只留下選取的那一家（地圖上其他店名的標籤不算）
        let found = try await AIRouter.extractPlaces(text: text, imageAnalysis: analysis)
        // 招牌照片：同一個招牌上的品牌和分店名稱（「炸雞大獅」＋「桃園輯安店」）是同一家店
        // （只在相機拍的招牌照片合併；截圖、貼文可能真的列了好幾家）
        let merged = readSign ? PlaceMerge.mergeBranches(found) : found
        let extracted = MapScreenshotFocus.filter(merged, text: text) { $0.name }
        guard !extracted.isEmpty else { throw WishListError.noPlaces }

        // 查座標並存起來
        var added: [String] = []
        var duplicates: [String] = []
        for place in extracted {
            var coordinate = await Self.geocode(place, near: photoLocation)
            // 招牌照片只有一家、地圖又查不到：用拍照的位置
            if coordinate == nil, extracted.count == 1, let photoLocation { coordinate = photoLocation.coordinate }
            let inserted = try store.addWishPlace(
                userId: userId, id: UUID().uuidString, name: place.name, address: place.address, area: place.area,
                category: place.category, note: place.note,
                latitude: coordinate?.latitude, longitude: coordinate?.longitude, sourceAssetId: sourceRef)
            if inserted { added.append(place.name) } else { duplicates.append(place.name) }
        }

        await syncNote(extraAssetIds: added.isEmpty ? [] : (photoAssetId.map { [$0] } ?? []))
        reload()
        await checkVisits(force: true)
        return AddResult(added: added, alreadyInList: duplicates)
    }

    // MARK: 編輯

    func setVisited(_ place: WishPlace, visited: Bool) async {
        guard let ctx = try? context() else { return }
        try? ctx.store.setWishVisited(userId: ctx.userId, placeId: place.id, visited: visited, assetId: nil,
                                  visitedAt: visited ? Self.dayString(Date()) : nil)
        await syncNote(extraAssetIds: [])
        reload()
    }

    /// 使用者編輯地點文字。名稱、地址或地區改了：用 Apple 地圖重新查位置（查不到就沿用原本的），
    /// 並重新判斷縣市。改成清單裡已有的名稱時不改，回傳 false。
    func update(_ place: WishPlace, name: String, address: String, area: String, category: String, note: String) async -> Bool {
        guard let ctx = try? context() else { return false }
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let (name, address, area) = (clean(name), clean(address), clean(area))
        var latitude = place.latitude
        var longitude = place.longitude
        if name != place.name || address != place.address || area != place.area {
            let draft = ExtractedPlace(name: name, address: address, area: area, category: category, note: note)
            if let coordinate = await Self.geocode(draft) {
                latitude = coordinate.latitude
                longitude = coordinate.longitude
            }
        }
        let changed = (try? ctx.store.updateWishPlace(userId: ctx.userId, placeId: place.id, name: name, address: address,
                                                      area: area, category: category, note: clean(note),
                                                      latitude: latitude, longitude: longitude)) ?? false
        if changed {
            await MainActor.run {
                regionHints[place.id] = nil      // 位置可能變了：重新判斷縣市
                UserDefaults.standard.set(regionHints, forKey: "wishRegionHints")
            }
            await syncNote(extraAssetIds: [])
        }
        reload()
        return changed
    }

    func delete(_ place: WishPlace) async {
        guard let ctx = try? context() else { return }
        try? ctx.store.deleteWishPlace(userId: ctx.userId, placeId: place.id)
        await syncNote(extraAssetIds: [])
        reload()
    }

    // MARK: 去過了沒（在附近拍的照片）

    /// App 回到前景時呼叫；10 分鐘內最多檢查一次
    func checkVisitsIfNeeded() {
        guard Date().timeIntervalSince(lastVisitCheck) > checkInterval else { return }
        Task.detached(priority: .utility) { await self.checkVisits(force: false) }
    }

    func checkVisits(force: Bool) async {
        if !force && Date().timeIntervalSince(lastVisitCheck) < checkInterval { return }
        lastVisitCheck = Date()
        guard let ctx = try? context(),
              let list = try? ctx.store.wishPlaces(userId: ctx.userId) else { return }
        let store = ctx.store, userId = ctx.userId
        let pending = list.compactMap { place -> (id: String, latitude: Double, longitude: Double, addedAt: Date)? in
            guard !place.isVisited, let lat = place.latitude, let lon = place.longitude else { return nil }
            return (place.id, lat, lon, Self.parseTimestamp(place.createdAt) ?? .distantPast)
        }
        guard let earliest = pending.map(\.addedAt).min() else { return }

        // 加入清單之後拍的、有定位的照片（只讀取拍攝時間與位置）
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate > %@ AND mediaType == %d", earliest as NSDate, PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 3000
        var photos: [WishVisitMatcher.Photo] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate, let location = asset.location else { return }
            photos.append(WishVisitMatcher.Photo(assetId: asset.localIdentifier, date: date,
                                                 latitude: location.coordinate.latitude,
                                                 longitude: location.coordinate.longitude))
        }
        let visits = WishVisitMatcher.visits(places: pending, photos: photos)
        guard !visits.isEmpty else { return }
        for visit in visits {
            try? store.setWishVisited(userId: userId, placeId: visit.placeId, visited: true,
                                      assetId: visit.assetId, visitedAt: Self.dayString(visit.date))
        }
        await syncNote(extraAssetIds: visits.map(\.assetId))
        reload()
    }

    // MARK: 同步成筆記

    /// 依地區把清單寫成筆記（「想去清單・桃園」「想去清單・東京」…），某個地區清空時刪掉那篇。
    /// 只連結截圖與到訪照片的識別碼（分享進來的截圖不在相簿，不連結）。
    private func syncNote(extraAssetIds: [String]) async {
        guard let ctx = try? context(), let list = try? ctx.store.wishPlaces(userId: ctx.userId) else { return }
        let hints = await MainActor.run { regionHints }

        func line(_ place: WishPlace) -> String {
            var detail = [place.category == "其他" ? nil : place.category,
                          place.address.isEmpty ? (place.area.isEmpty ? nil : place.area) : place.address]
                .compactMap { $0 }
                .joined(separator: "，")
            if !place.note.isEmpty { detail += detail.isEmpty ? place.note : "｜\(place.note)" }
            return detail.isEmpty ? place.name : "\(place.name)：\(detail)"
        }

        var notes: [ListNotes.Note] = []
        for group in WishRegion.group(list, hints: hints) {
            let want = group.places.filter { !$0.isVisited }
            let visited = group.places.filter(\.isVisited)
            var content: [String] = []
            if !want.isEmpty {
                content.append("## 想去（\(want.count)）")
                content += want.map { "- " + line($0) }
            }
            if !visited.isEmpty {
                if !content.isEmpty { content.append("") }
                content.append("## 去過（\(visited.count)）")
                content += visited.map { "- ✅ " + line($0) + ($0.visitedAt.map { "（\($0) 去過）" } ?? "") }
            }
            let photos = group.places.flatMap { [$0.sourceAssetId, $0.visitedAssetId] }.compactMap { $0 }
            notes.append(ListNotes.Note(topic: ListNotes.topic(ListNotes.wishPrefix, group.region),
                                        summary: "\(group.region)：想去 \(want.count) 個、去過 \(visited.count) 個地點",
                                        content: content.joined(separator: "\n"), assetIds: photos))
        }
        await ListNotes.sync(notes, prefix: ListNotes.wishPrefix, legacyTopic: Self.noteTopic)
    }

    // MARK: 工具

    /// Apple 地圖查座標（只送店名與地址）
    /// - near: 照片的位置（相機拍的招牌照片）：只找這附近 2 公里內的結果，避免查到別的分店
    private static func geocode(_ place: ExtractedPlace, near: CLLocation? = nil) async -> CLLocationCoordinate2D? {
        let query = [place.name, place.address.isEmpty ? place.area : place.address]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let near {
            request.region = MKCoordinateRegion(center: near.coordinate, latitudinalMeters: 4000, longitudinalMeters: 4000)
        }
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return item.placemark.coordinate
    }

    private static func loadImage(assetId: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = "yyyy/M/d"
        return formatter.string(from: date)
    }

    /// SQLite CURRENT_TIMESTAMP（UTC，yyyy-MM-dd HH:mm:ss）
    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}


// MARK: - 清單筆記（想去、購物）

/// 想去清單、購物清單依地區／國家各寫一篇筆記，給 Agent 和「這張照片在哪些筆記」使用。
/// 標題固定是「想去清單・桃園」「購物清單・日本」這種格式，由 App 自動整理（不能改名、不列在一般筆記裡）。
enum ListNotes {
    static let wishPrefix = "想去清單・"
    static let shoppingPrefix = "購物清單・"
    /// 舊版：所有想去的地方寫在同一篇
    static let legacyTopics: Set<String> = [WishListService.noteTopic, "購物清單"]

    struct Note {
        let topic: String
        let summary: String
        let content: String
        let assetIds: [String]
    }

    /// App 自動整理的清單筆記
    static func isListNote(_ topic: String) -> Bool {
        legacyTopics.contains(topic) || topic.hasPrefix(wishPrefix) || topic.hasPrefix(shoppingPrefix)
    }

    /// 筆記標題最多 10 個字
    static func topic(_ prefix: String, _ region: String) -> String {
        String((prefix + region).prefix(WikiText.maxTopicLength))
    }

    /// 寫入這些筆記（內容沒變就不重寫），並刪掉同一種清單裡已經沒有內容的地區
    static func sync(_ notes: [Note], prefix: String, legacyTopic: String?) async {
        let wiki = WikiService.shared
        for note in notes {
            let albumPhotos = note.assetIds.filter { !SharedScreenshotStore.isShared($0) }
            if let existing = try? await wiki.note(topic: note.topic),
               existing.content == WikiText.compactContent(TraditionalChinese.convert(note.content)),
               existing.summary == WikiText.compactSummary(TraditionalChinese.convert(note.summary)) {
                continue
            }
            _ = try? await wiki.apply(decision: "update", topic: note.topic, summary: note.summary,
                                      content: note.content, assetIds: albumPhotos)
        }
        let keep = Set(notes.map(\.topic))
        let existing = (try? await wiki.list(limit: 10_000)) ?? []
        for item in existing where (item.topic.hasPrefix(prefix) && !keep.contains(item.topic)) || item.topic == legacyTopic {
            try? await wiki.delete(topic: item.topic)
        }
    }
}


// MARK: - 合併同一家店

/// 招牌照片常被整理成兩筆：品牌（「炸雞大獅」「FRIED CHICKEN MASTER」）和分店（「桃園輯安店」）。
/// 只有一個品牌、另外幾筆只是「XX店」時，把分店名稱併進品牌那一筆。
enum PlaceMerge {
    static func isBranchOnly(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...10).contains(trimmed.count) else { return false }
        // 「飯店」「書店」「商店」本身就是店的種類，不是分店名稱
        if ["飯店", "酒店", "書店", "商店", "便利商店"].contains(where: { trimmed.hasSuffix($0) }) { return false }
        return ["分店", "門市", "店"].contains { trimmed.hasSuffix($0) } && !trimmed.contains(" ")
    }

    static func mergeBranches(_ places: [ExtractedPlace]) -> [ExtractedPlace] {
        let branches = places.filter { isBranchOnly($0.name) }
        let brands = places.filter { !isBranchOnly($0.name) }
        guard brands.count == 1, let brand = brands.first, !branches.isEmpty else { return places }
        let branch = branches[0]
        func pick(_ a: String, _ b: String) -> String { a.isEmpty ? b : a }
        let notes = ([brand.note] + branches.map(\.note)).filter { !$0.isEmpty }
        return [ExtractedPlace(name: "\(brand.name) \(branch.name)",
                               address: pick(brand.address, branch.address),
                               area: pick(brand.area, branch.area),
                               category: brand.category == "其他" ? branch.category : brand.category,
                               note: notes.joined(separator: "｜"))]
    }
}

// ShoppingListService.swift
//
// 購物清單：在商品截圖（IG、小紅書、官網、藥妝清單）的照片頁按「想買」→
// 1. 讀出截圖文字（手機上的 OCR；沒有文字時才請後端看圖）
// 2. Agent 從文字整理出商品名稱、品牌、價格、在哪裡買
// 3. 判斷要在哪個國家買（文字有日文假名 → 日本、韓文 → 韓國…；Agent 也可能從幣別、店名看出來），可以手動改
// 4. 存進手機（ShoppingItems 表）
//
// 沒有到達提醒（不使用定位）。只讀取照片，不修改、不刪除照片。

import Foundation
import MapKit
import Photos
import UIKit

enum ShoppingListError: LocalizedError {
    case notSignedIn
    case noProducts
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "請先登入。"
        case .noProducts: return "看不出是哪個商品，可以手動加入。"
        case .imageUnavailable: return "讀不到這張照片（可能還在 iCloud 下載），請稍後再試。"
        }
    }
}

final class ShoppingListService: ObservableObject {
    static let shared = ShoppingListService()

    @Published private(set) var items: [ShoppingItem] = []

    private init() {}

    private func context() throws -> (store: PersonalizationStore, userId: String) {
        guard let store = DatabaseManager.shared.personalization,
              let userId = LocalUserSession.currentUserId, !userId.isEmpty else { throw ShoppingListError.notSignedIn }
        return (store, userId)
    }

    var wantCount: Int { items.filter { !$0.isBought }.count }

    /// 還沒買的商品依國家分組（數量多的國家在前；沒指定國家的在最後）
    var pendingByCountry: [(code: String, items: [ShoppingItem])] {
        Dictionary(grouping: items.filter { !$0.isBought }, by: \.countryCode)
            .map { (code: $0.key, items: $0.value) }
            .sorted { lhs, rhs in
                if lhs.code.isEmpty != rhs.code.isEmpty { return !lhs.code.isEmpty }
                return (lhs.items.count, rhs.code) > (rhs.items.count, lhs.code)
            }
    }

    func reload() {
        let list = (try? context()).flatMap { try? $0.store.shoppingItems(userId: $0.userId) } ?? []
        DispatchQueue.main.async { self.items = list }
    }

    /// 同步讀取（背景被叫醒時用，不經過主執行緒）
    func currentItems() -> [ShoppingItem] {
        (try? context()).flatMap { try? $0.store.shoppingItems(userId: $0.userId) } ?? []
    }

    // MARK: 從截圖加入

    struct AddResult {
        let added: [String]
        let alreadyInList: [String]
        /// 判斷出的國家（沒判斷出時為空字串）
        let countryCode: String
    }

    func addItems(fromPhoto assetId: String) async throws -> AddResult {
        // 截圖文字：已辨識過就沿用，否則現在辨識這一張
        var text = PhotoTextCoordinator.shared.recognizedText(for: assetId)
        if text == nil { text = await PhotoTextCoordinator.shared.recognizeNow(assetId: assetId) }
        return try await addItems(text: text ?? "", sourceRef: assetId) {
            await Self.loadImage(assetId: assetId)
        }
    }

    /// 「用後端再整理一次」：用開發者的後端重新整理這張照片。
    /// 成功後才拿掉這張照片先前整理出、這次沒找到的項目（已打勾買到的保留）；失敗時清單不變。
    func redoItems(fromPhoto assetId: String) async throws -> AddResult {
        let previous = currentItems().filter { $0.sourceAssetId == assetId && !$0.isBought }
        let result = try await AIRouter.$forceBackend.withValue(true) {
            try await addItems(fromPhoto: assetId)
        }
        let kept = Set((result.added + result.alreadyInList).map { $0.lowercased() })
        for item in previous where !kept.contains(item.name.lowercased()) { delete(item) }
        return result
    }

    /// 從分享進來的截圖或文字加入（不經過相簿）；sourceRef 是 SharedScreenshotStore 的參照（shared:…）或 nil
    func addItems(sharedText text: String, image: UIImage?, sourceRef: String?) async throws -> AddResult {
        try await addItems(text: text, sourceRef: sourceRef) { image }
    }

    /// - Parameter loadImage: 沒有文字時才讀圖、請後端看圖
    private func addItems(text: String, sourceRef: String?, loadImage: () async -> UIImage?) async throws -> AddResult {
        let (store, userId) = try context()
        let text = await Self.withExtraScripts(text, loadImage: loadImage)
        var analysis: String?
        if text.isEmpty {
            // 沒有文字（例如只有商品照片）：看圖描述（支援的手機在手機上看）
            guard let image = await loadImage() else { throw ShoppingListError.imageUnavailable }
            analysis = try? await AIRouter.analyzeImage(image: image, prompt: "列出圖中商品的名稱、品牌與價格，並說明包裝上的文字是哪一種語言")
        }

        // 整理出商品
        var extracted = try await AIRouter.extractProducts(text: text, imageAnalysis: analysis)
        if extracted.isEmpty && analysis == nil, let image = await loadImage() {
            // 影片、貼文截圖常常只有字幕和標籤、沒寫商品全名：附上看圖描述再試一次
            analysis = try? await AIRouter.analyzeImage(image: image, prompt: "這張截圖裡介紹的是什麼商品？列出品牌、商品類型與看得到的名稱，並說明包裝上的文字是哪一種語言")
            if analysis != nil {
                extracted = try await AIRouter.extractProducts(text: text, imageAnalysis: analysis)
            }
        }
        guard !extracted.isEmpty else { throw ShoppingListError.noProducts }

        // 要在哪個國家買：看文字（韓文字、「韓國必買」、首爾、₩…）和 AI 的判斷。
        // 電腦上的 Agent 看得懂上下文，先用它的；手機上的模型比較小，文字看得出來就以文字為準。
        var guessed = ShoppingCountry.guess(text: text + " " + (analysis ?? "")) ?? ""
        // 文字辨識只認得中文和英文：韓文、日文包裝常被辨識成亂碼。手機上看不出國家時，請模型看一眼包裝是哪種文字
        if guessed.isEmpty, AIRouter.onDevice, extracted.allSatisfy({ $0.country_code.isEmpty }), let image = await loadImage(),
           let language = try? await AIRouter.analyzeImage(image: image, prompt: "照片裡商品包裝上的文字主要是哪一種語言？只回答：中文、日文、韓文、泰文、英文或其他") {
            guessed = ShoppingCountry.guess(text: language) ?? ""
        }
        var added: [String] = []
        var duplicates: [String] = []
        var country = ""
        for product in extracted {
            let fromAI = product.country_code.uppercased()
            let aiCode = ShoppingCountry.names[fromAI] != nil ? fromAI : ""
            let code = AIRouter.onDevice ? (guessed.isEmpty ? aiCode : guessed) : (aiCode.isEmpty ? guessed : aiCode)
            if country.isEmpty { country = code }
            let inserted = try store.addShoppingItem(
                userId: userId, id: UUID().uuidString, name: product.name, brand: product.brand, price: product.price,
                store: product.store, countryCode: code, note: product.note, sourceAssetId: sourceRef)
            if inserted { added.append(product.name) } else { duplicates.append(product.name) }
        }
        reload()
        await syncNotes()
        return AddResult(added: added, alreadyInList: duplicates, countryCode: country)
    }

    // MARK: 手動加入

    /// 手動加入一樣商品（認不出來、或想自己寫的時候）。同一個國家已有同名商品時回傳 false。
    @discardableResult
    func addManually(name: String, brand: String, shop: String, countryCode: String, note: String,
                     sourceAssetId: String?) throws -> Bool {
        let (store, userId) = try context()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let inserted = try store.addShoppingItem(
            userId: userId, id: UUID().uuidString, name: trimmed,
            brand: brand.trimmingCharacters(in: .whitespacesAndNewlines), price: "",
            store: shop.trimmingCharacters(in: .whitespacesAndNewlines), countryCode: countryCode, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceAssetId: sourceAssetId)
        changed()
        return inserted
    }

    // MARK: 編輯

    func setBought(_ item: ShoppingItem, bought: Bool) {
        guard let ctx = try? context() else { return }
        try? ctx.store.setShoppingBought(userId: ctx.userId, itemId: item.id, bought: bought,
                                         boughtAt: bought ? AppDateFormatters.dateTime.string(from: Date()) : nil)
        changed()
    }

    /// 改國家；改過去的國家已有同名商品時不改，回傳 false
    @discardableResult
    func setCountry(_ item: ShoppingItem, countryCode: String) -> Bool {
        guard let ctx = try? context() else { return false }
        let didChange = (try? ctx.store.setShoppingCountry(userId: ctx.userId, itemId: item.id, countryCode: countryCode)) ?? false
        changed()
        return didChange
    }

    /// 使用者編輯文字；改成同一個國家已有的商品名稱時不改，回傳 false
    @discardableResult
    func update(_ item: ShoppingItem, name: String, brand: String, price: String, shop: String, note: String) -> Bool {
        guard let ctx = try? context() else { return false }
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let didChange = (try? ctx.store.updateShoppingItem(userId: ctx.userId, itemId: item.id, name: clean(name),
                                                           brand: clean(brand), price: clean(price), store: clean(shop),
                                                           note: clean(note))) ?? false
        changed()
        return didChange
    }

    func delete(_ item: ShoppingItem) {
        guard let ctx = try? context() else { return }
        try? ctx.store.deleteShoppingItem(userId: ctx.userId, itemId: item.id)
        changed()
    }

    // MARK: 同步成筆記

    /// 清單改了：更新畫面，並在背景更新筆記
    private func changed() {
        reload()
        Task { await self.syncNotes() }
    }

    /// 依國家把清單寫成筆記（「購物清單・日本」「購物清單・韓國」…），和想去清單一樣；某個國家清空時刪掉那篇
    func syncNotes() async {
        let all = currentItems()
        func line(_ item: ShoppingItem) -> String {
            var detail = [item.brand, item.price, item.store.isEmpty ? "" : "在\(item.store)買"]
                .filter { !$0.isEmpty }
                .joined(separator: "，")
            if !item.note.isEmpty { detail += detail.isEmpty ? item.note : "｜\(item.note)" }
            return detail.isEmpty ? item.name : "\(item.name)：\(detail)"
        }
        var notes: [ListNotes.Note] = []
        let codes = Array(Set(all.map(\.countryCode)))
            .sorted { lhs, rhs in
                let l = all.filter { $0.countryCode == lhs }.count, r = all.filter { $0.countryCode == rhs }.count
                return l != r ? l > r : lhs < rhs
            }
        for code in codes {
            let items = all.filter { $0.countryCode == code }
            let want = items.filter { !$0.isBought }
            let bought = items.filter(\.isBought)
            var content: [String] = []
            if !want.isEmpty {
                content.append("## 想買（\(want.count)）")
                content += want.map { "- " + line($0) }
            }
            if !bought.isEmpty {
                if !content.isEmpty { content.append("") }
                content.append("## 買到了（\(bought.count)）")
                content += bought.map { "- ✅ " + line($0) }
            }
            let country = ShoppingCountry.name(for: code)
            notes.append(ListNotes.Note(topic: ListNotes.topic(ListNotes.shoppingPrefix, country),
                                        summary: "\(country)：想買 \(want.count) 樣、買到 \(bought.count) 樣",
                                        content: content.joined(separator: "\n"),
                                        assetIds: items.compactMap(\.sourceAssetId)))
        }
        await ListNotes.sync(notes, prefix: ListNotes.shoppingPrefix, legacyTopic: nil)
    }

    /// 照片上的韓文、日文另外辨識一次，接在原本的文字後面（第一次辨識只認得中文、英文）
    static func withExtraScripts(_ text: String, loadImage: () async -> UIImage?) async -> String {
        guard let image = await loadImage() else { return text }
        let extra = await Task.detached(priority: .userInitiated) { PhotoTextRecognizer.extraScripts(image: image) }.value
        guard !extra.isEmpty else { return text }
        return text.isEmpty ? extra : text + "\n" + extra
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
}

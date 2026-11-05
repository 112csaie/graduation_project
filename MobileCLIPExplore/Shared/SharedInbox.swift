// SharedInbox.swift
//
// 「分享到 App」的收件匣：App 和分享延伸功能（Share Extension）共用。
// - 在 IG、小紅書、Safari、相簿按「分享」→ 選這個 App →「加到購物清單／想去清單」：
//   分享延伸功能只把截圖（或網址、文字）存進 App Group 的共用資料夾，馬上結束，不用打開 App。
// - App 下次打開（而且連得上電腦）時再整理：辨識文字、請 Agent 整理商品或地點、存進清單。
// - 截圖不會存進你的相簿；整理完後收件匣裡的檔案就刪掉（清單上要看截圖時，App 會留一份縮小的副本）。
//
// 這個檔案要同時加到 App 和 Share Extension 兩個 target（Target Membership 兩個都勾）。
// 需要在兩個 target 的「Signing & Capabilities」加上同一個 App Group（見 ShareExtensionSource/設定步驟.md）。

import Foundation
import UIKit

enum SharedInbox {
    static let appGroupId = "group.com.elaine.MobileCLIPExplore"

    enum Kind: String, Codable {
        case shopping   // 購物清單
        case wish       // 想去清單

        var title: String { self == .shopping ? "購物清單" : "想去清單" }
    }

    struct Item: Codable, Identifiable, Equatable {
        let id: String
        let kind: Kind
        /// 分享進來的文字（例如貼文內容）
        let text: String
        /// 分享進來的網址
        let url: String
        /// 收件匣資料夾裡的圖片檔名（沒有圖片時為 nil）
        let imageFile: String?
        let createdAt: Date
    }

    /// App Group 的共用資料夾；還沒設定 App Group 時為 nil（分享功能無法使用，App 其他功能不受影響）
    static var folder: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let url = container.appendingPathComponent("SharedInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var isAvailable: Bool { folder != nil }

    enum InboxError: LocalizedError {
        case appGroupMissing
        case nothingToSave

        var errorDescription: String? {
            switch self {
            case .appGroupMissing: return "App 還沒設定 App Group，暫時無法從分享加入。"
            case .nothingToSave: return "沒有可以加入的圖片或文字。"
            }
        }
    }

    // MARK: 寫入（Share Extension）

    /// 存一筆分享進來的內容。圖片會縮到長邊 2000 px、存成 JPEG。
    static func add(kind: Kind, images: [UIImage], text: String, url: String) throws {
        guard let folder else { throw InboxError.appGroupMissing }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !images.isEmpty || !text.isEmpty || !url.isEmpty else { throw InboxError.nothingToSave }
        // 多張圖片：每張一筆（每張各自整理）；只有文字或網址：一筆
        let entries: [UIImage?] = images.isEmpty ? [nil] : images
        for image in entries {
            let id = UUID().uuidString
            var imageFile: String?
            if let image, let data = downscaled(image, maxSide: 2000).jpegData(compressionQuality: 0.85) {
                imageFile = id + ".jpg"
                try data.write(to: folder.appendingPathComponent(imageFile!), options: .atomic)
            }
            let item = Item(id: id, kind: kind, text: text, url: url, imageFile: imageFile, createdAt: Date())
            let data = try JSONEncoder().encode(item)
            try data.write(to: folder.appendingPathComponent(id + ".json"), options: .atomic)
        }
    }

    // MARK: 讀取（App）

    /// 還沒整理的項目（舊到新）
    static func pending() -> [Item] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Item.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func image(for item: Item) -> UIImage? {
        guard let folder, let file = item.imageFile else { return nil }
        return UIImage(contentsOfFile: folder.appendingPathComponent(file).path)
    }

    /// 整理完（或使用者放棄）後刪掉收件匣裡的檔案（只刪 App 自己的共用資料夾，不碰相簿）
    static func remove(_ item: Item) {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(item.id + ".json"))
        if let file = item.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
    }

    static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return image }
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

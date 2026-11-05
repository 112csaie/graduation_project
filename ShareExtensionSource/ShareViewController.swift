// ShareViewController.swift（Share Extension）
//
// 在其他 App（IG、小紅書、Safari、相簿…）按「分享」→ 選這個 App 時出現的小視窗：
// 「加到購物清單」或「加到想去清單」。只把截圖（或網址、文字）存進 App Group 的收件匣就結束，
// 整理（辨識文字、請 Agent 整理）等下次打開 App 再做（見 SharedInbox.swift、SharedInboxProcessor.swift）。
// 不會把截圖存進相簿，也不會修改任何照片。
//
// 設定方式見同資料夾的「設定步驟.md」。

import SwiftUI
import UIKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onFinish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        model.onCancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "ShareExtension", code: 0))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.load(from: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
    }
}

final class ShareModel: ObservableObject {
    @Published var images: [UIImage] = []
    @Published var text = ""
    @Published var url = ""
    @Published var isLoading = true
    @Published var message: String?
    @Published var done = false

    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}

    /// 最多一次分享幾張（分享延伸功能可用的記憶體很少）
    private let maxImages = 10

    func load(from items: [NSExtensionItem]) {
        let providers = items.flatMap { $0.attachments ?? [] }
        let contentText = items.compactMap { $0.attributedContentText?.string }.joined(separator: "\n")
        let group = DispatchGroup()
        var loadedImages: [UIImage] = []
        var loadedText: [String] = contentText.isEmpty ? [] : [contentText]
        var loadedURL = ""
        let lock = NSLock()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                    var image: UIImage?
                    if let url = item as? URL, let data = try? Data(contentsOf: url) { image = UIImage(data: data) }
                    else if let data = item as? Data { image = UIImage(data: data) }
                    else if let img = item as? UIImage { image = img }
                    if let image {
                        let small = SharedInbox.downscaled(image, maxSide: 2000)
                        lock.lock(); if loadedImages.count < self.maxImages { loadedImages.append(small) }; lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    if let url = item as? URL, !url.isFileURL {
                        lock.lock(); loadedURL = url.absoluteString; lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    if let text = item as? String {
                        lock.lock(); loadedText.append(text); lock.unlock()
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            self.images = loadedImages
            self.text = loadedText.joined(separator: "\n")
            self.url = loadedURL
            self.isLoading = false
        }
    }

    func save(_ kind: SharedInbox.Kind) {
        do {
            try SharedInbox.add(kind: kind, images: images, text: text, url: url)
            message = "已收到！下次打開 App 時會整理進\(kind.title)。"
            done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.onFinish() }
        } catch {
            message = error.localizedDescription
        }
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if model.isLoading {
                    ProgressView()
                        .frame(maxHeight: .infinity)
                } else {
                    preview
                    if let message = model.message {
                        Text(message)
                            .font(.system(size: 14))
                            .foregroundColor(model.done ? .green : .orange)
                            .multilineTextAlignment(.center)
                    }
                    if !model.done {
                        VStack(spacing: 10) {
                            button("加到購物清單", icon: "bag", kind: .shopping)
                            button("加到想去清單", icon: "mappin.and.ellipse", kind: .wish)
                        }
                        Text("截圖不會存進相簿。下次打開 App、連上電腦時，Agent 會整理出商品或店名。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(20)
            .navigationTitle("加到清單")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.onCancel() }
                }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if !model.images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.images.enumerated()), id: \.offset) { _, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 110, height: 150)
                            .clipped()
                            .cornerRadius(10)
                    }
                }
            }
            .frame(height: 150)
        } else if !model.url.isEmpty || !model.text.isEmpty {
            Text(model.url.isEmpty ? model.text : model.url)
                .font(.system(size: 13))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
        } else {
            Text("沒有可以加入的圖片或文字").foregroundColor(.secondary)
        }
    }

    private func button(_ title: String, icon: String, kind: SharedInbox.Kind) -> some View {
        Button(action: { model.save(kind) }) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.images.isEmpty && model.text.isEmpty && model.url.isEmpty)
    }
}

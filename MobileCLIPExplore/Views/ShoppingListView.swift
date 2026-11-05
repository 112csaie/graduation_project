// ShoppingListView.swift
//
// 購物清單：從商品截圖加入的想買的東西，依「在哪個國家買」分組。
// 打勾＝買到了、右邊是來源截圖的縮圖（點一下打開）、左滑編輯或刪除、長按可以改國家。
// 沒有到達提醒（不使用定位）。
// 備註是日文、韓文、英文時，下面加上繁體中文翻譯（Apple 翻譯，在手機上完成；見 ListTranslator）。

import NaturalLanguage
import SwiftUI
import Translation

struct ShoppingListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = ShoppingListService.shared
    @ObservedObject private var connection = AgentConnection.shared
    @ObservedObject private var inbox = SharedInboxProcessor.shared
    @State private var viewingAssetId: IdentifiableString?
    @State private var showBought = false
    @State private var message: String?
    @State private var showManualAdd = false
    @State private var editing: ShoppingItem?
    @ObservedObject private var translator = ListTranslator.shared

    private var bought: [ShoppingItem] { service.items.filter(\.isBought) }

    var body: some View {
        NavigationStack {
            Group {
                if service.items.isEmpty && inbox.pendingShopping == 0 && inbox.lastMessage == nil {
                    emptyState
                } else {
                    List {
                        if inbox.pendingShopping > 0 || inbox.lastMessage != nil {
                            SharedInboxStatusRow(kind: .shopping)
                                .listRowBackground(Theme.surface(0.12))
                        }
                        if connection.isOffline && !AIRouter.onDevice {
                            AgentOfflineNotice(feature: "從截圖加入新的商品", stillWorks: "清單、打勾和編輯")
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }
                        ForEach(service.pendingByCountry, id: \.code) { group in
                            Section("\(ShoppingCountry.name(for: group.code))（\(group.items.count)）") {
                                ForEach(group.items) { row($0) }
                            }
                        }
                        if !bought.isEmpty {
                            Section {
                                if showBought { ForEach(bought) { row($0) } }
                            } header: {
                                Button(action: { withAnimation { showBought.toggle() } }) {
                                    HStack {
                                        Text("買到了（\(bought.count)）")
                                        Spacer()
                                        Image(systemName: showBought ? "chevron.up" : "chevron.down")
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Theme.background)
                }
            }
            .translationTask(translator.configuration) { session in await translator.run(session) }
            .navigationTitle("購物清單")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { showManualAdd = true }) { Image(systemName: "plus") }
                        .accessibilityLabel("手動加入")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showManualAdd) { ShoppingManualAddView() }
            .sheet(item: $editing) { item in
                ShoppingEditView(item: item) { changed in
                    if !changed { message = "清單裡已經有同名的商品了，沒有修改。" }
                }
            }
            .alert("購物清單", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
        .onAppear {
            service.reload()
            connection.check()
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bag")
                .font(.system(size: 40))
                .foregroundColor(Theme.text.opacity(0.3))
            Text("還沒有想買的東西")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text.opacity(0.6))
            TipList(title: "怎麼加入", points: [
                .init("photo", "商品截圖（IG、小紅書、官網）的照片頁按「清單」→「想買」"),
                .init("square.and.arrow.up", "或在其他 App 按「分享」→ selfIE"),
                .init("globe.asia.australia", "自動整理出商品，依在哪個國家買分組"),
            ], collapsible: false)
            .padding(.horizontal, 32)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: 一列

    private func row(_ item: ShoppingItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: { service.setBought(item, bought: !item.isBought) }) {
                Image(systemName: item.isBought ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(item.isBought ? Theme.highlight : Theme.text.opacity(0.5))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .strikethrough(item.isBought, color: Theme.text.opacity(0.5))
                let detail = [item.brand, item.price, item.store.isEmpty ? "" : "在\(item.store)"]
                    .filter { !$0.isEmpty }
                    .joined(separator: "・")
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundColor(Theme.text.opacity(0.55))
                }
                if !item.note.isEmpty {
                    TranslatedNoteText(text: item.note)
                }
                if item.isBought {
                    Text("\(item.countryName)・\(item.boughtAt.map { "\($0) 買到" } ?? "買到了")")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.highlight.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
            if let source = item.sourceAssetId {
                SourceThumbnail(ref: source)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.surface(0.12))
        .contentShape(Rectangle())
        .onTapGesture {
            if let source = item.sourceAssetId { viewingAssetId = IdentifiableString(id: source) }
        }
        .contextMenu {
            if let source = item.sourceAssetId {
                Button(action: { viewingAssetId = IdentifiableString(id: source) }) { Label("查看截圖", systemImage: "photo") }
            }
            Button(action: { editing = item }) { Label("編輯", systemImage: "pencil") }
            Menu {
                ForEach(ShoppingCountry.common, id: \.self) { code in
                    Button(action: { changeCountry(item, to: code) }) {
                        if code == item.countryCode {
                            Label(ShoppingCountry.name(for: code), systemImage: "checkmark")
                        } else {
                            Text(ShoppingCountry.name(for: code))
                        }
                    }
                }
                Button("不指定國家") { changeCountry(item, to: "") }
            } label: {
                Label("在哪個國家買", systemImage: "globe.asia.australia")
            }
        }
        .swipeActions {
            Button(role: .destructive, action: { service.delete(item) }) {
                Label("刪除", systemImage: "trash")
            }
            Button(action: { editing = item }) {
                Label("編輯", systemImage: "pencil")
            }
            .tint(Theme.info)
        }
    }

    private func changeCountry(_ item: ShoppingItem, to code: String) {
        guard code != item.countryCode else { return }
        if !service.setCountry(item, countryCode: code) {
            message = "\(ShoppingCountry.name(for: code))的清單裡已經有「\(item.name)」了。"
        }
    }
}


// MARK: - 手動加入

/// 手動加入一樣想買的東西：截圖認不出商品、或想自己寫的時候。
/// 從照片頁打開時帶著那張照片（清單上可以「查看截圖」），國家先用照片文字猜（假名 → 日本…）。
struct ShoppingManualAddView: View {
    var sourceAssetId: String? = nil
    var suggestedCountry: String = ""
    var onAdded: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var brand = ""
    @State private var shop = ""
    @State private var note = ""
    @State private var country = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("商品名稱（必填），例如：無印良品 護髮油", text: $name)
                        .focused($nameFocused)
                    TextField("品牌（選填）", text: $brand)
                }
                Section("在哪裡買") {
                    Picker("國家", selection: $country) {
                        Text("不指定").tag("")
                        ForEach(ShoppingCountry.common, id: \.self) { code in
                            Text(ShoppingCountry.name(for: code)).tag(code)
                        }
                    }
                    TextField("店名（選填），例如：唐吉訶德", text: $shop)
                }
                Section {
                    TextField("備註（選填）", text: $note)
                }
                if let error {
                    Text(error).foregroundColor(.orange)
                }
            }
            .navigationTitle("手動加入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            if country.isEmpty { country = suggestedCountry }
            nameFocused = true
        }
    }

    private func save() {
        do {
            let added = try ShoppingListService.shared.addManually(name: name, brand: brand, shop: shop,
                                                                   countryCode: country, note: note,
                                                                   sourceAssetId: sourceAssetId)
            if added {
                onAdded?(name.trimmingCharacters(in: .whitespaces))
                dismiss()
            } else {
                error = "\(ShoppingCountry.name(for: country))的清單裡已經有「\(name)」了。"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}


// MARK: - 來源縮圖

/// 清單右邊的小縮圖：分享進來的截圖存在 App 裡，其他是相簿裡的照片（只讀取）
struct SourceThumbnail: View {
    let ref: String
    var size: CGFloat = 52

    var body: some View {
        Group {
            if SharedScreenshotStore.isShared(ref) {
                if let image = SharedScreenshotStore.image(for: ref) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Theme.surface(0.2)
                }
            } else {
                PhotoThumbnailView(assetId: ref, pixelSize: size * 3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}


// MARK: - 編輯

/// 編輯一樣想買的東西的文字（名稱、品牌、價格、店名、備註）。國家用長按選單改。
struct ShoppingEditView: View {
    let item: ShoppingItem
    var onDone: ((Bool) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var brand = ""
    @State private var price = ""
    @State private var shop = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("商品") {
                    TextField("商品名稱", text: $name)
                    TextField("品牌", text: $brand)
                    TextField("價格", text: $price)
                }
                Section("在哪裡買") {
                    TextField("店名，例如：唐吉訶德", text: $shop)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        let changed = ShoppingListService.shared.update(item, name: name, brand: brand, price: price,
                                                                        shop: shop, note: note)
                        dismiss()
                        onDone?(changed)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            name = item.name
            brand = item.brand
            price = item.price
            shop = item.store
            note = item.note
        }
    }
}

// MARK: - 備註翻譯（想去、想買清單共用）

/// 清單備註翻成繁體中文：日文、韓文、英文…的備註，下面加上中文翻譯，原文保留。
/// - 用 Apple 的翻譯（Translation），在手機上完成；第一次遇到某個語言時，系統會請你下載那個語言
/// - 翻譯結果只存在這支手機的 App 設定，不會改到清單原本的文字
/// - 中文（包括夾了幾個英文字的中文）不翻
@MainActor
final class ListTranslator: ObservableObject {
    static let shared = ListTranslator()

    /// 原文 → 中文
    @Published private(set) var translations: [String: String]
    /// 目前要翻的語言；交給 .translationTask，有值時系統就會開始翻
    @Published private(set) var configuration: TranslationSession.Configuration?

    private let storageKey = "listNoteTranslations"
    private let maxStored = 800
    private static let target = Locale.Language(identifier: "zh-TW")
    /// 語言代碼 → 還沒翻的原文
    private var pending: [String: [String]] = [:]
    private var running: String?
    /// 這次開 App 翻不了的（語言不支援、沒有下載）：不再重試
    private var failed = Set<String>()

    private init() {
        translations = (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String]) ?? [:]
    }

    func translation(for text: String) -> String? { translations[text] }

    /// 需要翻譯時排進去（已經翻過、中文、翻不了的都略過）
    func request(_ text: String) {
        guard translations[text] == nil, !failed.contains(text),
              let language = Self.sourceLanguage(of: text) else { return }
        var queue = pending[language, default: []]
        guard !queue.contains(text) else { return }
        queue.append(text)
        pending[language] = queue
        startNextIfIdle()
    }

    /// 要翻譯的語言代碼；中文或判斷不出來時回傳 nil
    nonisolated static func sourceLanguage(of text: String) -> String? {
        let scalars = text.unicodeScalars
        let hasKana = scalars.contains { (0x3040...0x30FF).contains($0.value) }
        let hasHangul = scalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
        let hasHan = scalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if hasKana { return "ja" }
        if hasHangul { return "ko" }
        // 有漢字、沒有假名和諺文：當作中文，不翻（例如「新商品～透明附…lip gloss」）
        if hasHan { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined,
              text.filter(\.isLetter).count >= 6 else { return nil }
        return language.rawValue
    }

    private func startNextIfIdle() {
        guard running == nil, let language = pending.keys.sorted().first else { return }
        running = language
        configuration = TranslationSession.Configuration(source: Locale.Language(identifier: language), target: Self.target)
    }

    /// 由 .translationTask 呼叫：翻完目前這個語言的備註，再換下一個語言
    func run(_ session: TranslationSession) async {
        guard let language = running else { return }
        let texts = pending[language] ?? []
        pending[language] = nil
        if !texts.isEmpty {
            let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            do {
                let responses = try await session.translations(from: requests)
                for response in responses {
                    guard let id = response.clientIdentifier, let index = Int(id), index < texts.count else { continue }
                    let result = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !result.isEmpty { translations[texts[index]] = result }
                }
                save()
            } catch {
                print("[清單翻譯] \(language) 翻譯失敗：\(error)")
                failed.formUnion(texts)
            }
        }
        running = nil
        configuration = nil
        startNextIfIdle()
    }

    private func save() {
        var stored = translations
        if stored.count > maxStored {
            for key in stored.keys.sorted().prefix(stored.count - maxStored) { stored[key] = nil }
            translations = stored
        }
        UserDefaults.standard.set(stored, forKey: storageKey)
    }
}

/// 清單的備註：有中文翻譯時，翻譯在上、原文小字在下
struct TranslatedNoteText: View {
    let text: String
    @ObservedObject private var translator = ListTranslator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let translated = translator.translation(for: text) {
                Text(translated).font(.system(size: 12)).foregroundColor(Theme.text.opacity(0.65))
                Text(text).font(.system(size: 11)).foregroundColor(Theme.text.opacity(0.4))
            } else {
                Text(text).font(.system(size: 12)).foregroundColor(Theme.text.opacity(0.65))
            }
        }
        .onAppear { translator.request(text) }
    }
}

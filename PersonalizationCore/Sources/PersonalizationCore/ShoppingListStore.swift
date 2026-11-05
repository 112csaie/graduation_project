// ShoppingListStore.swift
//
// 購物清單（migration v10 的 ShoppingItems 表）：從商品截圖整理出「想買的東西」與要在哪個國家買。
// - 商品名稱、品牌、價格、店名由 Agent 從截圖文字整理；國家由文字判斷（假名 → 日本、韓文 → 韓國…），可以手動改
// - 到了那個國家、或清單上寫的店附近時，App 會提醒（提醒的判斷規則在這裡，定位與通知在 App 端）
// - 只記錄來源截圖的識別碼，不修改照片
//
// 本檔案只依賴 Foundation 與 SQLite.swift，可在 macOS 用 swift test 驗證。

import Foundation
import SQLite

struct ShoppingItem: Identifiable, Hashable {
    let id: String
    let name: String
    let brand: String
    let price: String
    /// 在哪裡買（例如唐吉訶德、松本清）；沒寫時為空字串
    let store: String
    /// ISO 國家代碼（JP、KR…）；不知道時為空字串
    let countryCode: String
    let note: String
    let sourceAssetId: String?
    let isBought: Bool
    let boughtAt: String?
    let createdAt: String?

    var countryName: String { ShoppingCountry.name(for: countryCode) }
}

// MARK: - 國家

enum ShoppingCountry {
    /// 清單上常用的國家（顯示名稱）
    static let names: [String: String] = [
        "JP": "日本", "KR": "韓國", "TH": "泰國", "TW": "台灣", "CN": "中國", "HK": "香港", "MO": "澳門",
        "SG": "新加坡", "MY": "馬來西亞", "VN": "越南", "PH": "菲律賓", "ID": "印尼",
        "US": "美國", "GB": "英國", "FR": "法國", "DE": "德國", "IT": "義大利", "ES": "西班牙", "AU": "澳洲",
    ]

    /// 讓使用者手動選擇時的順序
    static let common = ["JP", "KR", "TH", "HK", "SG", "US", "GB", "FR", "TW"]

    static func name(for code: String) -> String {
        code.isEmpty ? "未指定國家" : (names[code.uppercased()] ?? code.uppercased())
    }

    /// 中文或英文國名 → 國家代碼（Agent 回傳國名時使用）；不認得時為 nil
    static func code(forName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 2, trimmed.uppercased() == trimmed, names[trimmed] != nil { return trimmed }
        if let hit = names.first(where: { $0.value == trimmed }) { return hit.key }
        let aliases: [String: String] = ["japan": "JP", "korea": "KR", "southkorea": "KR", "韓国": "KR", "南韓": "KR",
                                         "thailand": "TH", "taiwan": "TW", "臺灣": "TW", "hongkong": "HK",
                                         "singapore": "SG", "usa": "US", "unitedstates": "US", "美国": "US",
                                         "uk": "GB", "unitedkingdom": "GB", "france": "FR", "日本国": "JP"]
        return aliases[trimmed.lowercased().replacingOccurrences(of: " ", with: "")]
    }

    /// 截圖文字或看圖描述裡，直接寫出國家、城市、當地連鎖店、幣別的字（例如「韓國必買」「首爾」「Olive Young」「₩」）
    static let keywords: [(code: String, words: [String])] = [
        ("KR", ["韓國", "韩国", "南韓", "韓国", "韓文", "韩文", "首爾", "首尔", "釜山", "濟州", "济州", "明洞", "弘大", "聖水", "圣水",
                "東大門", "东大门", "olive young", "oliveyoung", "korea", "seoul", "busan", "韓幣", "韩币", "₩"]),
        ("JP", ["日本", "日文", "東京", "东京", "大阪", "京都", "福岡", "北海道", "沖繩", "冲绳", "唐吉訶德", "唐吉诃德", "松本清",
                "japan", "tokyo", "osaka", "kyoto", "日幣", "日币", "円"]),
        ("TH", ["泰國", "泰国", "泰文", "曼谷", "清邁", "清迈", "普吉", "芭達雅", "芭堤雅", "thailand", "bangkok", "泰銖", "泰铢", "฿"]),
        ("HK", ["香港", "hong kong", "hk$", "港幣", "港币"]),
        ("SG", ["新加坡", "singapore", "s$"]),
    ]

    /// 從截圖文字猜要在哪個國家買：有日文假名 → 日本、韓文 → 韓國、泰文 → 泰國；
    /// 也看文字裡寫出的國家、城市、當地連鎖店和幣別（「韓國必買」「首爾」「₩」）。都沒有時 nil。
    /// （只有中文字分不出台灣或中國，所以不猜；NT$ 也不算，台灣賣家常賣日本商品。）
    static func guess(text: String) -> String? {
        var scores: [String: Int] = [:]
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3041...0x309F, 0x30A0...0x30FF: scores["JP", default: 0] += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: scores["KR", default: 0] += 1
            case 0x0E00...0x0E7F: scores["TH", default: 0] += 1
            default: break
            }
        }
        let lowered = text.lowercased()
        for entry in keywords {
            for word in entry.words where lowered.contains(word) {
                scores[entry.code, default: 0] += 3
            }
        }
        guard let best = scores.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= 2 else { return nil }
        return best.key
    }
}

// MARK: - 提醒規則（純計算，方便測試）

enum ShoppingReminder {
    /// 同一個國家多久提醒一次（小時）：落地提醒一次，旅途中每天最多再提醒一次
    static let countryCooldownHours: Double = 20
    /// 同一間店多久提醒一次（小時）
    static let storeCooldownHours: Double = 6
    /// 店家離你多近才提醒（公尺）
    static let storeRadiusMeters: Double = 400

    /// 在這個國家還沒買的商品
    static func pending(_ items: [ShoppingItem], countryCode: String) -> [ShoppingItem] {
        guard !countryCode.isEmpty else { return [] }
        return items.filter { !$0.isBought && $0.countryCode.uppercased() == countryCode.uppercased() }
    }

    /// 上次提醒之後過了夠久才再提醒
    static func shouldNotify(lastNotified: Date?, now: Date, cooldownHours: Double) -> Bool {
        guard let lastNotified else { return true }
        return now.timeIntervalSince(lastNotified) >= cooldownHours * 3600
    }

    /// 還沒買、有寫店名的商品依店名分組（店名比對忽略空白與大小寫），店名依商品數多到少
    static func byStore(_ items: [ShoppingItem]) -> [(store: String, items: [ShoppingItem])] {
        var groups: [String: (store: String, items: [ShoppingItem])] = [:]
        for item in items where !item.isBought {
            let store = item.store.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !store.isEmpty else { continue }
            let key = PhotoTextHints.normalize(store)
            groups[key, default: (store, [])].items.append(item)
        }
        return groups.values.sorted { ($0.items.count, $1.store) > ($1.items.count, $0.store) }
    }

    /// 通知內容：「日本購物清單還有 8 樣：A、B、C…」
    static func countryMessage(countryCode: String, items: [ShoppingItem]) -> (title: String, body: String) {
        let names = items.prefix(4).map(\.name).joined(separator: "、")
        let more = items.count > 4 ? "…" : ""
        return ("你在\(ShoppingCountry.name(for: countryCode))！", "購物清單還有 \(items.count) 樣沒買：\(names)\(more)")
    }

    static func storeMessage(store: String, items: [ShoppingItem]) -> (title: String, body: String) {
        let names = items.prefix(4).map(\.name).joined(separator: "、")
        let more = items.count > 4 ? "…" : ""
        return ("附近有\(store)", "購物清單上有 \(items.count) 樣可以在這裡買：\(names)\(more)")
    }
}

// MARK: - 資料庫

extension PersonalizationStore {

    private func shoppingItem(from row: [Binding?]) -> ShoppingItem? {
        guard let id = row[0] as? String, let name = row[1] as? String else { return nil }
        return ShoppingItem(id: id, name: name,
                            brand: row[2] as? String ?? "", price: row[3] as? String ?? "",
                            store: row[4] as? String ?? "", countryCode: row[5] as? String ?? "",
                            note: row[6] as? String ?? "", sourceAssetId: row[7] as? String,
                            isBought: (row[8] as? String) == "bought", boughtAt: row[9] as? String,
                            createdAt: row[10] as? String)
    }

    /// 還沒買的在前（新加入的在前），買到的在後
    func shoppingItems(userId: String) throws -> [ShoppingItem] {
        try query("""
        SELECT item_id, name, brand, price, store, country_code, note, source_asset_id, status, bought_at, created_at
        FROM ShoppingItems WHERE user_id = ?
        ORDER BY CASE status WHEN 'want' THEN 0 ELSE 1 END, created_at DESC, rowid DESC
        """, userId).compactMap(shoppingItem(from:))
    }

    /// 加入商品；同一個國家已有同名商品（忽略空白與大小寫）時不重複加入，回傳 false
    @discardableResult
    func addShoppingItem(userId: String, id: String, name: String, brand: String, price: String, store: String,
                         countryCode: String, note: String, sourceAssetId: String?) throws -> Bool {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        let key = PhotoTextHints.normalize(name)
        guard !key.isEmpty else { return false }
        return try write {
            try exec("""
            INSERT OR IGNORE INTO ShoppingItems
                (user_id, item_id, name, name_key, brand, price, store, country_code, note, source_asset_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, userId, id, name, key, brand, price, store, countryCode.uppercased(), note, sourceAssetId)
            return db.changes > 0
        }
    }

    func setShoppingBought(userId: String, itemId: String, bought: Bool, boughtAt: String?) throws {
        try write {
            try exec("""
            UPDATE ShoppingItems SET status = ?, bought_at = ? WHERE user_id = ? AND item_id = ?
            """, bought ? "bought" : "want", bought ? boughtAt : nil, userId, itemId)
        }
    }

    /// 改國家；改過去的國家已有同名商品時不改，回傳 false
    @discardableResult
    func setShoppingCountry(userId: String, itemId: String, countryCode: String) throws -> Bool {
        try write {
            try exec("UPDATE OR IGNORE ShoppingItems SET country_code = ? WHERE user_id = ? AND item_id = ?",
                     countryCode.uppercased(), userId, itemId)
            return db.changes > 0
        }
    }

    /// 使用者編輯商品文字；改成同一個國家已有的商品名稱時不改，回傳 false
    @discardableResult
    func updateShoppingItem(userId: String, itemId: String, name: String, brand: String, price: String,
                            store: String, note: String) throws -> Bool {
        let key = PhotoTextHints.normalize(name)
        guard !key.isEmpty else { return false }
        return try write {
            try exec("""
            UPDATE OR IGNORE ShoppingItems SET name = ?, name_key = ?, brand = ?, price = ?, store = ?, note = ?
            WHERE user_id = ? AND item_id = ?
            """, name, key, brand, price, store, note, userId, itemId)
            return db.changes > 0
        }
    }

    func deleteShoppingItem(userId: String, itemId: String) throws {
        try write {
            try exec("DELETE FROM ShoppingItems WHERE user_id = ? AND item_id = ?", userId, itemId)
        }
    }
}

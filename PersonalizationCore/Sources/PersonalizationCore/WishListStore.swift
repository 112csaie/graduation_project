// WishListStore.swift
//
// 想去清單（migration v8 的 WishPlaces 表）：從截圖找出的店家／景點，以及「去過了沒」。
// - 名稱、地址由 Agent 從截圖文字整理；座標由 App 用 Apple 地圖查詢（只送店名與地址）
// - 之後在附近拍的照片會被認成「去過」，只記錄那張照片的識別碼，不修改照片
//
// 本檔案只依賴 Foundation 與 SQLite.swift，可在 macOS 用 swift test 驗證。

import Foundation
import SQLite

struct WishPlace: Identifiable, Hashable {
    let id: String
    let name: String
    let address: String
    let area: String
    let category: String
    let note: String
    let latitude: Double?
    let longitude: Double?
    let sourceAssetId: String?
    let isVisited: Bool
    let visitedAssetId: String?
    let visitedAt: String?
    let createdAt: String?

    var hasLocation: Bool { latitude != nil && longitude != nil }
}

/// 想去清單依地區分組：從 Agent 整理的「地區」與地址找出縣市（台灣縣市、日韓常去的城市），
/// 例如「桃園龜山」→ 桃園、「東京澀谷」→ 東京。認不出的放在「其他地區」。
enum WishRegion {
    static let other = "其他地區"

    /// 縣市名稱與別名（前面的是顯示名稱）
    static let regions: [(name: String, aliases: [String])] = [
        ("台北", ["台北", "臺北", "taipei"]), ("新北", ["新北", "板橋", "淡水", "九份", "三重", "中和", "永和", "新莊", "新店", "三峽", "鶯歌"]),
        ("基隆", ["基隆"]), ("桃園", ["桃園", "中壢", "龜山", "大溪"]), ("新竹", ["新竹", "竹北"]), ("苗栗", ["苗栗"]),
        ("台中", ["台中", "臺中", "taichung"]), ("彰化", ["彰化", "鹿港"]), ("南投", ["南投", "日月潭", "清境"]),
        ("雲林", ["雲林"]), ("嘉義", ["嘉義", "阿里山"]), ("台南", ["台南", "臺南", "tainan"]),
        ("高雄", ["高雄", "kaohsiung"]), ("屏東", ["屏東", "墾丁"]), ("宜蘭", ["宜蘭", "羅東", "礁溪"]),
        ("花蓮", ["花蓮"]), ("台東", ["台東", "臺東"]), ("澎湖", ["澎湖"]), ("金門", ["金門"]), ("馬祖", ["馬祖", "連江"]),
        ("東京", ["東京", "tokyo", "澀谷", "渋谷", "新宿", "池袋", "銀座", "淺草", "浅草", "上野", "原宿", "秋葉原"]),
        ("神奈川", ["神奈川", "橫濱", "横浜", "鎌倉", "箱根"]), ("千葉", ["千葉", "舞濱", "舞浜"]),
        ("大阪", ["大阪", "osaka", "難波", "なんば", "梅田", "心齋橋", "心斎橋"]), ("京都", ["京都", "kyoto", "嵐山", "祇園"]),
        ("奈良", ["奈良"]), ("兵庫", ["兵庫", "神戶", "神戸"]), ("北海道", ["北海道", "札幌", "小樽", "函館"]),
        ("沖繩", ["沖繩", "沖縄", "那霸", "那覇"]), ("福岡", ["福岡", "博多"]), ("名古屋", ["名古屋", "愛知"]),
        ("首爾", ["首爾", "서울", "seoul", "明洞", "弘大"]), ("釜山", ["釜山", "부산", "busan"]), ("濟州", ["濟州", "제주", "jeju"]),
        ("香港", ["香港", "hongkong"]), ("澳門", ["澳門", "macau"]), ("曼谷", ["曼谷", "bangkok"]), ("新加坡", ["新加坡", "singapore"]),
    ]

    /// 先看「地區」，再看地址，再看座標查到的行政區；都認不出時用「地區」原文（太長或空白就歸到其他地區）
    static func name(area: String, address: String, hint: String? = nil) -> String {
        for text in [area, address, hint ?? ""] {
            let lowered = text.lowercased().replacingOccurrences(of: " ", with: "")
            guard !lowered.isEmpty else { continue }
            // 取最早出現的那個（「台北市…新北」這種地址以前面的為準）
            var bestIndex: String.Index?
            var bestName: String?
            for region in regions {
                for alias in region.aliases {
                    guard let range = lowered.range(of: alias) else { continue }
                    if bestIndex == nil || range.lowerBound < bestIndex! {
                        bestIndex = range.lowerBound
                        bestName = region.name
                    }
                }
            }
            if let bestName { return bestName }
        }
        let trimmed = area.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.count > 6 ? other : trimmed
    }

    /// 依地區分組：地方多的地區排前面，同樣多照名稱；「其他地區」永遠最後。組內保持原本順序。
    /// - hints: 地點 id → 用座標查到的行政區（例如「桃園市龜山區」）。地址只有路名（「春日路1434巷」）時靠它判斷縣市。
    static func group(_ places: [WishPlace], hints: [String: String] = [:]) -> [(region: String, places: [WishPlace])] {
        var order: [String] = []
        var groups: [String: [WishPlace]] = [:]
        for place in places {
            let region = name(area: place.area, address: place.address, hint: hints[place.id])
            if groups[region] == nil { order.append(region) }
            groups[region, default: []].append(place)
        }
        let sorted = order.sorted { a, b in
            if (a == other) != (b == other) { return b == other }
            let countA = groups[a]?.count ?? 0
            let countB = groups[b]?.count ?? 0
            return countA != countB ? countA > countB : a < b
        }
        return sorted.map { (region: $0, places: groups[$0] ?? []) }
    }
}

/// 地圖截圖（Google 地圖、Apple 地圖）：只加入「選取的那一家」。
/// 地圖上同時標了附近很多店名，照片文字全部讀得到；被選取的店會出現在搜尋框和下方的地點卡
/// （同一個名字出現兩次，或緊接在「4.5 ★ (406)」這種評分上一行），其他只是地圖上的標籤。
/// 不是地圖截圖、或認不出選取的是哪一家時，照原本的結果全部加入。
enum MapScreenshotFocus {
    /// 地圖 App 地點卡上的按鈕與字樣（正規化：小寫、無空白）
    static let mapWords = ["路線", "開始", "致電", "營業時間", "已打烊", "營業中", "即將打烊", "即將營業", "街景",
                           "directions", "start", "call", "opennow", "closed", "openinghours", "路線規劃", "導航"]

    static func isMapScreenshot(_ text: String) -> Bool {
        let normalized = PhotoTextHints.normalize(text)
        return mapWords.filter { normalized.contains($0) }.count >= 2
    }

    /// 被選取的地點名稱（正規化後）
    static func focusNames(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { line in
                PhotoTextHints.normalize(line)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".…·・>×✕"))
            }
        var counts: [String: Int] = [:]
        for line in lines where isNameLike(line) { counts[line, default: 0] += 1 }
        var names = counts.filter { $0.value >= 2 }.map(\.key)
        // 評分那一行（4.5★★★★★(406)）的上一行是地點卡標題
        let rating = try! NSRegularExpression(pattern: "^[0-5][.,][0-9]")
        for (i, line) in lines.enumerated() where i > 0 {
            let range = NSRange(line.startIndex..., in: line)
            if rating.firstMatch(in: line, range: range) != nil, isNameLike(lines[i - 1]) { names.append(lines[i - 1]) }
        }
        return Array(Set(names)).sorted()
    }

    /// 只留下名稱和選取的地點相符的項目；認不出選取的是哪一家、或都不相符時原樣回傳
    static func filter<T>(_ items: [T], text: String, name: (T) -> String) -> [T] {
        guard items.count > 1, isMapScreenshot(text) else { return items }
        let focus = focusNames(text)
        guard !focus.isEmpty else { return items }
        let kept = items.filter { item in
            let n = PhotoTextHints.normalize(name(item))
            guard n.count >= 2 else { return false }
            return focus.contains { $0.contains(n) || n.contains($0) }
        }
        return kept.isEmpty ? items : kept
    }

    /// 看起來像店名的一行：至少 3 個字、不是時間或數字、不是地圖按鈕
    private static func isNameLike(_ line: String) -> Bool {
        guard line.count >= 3, !mapWords.contains(line) else { return false }
        let digits = line.filter { $0.isNumber || $0 == ":" || $0 == "." || $0 == "%" }
        return Double(digits.count) / Double(line.count) < 0.5
    }
}

/// 到訪比對：純計算，方便測試
enum WishVisitMatcher {
    /// 照片離地點多近算「去過」（公尺）
    static let defaultRadius: Double = 200

    struct Photo {
        let assetId: String
        let date: Date
        let latitude: Double
        let longitude: Double
    }

    struct Visit: Equatable {
        let placeId: String
        let assetId: String
        let date: Date
    }

    /// 每個還沒去過的地點：加入清單之後、在半徑內拍的第一張照片
    static func visits(places: [(id: String, latitude: Double, longitude: Double, addedAt: Date)],
                       photos: [Photo], radius: Double = defaultRadius) -> [Visit] {
        let sorted = photos.sorted { $0.date < $1.date }
        return places.compactMap { place in
            guard let photo = sorted.first(where: {
                $0.date > place.addedAt &&
                distance(place.latitude, place.longitude, $0.latitude, $0.longitude) <= radius
            }) else { return nil }
            return Visit(placeId: place.id, assetId: photo.assetId, date: photo.date)
        }
    }

    /// 兩點距離（公尺，haversine）
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// 比對用的名稱（去空白、轉小寫、全形轉半形）：同名的店不重複加入
    static func nameKey(_ name: String) -> String {
        PhotoTextHints.normalize(name)
    }
}

extension PersonalizationStore {

    private func wishPlace(from row: [Binding?]) -> WishPlace? {
        guard let id = row[0] as? String, let name = row[1] as? String else { return nil }
        return WishPlace(id: id, name: name,
                         address: row[2] as? String ?? "", area: row[3] as? String ?? "",
                         category: row[4] as? String ?? "其他", note: row[5] as? String ?? "",
                         latitude: row[6] as? Double, longitude: row[7] as? Double,
                         sourceAssetId: row[8] as? String,
                         isVisited: (row[9] as? String) == "visited",
                         visitedAssetId: row[10] as? String, visitedAt: row[11] as? String,
                         createdAt: row[12] as? String)
    }

    /// 想去的在前（新加入的在前），去過的在後
    func wishPlaces(userId: String) throws -> [WishPlace] {
        try query("""
        SELECT place_id, name, address, area, category, note, latitude, longitude, source_asset_id,
               status, visited_asset_id, visited_at, created_at
        FROM WishPlaces WHERE user_id = ?
        ORDER BY CASE status WHEN 'want' THEN 0 ELSE 1 END, created_at DESC, rowid DESC
        """, userId).compactMap(wishPlace(from:))
    }

    /// 加入地點；同名（忽略空白與大小寫）已存在時不重複加入，回傳 false
    @discardableResult
    func addWishPlace(userId: String, id: String, name: String, address: String, area: String, category: String,
                      note: String, latitude: Double?, longitude: Double?, sourceAssetId: String?) throws -> Bool {
        guard !userId.isEmpty else { throw PersonalizationError.notSignedIn }
        let key = WishVisitMatcher.nameKey(name)
        guard !key.isEmpty else { return false }
        return try write {
            try exec("""
            INSERT OR IGNORE INTO WishPlaces
                (user_id, place_id, name, name_key, address, area, category, note, latitude, longitude, source_asset_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, userId, id, name, key, address, area, category, note, latitude, longitude, sourceAssetId)
            return db.changes > 0
        }
    }

    func setWishVisited(userId: String, placeId: String, visited: Bool, assetId: String?, visitedAt: String?) throws {
        try write {
            if visited {
                try exec("""
                UPDATE WishPlaces SET status = 'visited', visited_asset_id = ?, visited_at = ?
                WHERE user_id = ? AND place_id = ?
                """, assetId, visitedAt, userId, placeId)
            } else {
                try exec("""
                UPDATE WishPlaces SET status = 'want', visited_asset_id = NULL, visited_at = NULL
                WHERE user_id = ? AND place_id = ?
                """, userId, placeId)
            }
        }
    }

    /// 使用者編輯地點文字（名稱、地址、地區、類別、備註）與重新查到的座標；改成清單裡已有的名稱時不改，回傳 false
    @discardableResult
    func updateWishPlace(userId: String, placeId: String, name: String, address: String, area: String,
                         category: String, note: String, latitude: Double?, longitude: Double?) throws -> Bool {
        let key = WishVisitMatcher.nameKey(name)
        guard !key.isEmpty else { return false }
        return try write {
            try exec("""
            UPDATE OR IGNORE WishPlaces SET name = ?, name_key = ?, address = ?, area = ?, category = ?, note = ?,
                latitude = ?, longitude = ?
            WHERE user_id = ? AND place_id = ?
            """, name, key, address, area, category, note, latitude, longitude, userId, placeId)
            return db.changes > 0
        }
    }

    func deleteWishPlace(userId: String, placeId: String) throws {
        try write {
            try exec("DELETE FROM WishPlaces WHERE user_id = ? AND place_id = ?", userId, placeId)
        }
    }
}

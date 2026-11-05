// InterestTracker.swift
//
// 興趣紀錄：依使用者選的興趣，把「有拍到相關照片的日子」整理成日曆，並可交給 Agent 寫成月報。
// 例：運動與健身 → 健身日曆；電影與藝文 → 觀影與看展日曆；音樂與演出 → 演出足跡。
//
// - 只用已確認的分類標籤與照片日期，不重算向量、不修改照片。
// - 日曆是「有拍照的日子」，沒拍照的那天不會被記到；畫面上會說明。
// - 本檔案只依賴 Foundation，可在 iOS App 與 macOS `swift test` 共用。

import Foundation

struct InterestTracker: Identifiable, Hashable {
    /// 對應的興趣定位 ID
    let id: String
    /// 日曆名稱，例如「健身日曆」
    let titleZh: String
    let icon: String
    /// 統計句的動作，例如「去運動」→「10 月有 12 天去運動」
    let activityZh: String
    /// 算進來的分類（大、中、小分類都可以，包含子分類）
    let nodeIds: [String]
    /// 月報標題用的短名稱（最多 4 個字）→「10月健身月報」
    let reportNameZh: String
    /// 月報要著重的內容（交給 Agent）
    let reportFocusZh: String
    /// 大分類底下不算的分類：有拍到不代表做了這件事（例如「球場觀賽」不算去運動）
    var excludedNodeIds: [String] = []
    /// 身體相關的照片（體組成）：日曆照常顯示，月報預設不放
    var sensitiveNodeIds: [String] = []
    /// 不算住家、學校、公司附近拍的照片（例如探店：學餐、在家吃飯不算）。常去地點由旅程偵測找出。
    var skipsRoutinePlaces = false
    /// 改用偵測到的旅程：旅程期間的每一天都算（不看分類標籤）
    var usesTrips = false

    /// 統計句：「10 月有 12 天去運動」
    func summary(month: Int, days: Int) -> String {
        days == 0 ? "\(month) 月還沒有紀錄" : "\(month) 月有 \(days) 天\(activityZh)"
    }

    /// 月報筆記標題（不超過筆記標題上限 10 個字）：「10月健身月報」
    func reportTitle(month: Int) -> String {
        "\(month)月\(reportNameZh)月報"
    }
}

enum InterestTrackers {

    static let builtIn: [InterestTracker] = [
        InterestTracker(id: "sports_outdoor", titleZh: "健身日曆", icon: "dumbbell.fill", activityZh: "去運動",
                        nodeIds: ["gym", "sports"], reportNameZh: "健身",
                        reportFocusZh: "依日期列出每次運動的項目（重訓、有氧、球類、跑步、瑜伽等）與地點；最後整理這個月最常做的運動。不要評論身材或體重。",
                        // 在場邊看球賽、拍運動用品不算自己去運動
                        excludedNodeIds: ["sports_game", "sports_gear"],
                        sensitiveNodeIds: ["body_composition"]),
        // 只算「真的出門去看」的照片：電影（電影院、電影票）、展覽、美術館、舞台劇（海報、書不算）
        InterestTracker(id: "film_arts", titleZh: "觀影與看展", icon: "film.fill", activityZh: "看電影或看展",
                        nodeIds: ["movie", "exhibition", "museum", "theater_show"], reportNameZh: "藝文",
                        reportFocusZh: "列出這個月看過的電影、展覽與舞台劇；名稱只用票根、海報的照片文字或畫面描述裡出現的，看不出名稱就寫「看了一部電影」，不要猜片名。"),
        InterestTracker(id: "music_live", titleZh: "演出足跡", icon: "music.mic", activityZh: "看演出",
                        nodeIds: ["live_music", "idol_fans"], reportNameZh: "演出",
                        reportFocusZh: "每場演出寫一段：日期、場地、演出者（只用照片文字或畫面描述裡出現的名稱），以及印象深刻的畫面。",
                        // 在家拍的專輯、手燈、電視畫面不算去看演出
                        excludedNodeIds: ["cheering_goods", "tv_screen"]),
        // 探店：住家、學校、公司附近拍的（在家吃飯、學餐）不算
        InterestTracker(id: "food_cafe", titleZh: "探店紀錄", icon: "fork.knife", activityZh: "出去吃",
                        nodeIds: ["meals", "street_food"], reportNameZh: "美食",
                        reportFocusZh: "依日期列出吃了什麼、在哪裡（店名只用照片文字或畫面描述裡出現的）；最後整理這個月常吃的種類。",
                        skipsRoutinePlaces: true),
        InterestTracker(id: "cafe_hopping", titleZh: "咖啡廳打卡", icon: "cup.and.saucer.fill", activityZh: "喝咖啡或吃甜點",
                        nodeIds: ["cafe_visit", "desserts", "coffee", "bubble_tea"], reportNameZh: "咖啡甜點",
                        reportFocusZh: "列出去過的咖啡廳與吃過的甜點、飲料（店名只用照片文字或畫面描述裡出現的）；最後整理這個月最常點的東西。",
                        skipsRoutinePlaces: true),   // 在家、公司泡的咖啡不算打卡
        // 旅行：用偵測到的旅程（和首頁的旅遊相簿相同），旅程中的每一天都算
        InterestTracker(id: "travel_photo", titleZh: "旅行足跡", icon: "airplane", activityZh: "在旅行",
                        nodeIds: ["sights", "transport", "travel_memories", "nature_scenery"], reportNameZh: "足跡",
                        reportFocusZh: "依日期整理去過的地方與看到的風景；同一趟旅行合在一起寫。",
                        usesTrips: true),
        InterestTracker(id: "outdoor_hiking", titleZh: "戶外紀錄", icon: "mountain.2.fill", activityZh: "去戶外",
                        nodeIds: ["outdoor"], reportNameZh: "戶外",
                        reportFocusZh: "列出每次登山、露營、滑雪或潛水的日期與地點（山名、步道名只用照片文字或地名裡出現的）。"),
        InterestTracker(id: "pets_animals", titleZh: "毛孩日記", icon: "pawprint.fill", activityZh: "拍了毛孩",
                        nodeIds: ["pets"], reportNameZh: "毛孩",
                        reportFocusZh: "整理這個月毛孩的日常與可愛瞬間，依日期寫成幾則小日記；不要替毛孩編造心情。"),
        InterestTracker(id: "anime_games", titleZh: "動漫與遊戲", icon: "gamecontroller.fill", activityZh: "有動漫或遊戲的照片",
                        nodeIds: ["anime_games"], reportNameZh: "動漫遊戲",
                        reportFocusZh: "列出這個月看的漫畫動畫、玩的遊戲、去的動漫展（作品名稱只用照片文字裡出現的）。"),
        InterestTracker(id: "crafts_collecting", titleZh: "收藏紀錄", icon: "shippingbox.fill", activityZh: "有收藏或手作的照片",
                        nodeIds: ["items_collections"], reportNameZh: "收藏",
                        reportFocusZh: "列出這個月新入手的收藏與完成的手作（名稱只用照片文字或畫面描述裡出現的）。",
                        excludedNodeIds: ["gadgets", "camera_gear"]),   // 手機、相機等 3C 產品不算收藏或手作
        InterestTracker(id: "fashion_lifestyle", titleZh: "穿搭日曆", icon: "tshirt.fill", activityZh: "記錄穿搭",
                        nodeIds: ["outfits", "beauty"], reportNameZh: "穿搭",
                        reportFocusZh: "依日期簡短描述每天的穿搭與妝容（顏色、單品）；最後整理這個月常穿的風格。不要評論身材。"),
        // 照片看不出人和人的關係（家庭合照已移除），改成記錄寶寶、生日、派對聚會這些重要時刻
        InterestTracker(id: "family_life", titleZh: "重要時刻", icon: "gift.fill", activityZh: "有重要時刻",
                        nodeIds: ["family", "milestones"], reportNameZh: "重要時刻",
                        reportFocusZh: "依日期整理這個月的重要時刻（生日、派對聚會、寶寶的日常）；不要猜測人物身分或關係。"),
        InterestTracker(id: "study_work", titleZh: "學習日曆", icon: "book.fill", activityZh: "有學習或工作紀錄",
                        nodeIds: ["documents", "workspace"], reportNameZh: "學習",   // 含課本與講義
                        reportFocusZh: "依日期整理讀書與工作的內容（課程、主題只用照片文字裡出現的）。",
                        excludedNodeIds: ["id_card"]),   // 證件、會員卡不是學習紀錄
    ]

    static func tracker(forInterest id: String) -> InterestTracker? {
        builtIn.first { $0.id == id }
    }

    /// 要顯示的興趣紀錄：選過的興趣依目錄順序；沒選（或只選「一般」）時，取照片最多的前幾個。
    static func trackers(selectedInterestIds: Set<String>,
                         photoCounts: [String: Int],
                         catalog: TaxonomyCatalog = .builtIn,
                         fallbackLimit: Int = 3) -> [InterestTracker] {
        let order = Dictionary(uniqueKeysWithValues: catalog.interests.map { ($0.id, $0.sortOrder) })
        let selected = builtIn
            .filter { selectedInterestIds.contains($0.id) }
            .sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        if !selected.isEmpty { return selected }
        return builtIn
            // 張數含子分類；扣掉不算的分類（例如球場觀賽）
            .map { tracker in (tracker, max(0, tracker.nodeIds.map { photoCounts[$0] ?? 0 }.reduce(0, +)
                                             - tracker.excludedNodeIds.map { photoCounts[$0] ?? 0 }.reduce(0, +))) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(fallbackLimit)
            .map { $0.0 }
    }

    /// 這個紀錄要算的所有分類（含子分類）
    static func expandedNodeIds(_ tracker: InterestTracker, catalog: TaxonomyCatalog = .builtIn) -> Set<String> {
        let excluded = Set(tracker.excludedNodeIds.flatMap { [$0] + catalog.descendants(of: $0).map(\.id) })
        return Set(tracker.nodeIds.flatMap { [$0] + catalog.descendants(of: $0).map(\.id) }).subtracting(excluded)
    }

    /// 已確認標籤中，屬於這個紀錄的照片
    static func assetIds(tagMap: [String: Set<String>], tracker: InterestTracker,
                         catalog: TaxonomyCatalog = .builtIn) -> Set<String> {
        let wanted = expandedNodeIds(tracker, catalog: catalog)
        return Set(tagMap.compactMap { $0.value.isDisjoint(with: wanted) ? nil : $0.key })
    }

    /// 有身體相關標籤（體組成）的照片：月報預設不放
    static func sensitiveAssetIds(tagMap: [String: Set<String>], tracker: InterestTracker,
                                  catalog: TaxonomyCatalog = .builtIn) -> Set<String> {
        guard !tracker.sensitiveNodeIds.isEmpty else { return [] }
        let sensitive = Set(tracker.sensitiveNodeIds.flatMap { [$0] + catalog.descendants(of: $0).map(\.id) })
        return Set(tagMap.compactMap { $0.value.isDisjoint(with: sensitive) ? nil : $0.key })
    }

    static func validationErrors(catalog: TaxonomyCatalog = .builtIn) -> [String] {
        var errors: [String] = []
        var seen = Set<String>()
        for tracker in builtIn {
            if !seen.insert(tracker.id).inserted { errors.append("重複的興趣紀錄：\(tracker.id)") }
            if catalog.interest(tracker.id) == nil { errors.append("興趣紀錄對應的興趣不存在：\(tracker.id)") }
            if tracker.nodeIds.isEmpty { errors.append("興趣紀錄沒有分類：\(tracker.id)") }
            for ref in tracker.nodeIds + tracker.sensitiveNodeIds + tracker.excludedNodeIds where catalog.node(ref) == nil {
                errors.append("興趣紀錄引用不存在的分類：\(tracker.id) → \(ref)")
            }
            if tracker.reportNameZh.isEmpty || tracker.reportNameZh.count > 4 {
                errors.append("月報名稱要 1–4 個字：\(tracker.id)")
            }
            if tracker.reportTitle(month: 12).count > 10 {
                errors.append("月報標題超過 10 個字：\(tracker.id)")
            }
        }
        return errors
    }
}

// MARK: - 常去地點

enum RoutinePlaces {
    /// 這個位置是不是在常去地點（住家、學校、公司）附近。預設 1.5 公里：校園、社區範圍不小。
    static func isNear(latitude: Double, longitude: Double, anchors: [PlaceAnchor], radiusKm: Double = 1.5) -> Bool {
        anchors.contains { distanceKm(latitude, longitude, $0.latitude, $0.longitude) <= radiusKm }
    }

    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

// MARK: - 日曆計算

/// 把照片依「拍攝日」分組，計算某個月的活動天數與連續週數。只做計算，不讀照片。
struct ActivityCalendar {
    let calendar: Calendar
    /// 當天 00:00 → 該日的照片（依拍攝時間排序）
    let photosByDay: [Date: [String]]

    init(photoDates: [String: Date], calendar: Calendar = .current) {
        self.calendar = calendar
        var grouped: [Date: [(String, Date)]] = [:]
        for (assetId, date) in photoDates {
            grouped[calendar.startOfDay(for: date), default: []].append((assetId, date))
        }
        photosByDay = grouped.mapValues { items in
            items.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.map { $0.0 }
        }
    }

    /// 這個月有紀錄的日子（由早到晚）
    func activeDays(inMonthOf date: Date) -> [Date] {
        photosByDay.keys
            .filter { calendar.isDate($0, equalTo: date, toGranularity: .month) }
            .sorted()
    }

    /// 這個月的照片（由早到晚）
    func assetIds(inMonthOf date: Date) -> [String] {
        activeDays(inMonthOf: date).flatMap { photosByDay[$0] ?? [] }
    }

    /// 連續幾週都有紀錄（從本週往回算；本週還沒有紀錄時從上週開始算，不會因為週初而歸零）
    func weekStreak(asOf date: Date) -> Int {
        let weeks = Set(photosByDay.keys.compactMap { weekStart($0) })
        guard var cursor = weekStart(date) else { return 0 }
        if !weeks.contains(cursor) {
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { return 0 }
            cursor = previous
        }
        var streak = 0
        while weeks.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// 有紀錄的月份（由新到舊），給月份切換使用
    var months: [Date] {
        let starts = Set(photosByDay.keys.compactMap { calendar.dateInterval(of: .month, for: $0)?.start })
        return starts.sorted(by: >)
    }

    private func weekStart(_ date: Date) -> Date? {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start
    }
}

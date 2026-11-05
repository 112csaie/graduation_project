// LiveEventDetector.swift
//
// 演唱會（音樂祭、Live House、舞台劇）依「場次」整理：同一個晚上、同一個場館的照片是一場。
// 主題樂園也用同一套方法整理成「場次」：同一天、同一個樂園的照片是一次（見 LiveEventProfile.themePark）。
//
// 為什麼不只靠 AI 看圖：演唱會照片常是暗場、晃動、遠遠的舞台，單張照片判斷不穩；
// 但「同一段時間、同一個地點」非常可靠。做法（只用既有照片向量、拍攝時間與 GPS，不重算向量）：
//
// 1. 起點（seed）：照片與演唱會類文字描述最像，且分數不輸給這張照片最像的其他分類太多；
//    或已被標成（含待確認、使用者確認）演唱會類。使用者按過「不是」的照片不算。
// 2. 依時間串起起點：間隔超過 3 小時、或地點相距超過 1.5 公里，就是不同場。
// 3. 成立條件：至少 3 張起點，其中至少 2 張是舞台類（手燈這類應援物只能當輔助，
//    避免在家拍幾張手燈就變成一場演唱會）。
// 4. 擴大：開演前後 2 小時內、在場館 1.5 公里內的照片一起收進來（排隊、周邊攤位、場外合照）；
//    沒有定位的照片只收演出期間（第一張到最後一張起點前後 30 分鐘）；一般螢幕截圖不收。
// 5. 螢幕截圖、從網路或別人那裡存下來的照片（isSaved）不當起點、也不收進場次：
//    存了一堆別人拍的演唱會照片或截圖，不代表自己去了一場演唱會。
//
// 門檻說明：專案沒有標註資料，以下是保守的初始值，應依實際圖庫調整。
// 本檔案只依賴 Foundation，可在 macOS 用 swift test 驗證。

import Foundation

struct EventPhoto: Equatable {
    let id: String
    let date: Date
    let latitude: Double?
    let longitude: Double?
    let isScreenshot: Bool
    /// 不是這支手機拍的：從網路、社群或聊天 App 存下來的照片（見 PhotoOrigin.looksSaved）
    var isSaved: Bool = false
    /// 起點的分類（concert…）；不是起點時為 nil。
    var seedNodeId: String? = nil
    var seedScore: Float = 0

    var hasLocation: Bool { latitude != nil && longitude != nil }
    /// 自己在現場拍的照片（不是截圖、也不是存下來的）
    var isOwnShot: Bool { !isScreenshot && !isSaved }
}

/// 判斷照片是不是自己用手機相機拍的（只看 PhotoKit 的中繼資料，不讀取照片內容）。
enum PhotoOrigin {
    /// 相機拍的照片長邊至少有這麼多像素（iPhone 前後鏡頭 3088～8064）；
    /// 社群、聊天 App 存下來的照片多半壓縮到 2048 以下。
    static let cameraMinLongSide = 2500

    /// 看起來是存下來的照片：沒有定位、不是原況照片（Live Photo），而且尺寸比相機拍的小。
    /// 自己拍的照片只要有定位或是原況照片就不算；關掉定位又裁切過的照片可能被誤判，所以兩個條件都要成立才算。
    static func looksSaved(pixelWidth: Int, pixelHeight: Int, hasLocation: Bool, isLivePhoto: Bool, isScreenshot: Bool) -> Bool {
        guard !isScreenshot, !hasLocation, !isLivePhoto else { return false }
        let longSide = max(pixelWidth, pixelHeight)
        return longSide > 0 && longSide < cameraMinLongSide
    }
}

struct DetectedLiveEvent: Identifiable, Equatable {
    /// 以第一張起點照片當作識別碼（同一場在不同次計算中一致）
    let id: String
    let startDate: Date
    let endDate: Date
    /// 依時間排序的所有照片（含起點）
    let assetIds: [String]
    let seedIds: [String]
    /// 這場最常見的舞台類分類：concert / theater_show（v25：音樂祭、Live House 併入演唱會）
    let kindNodeId: String
    /// 場館位置（起點照片定位的中位數）；起點都沒有定位時為 nil
    let latitude: Double?
    let longitude: Double?
    let coverAssetId: String
}

struct LiveEventConfig: Equatable {
    /// 起點：與演唱會類描述的相似度至少要這麼高
    var minSeedScore: Float = 0.22
    /// 起點：最多比這張照片最像的分類低這麼多
    var seedMarginFromBest: Float = 0.02
    var seedGapHours: Double = 3
    var radiusKm: Double = 1.5
    var expandHours: Double = 2
    var unlocatedPaddingMinutes: Double = 30
    var minSeeds = 3
    var minStageSeeds = 2
    /// 起點：容易誤認的畫面分數只要不低於「本分類 − 此值」就不算
    var confuserMargin: Float = 0.01
    var maxDurationHours: Double = 16

    static let `default` = LiveEventConfig()
}

/// 一種「場次」：用哪些分類當起點、怎麼分場
struct LiveEventProfile: Equatable {
    /// 場次相簿 id 的開頭（live-…、park-…）
    let idPrefix: String
    /// 可以單獨成立一場的分類
    let stageNodeIds: [String]
    /// 輔助類：可以當起點，但不能單獨成立一場
    let supportNodeIds: Set<String>
    let config: LiveEventConfig
    /// 對手分類：照片至少一樣像這些分類（例如展覽、周邊）時不當起點。
    /// 動漫展、特展也是暗暗的室內、聚光燈、大型看板，很容易被當成演唱會。
    var rivalNodeIds: Set<String> = []

    var nodeIds: Set<String> { Set(stageNodeIds).union(supportNodeIds) }

    /// 演唱會、音樂祭、Live House、舞台劇：同一個晚上、同一個場館
    static let concert = LiveEventProfile(idPrefix: "live-",
                                          stageNodeIds: ["concert", "theater_show"],
                                          supportNodeIds: ["cheering_goods"],
                                          config: .default,
                                          rivalNodeIds: ["exhibition", "museum", "comic_convention", "merch", "poster"])

    /// 主題樂園：同一天、同一個樂園。樂園很大、一待就是一整天，所以範圍比演唱會大、間隔可以比較長；
    /// 樂園照片常是人像合照，所以起點容許比最像的分類低多一點。
    static let themePark = LiveEventProfile(idPrefix: "park-",
                                            stageNodeIds: ["theme_park"],
                                            supportNodeIds: [],
                                            config: LiveEventConfig(minSeedScore: 0.22, seedMarginFromBest: 0.03,
                                                                    seedGapHours: 4, radiusKm: 3, expandHours: 1,
                                                                    unlocatedPaddingMinutes: 30, minSeeds: 3, minStageSeeds: 3,
                                                                    confuserMargin: 0.01, maxDurationHours: 16))

    static let all: [LiveEventProfile] = [.concert, .themePark]

    static func profile(forEventId id: String) -> LiveEventProfile? {
        all.first { id.hasPrefix($0.idPrefix) }
    }
}

enum LiveEventDetector {

    /// 舞台類（可以單獨成立一場）—— 演唱會類
    static let stageNodeIds: [String] = LiveEventProfile.concert.stageNodeIds
    /// 輔助類（應援物）：可以當起點，但不能單獨成立一場
    static let supportNodeIds: Set<String> = LiveEventProfile.concert.supportNodeIds
    static var liveNodeIds: Set<String> { LiveEventProfile.concert.nodeIds }

    /// 所有種類的場次（演唱會、主題樂園）用到的分類
    static var allNodeIds: Set<String> { Set(LiveEventProfile.all.flatMap(\.nodeIds)) }
    static var allStageNodeIds: [String] { LiveEventProfile.all.flatMap(\.stageNodeIds) }

    // MARK: 起點

    /// 用文字向量判斷一張照片是不是演唱會類起點。
    /// - Parameter prompts: 節點 → 該節點所有描述的向量（全部分類，用來比較「是不是這張照片最像的」）。
    static func seed(for embedding: [Float], prompts: [String: [[Float]]],
                     config: LiveEventConfig? = nil, profile: LiveEventProfile = .concert) -> (nodeId: String, score: Float)? {
        seed(for: embedding, matrix: PromptMatrix(prompts), config: config, profile: profile)
    }

    /// 同上，但文字向量已經排成矩陣（大量照片時只建一次矩陣，每張照片一次矩陣運算）。
    static func seed(for embedding: [Float], matrix: PromptMatrix,
                     config: LiveEventConfig? = nil, profile: LiveEventProfile = .concert) -> (nodeId: String, score: Float)? {
        let config = config ?? profile.config
        guard !embedding.isEmpty, let rowScores = matrix.scores(for: embedding) else { return nil }
        var bestOverall: Float = -1
        var scores: [String: Float] = [:]
        for key in matrix.rowsByKey.keys {
            guard let best = matrix.best(key, in: rowScores) else { continue }
            scores[key] = best
            // 「這張照片最像什麼」只比真正的分類；容易誤認的畫面只用來排除對應的演唱會類
            if !key.hasSuffix(TaxonomyNode.confuserSuffix) { bestOverall = max(bestOverall, best) }
        }
        var bestLive: (nodeId: String, score: Float)?
        for nodeId in profile.nodeIds.sorted() {
            guard let best = scores[nodeId] else { continue }
            // 比較像容易誤認的畫面（例如晚上在店門口、海報前合照之於 Live House）就不當起點
            if let confused = scores[TaxonomyNode.confuserKey(nodeId)], confused >= best - config.confuserMargin { continue }
            if best > (bestLive?.score ?? -1) { bestLive = (nodeId, best) }
        }
        guard let bestLive, bestLive.score >= config.minSeedScore,
              bestLive.score >= bestOverall - config.seedMarginFromBest else { return nil }
        // 至少一樣像展覽、周邊這些對手分類 → 不算
        if profile.rivalNodeIds.contains(where: { (scores[$0] ?? -1) >= bestLive.score - config.confuserMargin }) { return nil }
        return bestLive
    }

    /// 照片像對手分類（展覽、周邊…）至少和像這種場次一樣：自動標上的演唱會類標籤也不當起點（手動確認的照算）。
    static func isRival(_ embedding: [Float], matrix: PromptMatrix, profile: LiveEventProfile) -> Bool {
        guard !profile.rivalNodeIds.isEmpty, !embedding.isEmpty, let rowScores = matrix.scores(for: embedding) else { return false }
        let live = profile.nodeIds.compactMap { matrix.best($0, in: rowScores) }.max() ?? -1
        let rival = profile.rivalNodeIds.compactMap { matrix.best($0, in: rowScores) }.max() ?? -1
        return rival >= live - profile.config.confuserMargin
    }

    // MARK: 場次

    static func detect(photos: [EventPhoto], config: LiveEventConfig? = nil,
                       profile: LiveEventProfile = .concert) -> [DetectedLiveEvent] {
        let config = config ?? profile.config
        let stageNodeIds = profile.stageNodeIds
        let sorted = photos.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        // 截圖、存下來的照片不當起點
        let seeds = sorted.filter { $0.seedNodeId != nil && $0.isOwnShot }
        guard !seeds.isEmpty else { return [] }

        // 1. 依時間與地點把起點串成一組一組
        var groups: [[EventPhoto]] = []
        for seed in seeds {
            if var last = groups.last, let previous = last.last,
               seed.date.timeIntervalSince(previous.date) <= config.seedGapHours * 3600,
               !isFar(seed, from: last, config: config) {
                last.append(seed)
                groups[groups.count - 1] = last
            } else {
                groups.append([seed])
            }
        }

        // 2. 成立條件與擴大
        let allSeedIds = Set(seeds.map(\.id))
        var used = Set<String>()
        var events: [DetectedLiveEvent] = []
        for group in groups {
            let stage = group.filter { stageNodeIds.contains($0.seedNodeId ?? "") }
            guard group.count >= config.minSeeds, stage.count >= config.minStageSeeds,
                  let first = group.first, let last = group.last,
                  last.date.timeIntervalSince(first.date) <= config.maxDurationHours * 3600 else { continue }

            let located = group.filter(\.hasLocation)
            let center: (lat: Double, lon: Double)? = located.isEmpty ? nil
                : (median(located.compactMap(\.latitude)), median(located.compactMap(\.longitude)))
            let windowStart = first.date.addingTimeInterval(-config.expandHours * 3600)
            let windowEnd = last.date.addingTimeInterval(config.expandHours * 3600)
            let padding = config.unlocatedPaddingMinutes * 60
            let seedIds = Set(group.map(\.id))

            var members: [String] = []
            for photo in sorted where photo.date >= windowStart && photo.date <= windowEnd && !used.contains(photo.id) {
                let include: Bool
                if seedIds.contains(photo.id) {
                    include = true
                } else if allSeedIds.contains(photo.id) || !photo.isOwnShot {
                    include = false   // 別場的起點；截圖、存下來的照片
                } else if let lat = photo.latitude, let lon = photo.longitude, let center {
                    include = TripDetector.haversineKm(lat, lon, center.lat, center.lon) <= config.radiusKm
                } else {
                    // 沒有定位（或場館位置未知）：只收演出期間
                    include = photo.date >= first.date.addingTimeInterval(-padding)
                        && photo.date <= last.date.addingTimeInterval(padding)
                }
                if include { members.append(photo.id) }
            }
            used.formUnion(members)

            var kindCounts: [String: Int] = [:]
            for photo in stage { kindCounts[photo.seedNodeId!, default: 0] += 1 }
            let kind = stageNodeIds.max { (kindCounts[$0] ?? 0, -(stageNodeIds.firstIndex(of: $0) ?? 0))
                < (kindCounts[$1] ?? 0, -(stageNodeIds.firstIndex(of: $1) ?? 0)) } ?? stageNodeIds[0]
            let cover = stage.max { ($0.seedScore, $1.id) < ($1.seedScore, $0.id) } ?? first

            events.append(DetectedLiveEvent(
                id: profile.idPrefix + first.id,
                startDate: first.date,
                endDate: last.date,
                assetIds: members,
                seedIds: group.map(\.id),
                kindNodeId: kind,
                latitude: center?.lat,
                longitude: center?.lon,
                coverAssetId: cover.id
            ))
        }
        return events.sorted { ($0.startDate, $0.id) > ($1.startDate, $1.id) }
    }

    /// 起點和這一組已有定位的起點相距太遠 → 不同場
    private static func isFar(_ photo: EventPhoto, from group: [EventPhoto], config: LiveEventConfig) -> Bool {
        guard let lat = photo.latitude, let lon = photo.longitude else { return false }
        let located = group.filter(\.hasLocation)
        guard !located.isEmpty else { return false }
        let centerLat = median(located.compactMap(\.latitude))
        let centerLon = median(located.compactMap(\.longitude))
        return TripDetector.haversineKm(lat, lon, centerLat, centerLon) > config.radiusKm
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

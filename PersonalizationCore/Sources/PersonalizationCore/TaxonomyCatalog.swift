// TaxonomyCatalog.swift
//
// 個人化分類系統的「唯一」分類定義來源（single source of truth）。
// UI、推薦規則、標記器、資料庫 seed 全部從這裡讀取，請不要在其他元件中寫死分類名稱。
//
// 擴充方式：
//   1. 在 `TaxonomyCatalog.builtIn` 裡新增節點（L1 / L2 / L3）或興趣定位。
//   2. 調高 `catalogVersion`，App 下次啟動會把新節點同步進資料庫（不刪除舊資料）。
//   3. 新的 prompt 會在裝置上用既有的 MobileCLIP 文字模型自動補算向量，
//      既有照片向量不需要重算（標記器只重新做「照片向量 × 文字向量」比對）。
//
// 本檔案只依賴 Foundation，可在 iOS App 與 macOS `swift test` 共用。

import Foundation

// MARK: - 辨識能力等級

/// 描述「現有模型（MobileCLIP 向量相似度）對這個分類能做到什麼程度」。
/// 這是避免把模型做不到的事情（例如活動目的）當成確定事實的關鍵欄位。
enum RecognitionMode: String, Codable, CaseIterable {
    /// 可由視覺內容直接判斷（例如：麵食、貓、夕陽）。分數夠高時可自動標記為「已確認」。
    case visual
    /// 只有視覺線索、無法確定情境（例如：演唱會、Cosplay）。最多只會成為「待確認」候選。
    case assisted
    /// 由其他標籤組合推論（例如：合照 + 地標 → 旅行合照）。只會成為「待確認」候選。
    case derived
    /// 模型無法可靠判斷（例如：情侶合照、簽名會），只能由使用者手動加入。
    case manualOnly
}

// MARK: - 分類節點

struct TaxonomyNode: Identifiable, Hashable, Codable {
    let id: String
    let parentId: String?
    let level: Int            // 1 = 大分類, 2 = 中分類, 3 = 小分類
    let nameZh: String
    let nameEn: String
    let summaryZh: String
    let summaryEn: String
    let examplesZh: String
    let icon: String          // SF Symbol 名稱
    let recognition: RecognitionMode
    let prompts: [String]     // 給 MobileCLIP 文字模型的英文描述（會套用 "a photo of …" 模板）
    /// 衍生規則：每一組至少要有一個節點出現（組與組之間為 AND）。
    let requiresAnyOf: [[String]]
    /// 選取大分類時是否自動啟用此子分類。
    let enabledByDefault: Bool
    let sortOrder: Int
    /// 這些節點的分數「不低於」本節點時，本節點不自動確認。
    /// 例：LINE 聊天截圖（吉伊卡哇主題）也有對話框與可愛角色，若「聊天截圖」一樣像或更像，就不算「漫畫截圖」。
    var suppressedBy: [String] = []
    /// 容易被誤認成本分類的畫面（英文描述）。照片比較像這些畫面時，本分類不自動確認、也不列入待確認。
    /// 例：「跑步」← 單腳站著擺姿勢拍照；「Live House」← 晚上在店門口、海報前合照。
    var confusers: [String] = []
    /// 一眼就看得出來的分類（貓、狗…）：就算不是你選的大分類、或照片裡還有別的東西，也照樣標上。
    var distinct: Bool = false
    /// 這個分類自己的確認門檻（nil = 用全域的 TaggingThresholds.acceptScore）。由桌面「相簿主題設定」資料夾調整。
    var acceptScore: Float? = nil
    /// 看起來像就好、但不能只靠畫面確認（例如收據：有 QR code 的東西都很像電子發票）。
    /// 畫面像只會觸發照片文字辨識，要文字也對（「電子發票」「統一編號」…）才標上。
    var requiresText: Bool = false

    /// 混淆畫面的文字向量存在 TaxonomyPrompts 的這個 node_id 底下（不是分類節點，不會被標到照片上）。
    static func confuserKey(_ id: String) -> String { id + confuserSuffix }
    static let confuserSuffix = "#not"

    func displayName(english: Bool) -> String { english ? nameEn : nameZh }
    func displaySummary(english: Bool) -> String { english ? summaryEn : summaryZh }
}

// MARK: - 興趣定位

/// 興趣定位只代表使用者「偏好」，只影響推薦與排序，絕不參與照片內容辨識。
struct InterestProfile: Identifiable, Hashable, Codable {
    let id: String
    let nameZh: String
    let nameEn: String
    let summaryZh: String
    let summaryEn: String
    let icon: String
    /// 依優先順序排列的推薦大分類（第一個權重最高）。
    let recommendedTopLevelIds: [String]
    /// 相關子分類，用來在推薦清單中提升排序。
    let relatedNodeIds: [String]
    let sortOrder: Int

    func displayName(english: Bool) -> String { english ? nameEn : nameZh }
    func displaySummary(english: Bool) -> String { english ? summaryEn : summaryZh }
}

// MARK: - 目錄

struct TaxonomyCatalog {
    let catalogVersion: Int
    /// 「相簿主題設定」資料夾的調整簽章（沒有調整時為空字串）；內容一變，App 會重新同步分類並重新比對自動標籤
    let tuningSignature: String
    let nodes: [TaxonomyNode]
    let interests: [InterestProfile]
    /// 已移除的節點 → 取代它的節點（升級時搬移標籤與偏好）。
    let nodeRedirects: [String: String]
    /// 新的大分類 ← 舊的大分類（升級時，選過舊分類的使用者自動選取新分類）。
    let topLevelAdditions: [String: [String]]
    /// 已移除的興趣定位 → 取代它的興趣定位（升級時搬移使用者選過的興趣）。
    let interestRedirects: [String: String]

    private let nodesById: [String: TaxonomyNode]
    private let childrenByParent: [String: [TaxonomyNode]]

    init(catalogVersion: Int, nodes: [TaxonomyNode], interests: [InterestProfile],
         nodeRedirects: [String: String] = [:], topLevelAdditions: [String: [String]] = [:],
         interestRedirects: [String: String] = [:], tuningSignature: String = "") {
        self.catalogVersion = catalogVersion
        self.tuningSignature = tuningSignature
        self.interestRedirects = interestRedirects
        self.nodes = nodes
        self.nodeRedirects = nodeRedirects
        self.topLevelAdditions = topLevelAdditions
        self.interests = interests.sorted { $0.sortOrder < $1.sortOrder }
        var byId: [String: TaxonomyNode] = [:]
        var byParent: [String: [TaxonomyNode]] = [:]
        for node in nodes {
            byId[node.id] = node
            if let parent = node.parentId {
                byParent[parent, default: []].append(node)
            }
        }
        for key in byParent.keys {
            byParent[key]?.sort { $0.sortOrder < $1.sortOrder }
        }
        self.nodesById = byId
        self.childrenByParent = byParent
    }

    /// 存進資料庫的目錄版本標記：版本或調整內容改變時，App 會重新同步分類
    var catalogStamp: String {
        tuningSignature.isEmpty ? String(catalogVersion) : "\(catalogVersion)+\(tuningSignature)"
    }

    var topLevelNodes: [TaxonomyNode] {
        nodes.filter { $0.level == 1 }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func node(_ id: String) -> TaxonomyNode? { nodesById[id] }

    func interest(_ id: String) -> InterestProfile? { interests.first { $0.id == id } }

    func children(of id: String) -> [TaxonomyNode] { childrenByParent[id] ?? [] }

    /// 所有子孫節點（不含自己）。
    func descendants(of id: String) -> [TaxonomyNode] {
        var result: [TaxonomyNode] = []
        var stack = children(of: id)
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: children(of: next.id))
        }
        return result
    }

    /// 由下往上的祖先鏈（不含自己），例如 noodle_dish → [meals, food_drink]。
    func ancestors(of id: String) -> [TaxonomyNode] {
        var result: [TaxonomyNode] = []
        var current = nodesById[id]?.parentId
        var guardCounter = 0
        while let parentId = current, let parent = nodesById[parentId], guardCounter < 10 {
            result.append(parent)
            current = parent.parentId
            guardCounter += 1
        }
        return result
    }

    func topLevelId(of id: String) -> String? {
        guard let node = nodesById[id] else { return nil }
        if node.level == 1 { return node.id }
        return ancestors(of: id).last?.id
    }

    /// 可以被標記到照片上的節點（L2 / L3）。
    var taggableNodes: [TaxonomyNode] {
        nodes.filter { $0.level >= 2 }
    }

    /// 以名稱（中英文、不分大小寫）搜尋節點。
    func searchNodes(matching text: String) -> [TaxonomyNode] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return nodes.filter {
            $0.nameZh.lowercased().contains(query)
                || $0.nameEn.lowercased().contains(query)
                || $0.examplesZh.lowercased().contains(query)
        }
        .sorted { ($0.level, $0.sortOrder) < ($1.level, $1.sortOrder) }
    }

    /// 基本完整性檢查：ID 唯一、父節點存在、層級正確、規則引用的節點存在。
    func validationErrors() -> [String] {
        var errors: [String] = []
        var seen = Set<String>()
        for node in nodes {
            if !seen.insert(node.id).inserted { errors.append("重複的節點 ID：\(node.id)") }
            if node.level == 1 {
                if node.parentId != nil { errors.append("L1 節點不能有父節點：\(node.id)") }
            } else {
                guard let parentId = node.parentId, let parent = nodesById[parentId] else {
                    errors.append("找不到父節點：\(node.id)")
                    continue
                }
                if parent.level != node.level - 1 { errors.append("層級錯誤：\(node.id)") }
            }
            if node.recognition == .derived && node.requiresAnyOf.isEmpty {
                errors.append("衍生節點缺少規則：\(node.id)")
            }
            if (node.recognition == .visual || node.recognition == .assisted) && node.level >= 2 && node.prompts.isEmpty {
                errors.append("可辨識節點缺少 prompt：\(node.id)")
            }
            if !node.confusers.isEmpty && node.recognition != .visual && node.recognition != .assisted {
                errors.append("只有可辨識節點能設定混淆畫面：\(node.id)")
            }
            if node.confusers.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                errors.append("混淆畫面描述是空的：\(node.id)")
            }
            if node.id.hasSuffix(TaxonomyNode.confuserSuffix) { errors.append("節點 ID 不能以 #not 結尾：\(node.id)") }
            for ref in node.suppressedBy where nodesById[ref] == nil {
                errors.append("排除規則引用不存在的節點：\(node.id) → \(ref)")
            }
            for group in node.requiresAnyOf {
                for ref in group where nodesById[ref] == nil {
                    errors.append("規則引用不存在的節點：\(node.id) → \(ref)")
                }
            }
        }
        for (old, new) in nodeRedirects {
            if nodesById[old] != nil { errors.append("被取代的節點仍在目錄中：\(old)") }
            if nodesById[new] == nil { errors.append("取代節點不存在：\(old) → \(new)") }
        }
        for (new, olds) in topLevelAdditions {
            if nodesById[new]?.level != 1 { errors.append("新增的大分類不存在：\(new)") }
            // 來源可以是目錄中的大分類，或本版移除（有取代節點）的舊大分類
            for old in olds where nodesById[old]?.level != 1 && nodeRedirects[old] == nil {
                errors.append("來源大分類不存在：\(old)")
            }
        }
        for (old, new) in interestRedirects {
            if interests.contains(where: { $0.id == old }) { errors.append("被取代的興趣仍在目錄中：\(old)") }
            if !interests.contains(where: { $0.id == new }) { errors.append("取代興趣不存在：\(old) → \(new)") }
        }
        for interest in interests {
            for ref in interest.recommendedTopLevelIds where nodesById[ref]?.level != 1 {
                errors.append("興趣 \(interest.id) 推薦了非大分類節點：\(ref)")
            }
            for ref in interest.relatedNodeIds where nodesById[ref] == nil {
                errors.append("興趣 \(interest.id) 引用不存在的節點：\(ref)")
            }
        }
        return errors
    }
}

// MARK: - 內建目錄資料
//
// v25：音樂祭、Live House 併入「演唱會」（照片分不出來，對使用者來說也不必分；場次相簿有場館名稱）。
// v24：移除「手機截圖」小分類，改成「照片」分頁的「截圖」切換。
// v23：專輯併入「專輯與周邊」（原「周邊小物」改名）。
// v23：「手機截圖」改用 iPhone 的截圖標記（像自拍用系統自拍相簿），不看畫面猜。
// v22：移除「婚禮」；櫻花併入「花」；生日派對、KTV 合併成「派對聚會」；「3C 與相機」獨立成大分類。
// v21：電影院＋票根合併成「電影」；小卡、卡冊、壓克力立牌、徽章、吊飾合併成「周邊小物」；移除「盲盒」「畢業」。
// v20：KTV 改成看得到包廂（早餐店的價目表、彩色吊燈不算）。
// v19：票根加回畫面描述（仍要照片文字佐證）；專輯、小卡、壓克力立牌、徽章、拍貼、文具、騎單車改寫描述並加上容易誤認的畫面。
// v18：「人物照」排除公車站廣告牌、路燈應援旗、大型看板；「咖啡廳」不再比對店門（快閃店、主題店面容易被誤認）。
// v17：不再偵測人臉。自拍改用系統「自拍」相簿；單人照、雙人合照、多人合照合併為「人物照」。
// v16：移除「家庭合照」（看不出人和人的關係）。
// v14：「收據發票」要照片文字佐證才標上（有 QR code 的東西不再都被當成收據）；
//      「動物與寵物」改為「動物」、「寵物」改為「貓狗與小動物」（拍到貓狗不一定是寵物）；
//      主題樂園加上更多描述，並和演唱會一樣整理成「場次」。
// v13：「夕陽」改為「日出與夕陽」（模型分不出日出和夕陽，放在同一個分類）。
// v12：刪除「瑜伽與舞蹈」；「票根與門票」只靠照片文字（電影票上的放映、票種、票號…）或手動加入；
//      貓、狗等一眼看得出的動物不再因為沒選「動物與寵物」或畫面裡有別的東西而漏標；
//      新增「拍貼與明信片」「吊飾與鑰匙圈」，不再被當成專輯、壓克力立牌；
//      畢業典禮、婚禮不算演唱會或 Live House；展覽照片不算舞台劇。
// v11：「票根與門票」的描述加上影城電影票的樣子（感熱紙長條、有條碼，常好幾張拿在手上）。
// v10：移除「健身鏡前照」（所有鏡前照都被歸進來）；「體組成紀錄」改成只靠照片文字（InBody、體脂肪…）或手動加入；
//      新增「菜單」與「證件與卡片」：菜單不再被當成體組成、收據，學生證、身分證不再被當成票根或收據；
//      「票根與門票」改成只會成為待確認（需要你確認或照片文字佐證），「收據發票」描述改得更具體。
// v9：新增「課本與講義」（學習與工作），讀書用的課本不再被算成「書籍與閱讀」；
//     「瑜伽與舞蹈」更嚴格：比較像房間、居家、空房間裡走動的照片不算。
// v8：描述改得更精準（要拍到「正在做」的動作），並新增「容易誤認的畫面」：照片比較像這些畫面時不算。
//     例：單腳站著擺姿勢不算跑步；學校禮堂、體育館裡的表演不算球類運動；舞台表演、電視打歌不算瑜伽與舞蹈；
//     晚上在店門口、應援海報前合照不算 Live House 或演唱會。
// v7：「運動與戶外」新增中分類「健身房」（健身、重訓、有氧器材、健身鏡前照、體組成紀錄），給健身日曆使用。
// v6：分類重新平衡，面向所有興趣，不再偏重追星與動漫，也少用流行用語。
//     ・美食只保留 MobileCLIP 分得好的類別：「咖啡廳與甜點」併入「美食與飲品」；
//       拉麵／義大利麵／烏龍麵／牛肉麵合併為「麵食」；具體料理要比「餐點」明顯更像才會自動標記
//       （避免複雜的大鍋菜都被當成火鍋、牽絲起司被當成義大利麵）。
//     ・新增大分類「電影與藝文」（電影院、票根、電影海報、展覽、美術館、舞台劇、閱讀）。
//     ・「追星」併入「音樂與表演」的「偶像與粉絲」；「周邊與推活」「娃娃與娃活」併入「收藏與手作」。
//     ・「動漫與遊戲」精簡；運動新增「瑜伽與舞蹈」「運動用品」，「運動賽事」改為「球場觀賽」。
//     ・移除的分類全部有對應（nodeRedirects）：手動標籤與偏好會搬過去，不會遺失；自動標籤用既有照片向量重新比對。
// v5：移除「其他周邊」（與立牌、徽章、公仔大量重複），公仔併入「立牌、徽章與公仔」；
//     新增「聊天截圖」，聊天截圖（例如吉伊卡哇主題的 LINE）不再被當成「漫畫截圖」。
// v4：娃娃類合併成「娃娃」並新增「娃活」；新增「漫畫」中分類（含漫畫截圖）；新的大分類「周邊與推活」。
// v3：取代舊的 45 類 Classification，改為以「興趣與生活情境」設計的分類（L1 → L2 → L3）。
// 既有節點 ID 盡量保留，使用者已確認的標籤不會失效。

extension TaxonomyCatalog {

    /// 內建目錄，套用桌面「相簿主題設定」資料夾的調整（沒有調整時與 untuned 相同）
    static let builtIn: TaxonomyCatalog = untuned.applying(TaxonomyTuning.current, signature: TaxonomyTuning.currentSignature)

    /// 內建目錄的原始設定（沒有套用任何調整）
    static let untuned: TaxonomyCatalog = TaxonomyCatalog(
        catalogVersion: 25,
        nodes: BuiltInTaxonomy.nodes,
        interests: BuiltInTaxonomy.interests,
        nodeRedirects: BuiltInTaxonomy.nodeRedirects,
        topLevelAdditions: BuiltInTaxonomy.topLevelAdditions,
        interestRedirects: BuiltInTaxonomy.interestRedirects
    )

    /// 套用調整；調整有錯（引用不存在的分類、門檻不合理）或套用後目錄檢查不通過時，沿用原本的目錄
    func applying(_ tuning: TaxonomyTuning, signature: String) -> TaxonomyCatalog {
        guard !tuning.isEmpty else { return self }
        let errors = tuning.validationErrors(baseNodeIds: Set(nodes.map(\.id)))
        guard errors.isEmpty else {
            print("[主題設定] 調整有錯誤，沿用內建設定：\(errors.joined(separator: "；"))")
            return self
        }
        let tuned = TaxonomyCatalog(catalogVersion: catalogVersion, nodes: tuning.apply(to: nodes), interests: interests,
                                    nodeRedirects: nodeRedirects, topLevelAdditions: topLevelAdditions,
                                    interestRedirects: interestRedirects, tuningSignature: signature)
        let tunedErrors = tuned.validationErrors()
        guard tunedErrors.isEmpty else {
            print("[主題設定] 套用後分類目錄有錯誤，沿用內建設定：\(tunedErrors.joined(separator: "；"))")
            return self
        }
        return tuned
    }
}

private enum BuiltInTaxonomy {

    static func l1(_ id: String, _ zh: String, _ en: String, _ summaryZh: String, _ summaryEn: String,
                   _ examples: String, _ icon: String, _ order: Int) -> TaxonomyNode {
        TaxonomyNode(id: id, parentId: nil, level: 1, nameZh: zh, nameEn: en,
                     summaryZh: summaryZh, summaryEn: summaryEn, examplesZh: examples, icon: icon,
                     recognition: .visual, prompts: [], requiresAnyOf: [], enabledByDefault: true, sortOrder: order)
    }

    static func l2(_ id: String, _ parent: String, _ zh: String, _ en: String, _ icon: String, _ order: Int) -> TaxonomyNode {
        TaxonomyNode(id: id, parentId: parent, level: 2, nameZh: zh, nameEn: en,
                     summaryZh: "", summaryEn: "", examplesZh: "", icon: icon,
                     recognition: .manualOnly, prompts: [], requiresAnyOf: [], enabledByDefault: true, sortOrder: order)
    }

    static func l3(_ id: String, _ parent: String, _ zh: String, _ en: String,
                   _ mode: RecognitionMode, _ prompts: [String],
                   requires: [[String]] = [], enabled: Bool = true, order: Int = 0,
                   suppressedBy: [String] = [], confusers: [String] = [], distinct: Bool = false,
                   requiresText: Bool = false) -> TaxonomyNode {
        var node = TaxonomyNode(id: id, parentId: parent, level: 3, nameZh: zh, nameEn: en,
                                summaryZh: "", summaryEn: "", examplesZh: "", icon: "tag",
                                recognition: mode, prompts: prompts, requiresAnyOf: requires, enabledByDefault: enabled, sortOrder: order,
                                suppressedBy: suppressedBy, confusers: confusers, distinct: distinct)
        node.requiresText = requiresText
        return node
    }

    // 容易誤認的畫面（只用來排除，不會成為分類）
    /// 擺姿勢拍照：單腳站、跳起來、全身照
    static let posingPerson = ["a person posing for a photo standing on one leg", "a full-body photo of a person posing outdoors",
                               "a person jumping in the air for a fun photo"]
    /// 學校禮堂、體育館裡的活動（地上有球場線，但不是在打球）
    static let schoolHall = ["a school event or performance in an indoor gymnasium", "an audience sitting in an indoor gymnasium",
                             "a stage with a projector screen in a school hall"]
    /// 晚上在店門口、應援海報前合照（不是在看演出）
    static let notAConcert = ["friends posing in front of a cafe entrance at night",
                              "a birthday banner with a person's photo hung on a cafe wall",
                              "a person holding a phone inside a car at night", "a lit shop sign on a building at night",
                              "a graduation ceremony on a stage in a school auditorium",
                              // v25：動漫特展的角色看板、展場（燈光暗、大型人物看板，常被當成演唱會）
                              "a person posing next to life-size anime character standees at an exhibition",
                              "an anime exhibition hall with large character panels and spotlights"]

    /// 一般的紙張與卡片（不是票根、也不是收據）
    static let plainPaperOrCard = ["a plain sheet of printed paper", "a business card", "a bank card or credit card",
                                   "a printed document page"]

    /// 具體料理：要比一般「餐點」明顯更像才自動標記（MobileCLIP 對複雜菜色容易誤判）。
    static let genericMeal = ["restaurant_meal"]

    /// 已移除的節點 → 取代它的節點。升級時會把使用者的標籤與偏好移過去（手動標籤不會遺失）。
    static let nodeRedirects: [String: String] = [
        // v21：電影院＋票根合併成「電影」；小卡、卡冊、壓克力立牌、徽章、吊飾合併成「周邊小物」；
        //      移除「盲盒」（併入公仔）與「畢業」（手動標過的移到「重要時刻」）
        "ticket_stub": "movie",
        "photocard": "merch",
        "photocard_binder": "merch",
        "acrylic_stand": "merch",
        "badge": "merch",
        "keychain": "merch",
        "blind_box": "figure",
        "graduation": "milestones",
        // v23：專輯併入「專輯與周邊」
        "album_cd": "merch",
        // v24：「手機截圖」移除（照片分頁有「截圖」切換）；手動標過的移到「螢幕截圖」
        "screenshot": "screens",
        // v25：音樂祭、Live House 併入演唱會
        "music_festival": "concert",
        "live_house": "concert",
        // v22：櫻花併入花；生日派對、KTV 合併成「派對聚會」；移除「婚禮」（手動標過的移到「重要時刻」）
        "cherry_blossom": "flowers",
        "birthday_party": "party",
        "karaoke": "party",
        "wedding": "milestones",
        // v17：單人照、雙人合照、多人合照合併成「人物照」；v16 移除的家庭合照也直接移到人物照
        "family_photo": "portrait",
        "group_photo": "portrait",
        "duo_photo": "portrait",
        // v12：瑜伽與舞蹈辨識不準（舞台劇、空房間都會被歸進來），手動確認過的改放「運動」
        "yoga_dance": "sports",
        // v10：鏡前照常常不是在健身房（手動確認過的改成「健身」）
        "gym_selfie": "workout",
        // v4／v5 舊對應（目標改為 v6 仍存在的節點）
        "bjd_doll": "stuffed_toy",
        "character_doll": "stuffed_toy",
        "doll_styling": "collectibles",
        "anime_goods": "collectibles",
        "figures_merch": "collectibles",
        "anime_merch": "collectibles",

        // v6 美食與飲品
        "cafe_dessert": "food_drink",
        "noodles": "meals",
        "ramen": "noodle_dish",
        "pasta": "noodle_dish",
        "udon": "noodle_dish",
        "beef_noodle": "noodle_dish",
        "steak": "bbq",
        "korean_food": "restaurant_meal",
        "street_snack": "restaurant_meal",
        "home_cooking": "meals",
        "home_meal": "restaurant_meal",
        "brunch": "restaurant_meal",
        "bar": "drinks",
        "dessert": "cake",
        "afternoon_tea": "cake",
        "shaved_ice": "ice_cream",
        "latte_art": "coffee",
        "tea": "bubble_tea",
        "cafe_storefront": "cafe",
        "theme_cafe": "cafe",

        // v6 追星 → 音樂與表演「偶像與粉絲」
        "idol_fandom": "music_shows",
        "fan_merch": "idol_fans",
        "fan_activities": "idol_fans",
        "idol_media": "idol_fans",
        "idol_billboard": "idol_fans",
        "birthday_support": "idol_fans",

        // v6 動漫與遊戲精簡
        "manga_screenshot": "manga",
        "anime_scenes": "manga_comics",
        "game_collection": "video_game",
        "pilgrimage": "anime_events",

        // v6 周邊與推活、娃娃與娃活 → 收藏與手作
        "fan_goods": "items_collections",
        "cards_prints": "collectibles",
        "stands_badges": "collectibles",
        "oshi_activities": "collectibles",
        "ita_bag": "merch",
        "oshi_photo_with_goods": "merch",
        "fan_event": "exhibition",
        "oshi_cafe": "cafe",
        "doll_photography": "items_collections",
        "dolls": "collectibles",
        "doll_scenes": "collectibles",
        "plush_doll": "stuffed_toy",
        "doll_outfit": "stuffed_toy",
        "doll_outing": "stuffed_toy",
        "doll_with_food": "stuffed_toy",
        "doll_with_scenery": "stuffed_toy",
        "doll_meetup": "stuffed_toy",
        "doll_studio": "stuffed_toy",
    ]

    /// 新的大分類 ← 舊的大分類：升級時，選過舊分類的使用者會自動選取新分類（含預設子分類）。
    static let topLevelAdditions: [String: [String]] = [
        "food_drink": ["cafe_dessert"],
        "music_shows": ["idol_fandom"],
        "items_collections": ["fan_goods", "doll_photography"],
        // 電影、展覽原本在「娛樂與活動」，舞台劇原本在「音樂與表演」
        "film_arts": ["entertainment_events", "music_shows"],
        // v22：3C 與相機原本在「收藏與手作」
        "tech_gear": ["items_collections"],
    ]

    /// 已移除的興趣定位 → 取代它的興趣定位。
    static let interestRedirects: [String: String] = [
        "idol_fandom": "music_live",
        "doll_photo": "crafts_collecting",
    ]

    static let nodes: [TaxonomyNode] = [
        // ───────── 1. 美食與飲品 ─────────
        l1("food_drink", "美食與飲品", "Food & Drinks", "餐點、小吃、甜點、飲料與咖啡廳", "Meals, snacks, desserts, drinks and cafes", "麵食、壽司、夜市、蛋糕、咖啡廳", "fork.knife", 1),
        l2("meals", "food_drink", "餐點", "Meals", "fork.knife.circle", 1),
        l3("restaurant_meal", "meals", "餐點", "Meals", .visual, ["a meal on a table", "plated food dishes on a dining table"], order: 1),
        l3("noodle_dish", "meals", "麵食", "Noodles", .visual,
           ["a bowl of noodle soup", "a plate of noodles", "a bowl of ramen"], order: 2, suppressedBy: genericMeal),
        l3("bento", "meals", "飯類與便當", "Rice & Bento", .visual,
           ["a bento lunch box", "a bowl of rice with toppings"], order: 3, suppressedBy: genericMeal),
        l3("sushi", "meals", "壽司與生魚片", "Sushi & Sashimi", .visual,
           ["sushi", "slices of raw fish sashimi"], order: 4, suppressedBy: genericMeal),
        l3("bbq", "meals", "燒烤與牛排", "Grill & Steak", .visual,
           ["meat grilling on a barbecue grill", "a steak on a plate"], order: 5, suppressedBy: genericMeal),
        l3("pizza_burger", "meals", "披薩與漢堡", "Pizza & Burgers", .visual,
           ["a pizza", "a hamburger"], order: 6, suppressedBy: genericMeal),
        l3("fried_chicken", "meals", "炸物", "Fried Food", .visual,
           ["fried chicken", "deep-fried food"], order: 7, suppressedBy: genericMeal),
        // 只認「鍋子在桌上、旁邊擺生肉片和蔬菜」的畫面，避免複雜的大鍋菜都被當成火鍋
        l3("hotpot", "meals", "火鍋", "Hot Pot", .visual,
           ["a hot pot on the table with raw meat slices and vegetables around it"], order: 8, suppressedBy: genericMeal),
        l2("street_food", "food_drink", "小吃", "Street Food", "flame", 2),
        l2("menus", "food_drink", "菜單", "Menus", "menucard", 6),
        l3("menu", "menus", "菜單", "Menu", .visual,
           ["a restaurant menu with dish names and prices", "a drink menu board at a shop"], order: 1),
        l3("night_market", "street_food", "夜市", "Night Market", .visual, ["a night market food stall"], order: 1),
        l2("desserts", "food_drink", "甜點", "Desserts", "birthday.cake", 3),
        l3("cake", "desserts", "蛋糕", "Cake", .visual, ["cake", "a slice of cake"], order: 1),
        l3("ice_cream", "desserts", "冰品", "Ice Cream & Shaved Ice", .visual, ["ice cream", "shaved ice dessert"], order: 2),
        l3("bakery", "desserts", "麵包烘焙", "Bakery", .visual, ["bread and pastries in a bakery"], order: 3),
        l2("drinks", "food_drink", "飲料", "Drinks", "mug", 4),
        l3("coffee", "drinks", "咖啡", "Coffee", .visual, ["a cup of coffee", "latte art on a cup of coffee"], order: 1),
        l3("bubble_tea", "drinks", "手搖飲與茶", "Bubble Tea & Tea", .visual,
           ["bubble tea", "milk tea in a plastic cup with a straw", "a cup of tea"], order: 2),
        l3("cocktail", "drinks", "酒與調酒", "Wine & Cocktails", .visual, ["cocktails and wine glasses at a bar"], order: 3),
        l2("cafe_visit", "food_drink", "咖啡廳", "Cafes", "cup.and.saucer", 5),
        // v18：拿掉「店門」提示詞——快閃店、主題店面的門面設計會被當成咖啡廳
        l3("cafe", "cafe_visit", "咖啡廳", "Cafe", .visual,
           ["a cafe interior", "a coffee shop"], order: 1,
           confusers: ["the decorated storefront of a shop or a pop-up store"]),

        // ───────── 2. 動物與寵物 ─────────
        // 拍到貓狗不一定是自己養的（路上、朋友家、貓咖），所以不叫「寵物」
        l1("animals_pets", "動物", "Animals", "貓、狗與遇到的各種動物", "Cats, dogs and animals you meet", "貓、狗、兔子、鳥、水族", "pawprint.fill", 2),
        l2("pets", "animals_pets", "貓狗與小動物", "Cats, Dogs & Small Animals", "pawprint", 1),
        // 動物一眼就看得出來：沒選「動物」、或畫面裡還有沙發、街景，也照樣標上（distinct）
        l3("cat", "pets", "貓", "Cat", .visual,
           ["a cat", "a kitten", "a cat lying on a sofa or bed", "a close-up of a cat's face", "a cat sitting on the street"],
           order: 1, distinct: true),
        l3("dog", "pets", "狗", "Dog", .visual,
           ["a dog", "a puppy", "a dog lying on the floor at home", "a close-up of a dog's face", "a dog on a leash outdoors"],
           order: 2, distinct: true),
        l3("rabbit", "pets", "兔子", "Rabbit", .visual, ["a rabbit", "a bunny"], order: 3, distinct: true),
        l3("small_pet", "pets", "小動物", "Small Animals", .visual, ["a hamster", "a small rodent"], order: 4, distinct: true),
        l3("reptile", "pets", "爬蟲與兩棲", "Reptiles", .visual, ["a lizard or turtle"], order: 5),
        l2("wildlife", "animals_pets", "其他動物", "Other Animals", "bird", 2),
        l3("bird", "wildlife", "鳥", "Bird", .visual, ["a bird"], order: 1, distinct: true),
        l3("aquarium", "wildlife", "水族", "Aquarium", .visual, ["fish in an aquarium"], order: 2),
        l3("zoo_animal", "wildlife", "動物園", "Zoo Animals", .visual, ["animals at a zoo"], order: 3),
        l3("farm_animal", "wildlife", "牧場動物", "Farm Animals", .visual, ["farm animals like sheep or cows"], order: 4),

        // ───────── 3. 風景與自然 ─────────
        l1("nature_scenery", "風景與自然", "Scenery & Nature", "天空、山海與四季景色", "Sky, sea, mountains and seasons", "日出夕陽、海邊、櫻花、雪景", "leaf.fill", 3),
        l2("sky", "nature_scenery", "天空", "Sky", "sun.horizon", 1),
        // 日出和夕陽在照片上幾乎一樣（天邊的橘紅色與太陽），模型分不出來，所以放在同一個分類
        l3("sunset", "sky", "日出與夕陽", "Sunrise & Sunset", .visual,
           ["sunset", "a sunset sky", "sunrise", "the sun rising over the horizon at dawn"], order: 1),
        l3("starry_sky", "sky", "星空", "Starry Sky", .visual, ["a starry night sky"], order: 2),
        l2("sea_mountain", "nature_scenery", "山海風景", "Sea & Mountains", "mountain.2", 2),
        l3("beach", "sea_mountain", "海邊", "Beach", .visual, ["a beach", "the seaside"], order: 1),
        l3("mountain", "sea_mountain", "山景", "Mountains", .visual, ["a mountain landscape"], order: 2),
        l3("forest", "sea_mountain", "森林", "Forest", .visual, ["a forest", "trees in a park"], order: 3),
        l3("lake_river", "sea_mountain", "湖泊河流", "Lakes & Rivers", .visual, ["a lake or river"], order: 4),
        l2("seasons", "nature_scenery", "花季與四季", "Seasons", "camera.macro", 3),
        // v22：櫻花併入「花」
        l3("flowers", "seasons", "花", "Flowers", .visual, ["flowers", "a bouquet of flowers", "cherry blossoms"], order: 1),
        l3("autumn_leaves", "seasons", "楓葉", "Autumn Leaves", .visual, ["red autumn maple leaves"], order: 3),
        l3("snow", "seasons", "雪景", "Snow", .visual, ["a snowy landscape"], order: 4),

        // ───────── 4. 人物與生活紀錄 ─────────
        l1("people_life", "人物與生活紀錄", "People & Daily Life", "自拍、合照、家人與重要時刻", "Selfies, friends, family and milestones", "自拍、人物照、生日、KTV", "person.2.fill", 4),
        l2("portraits", "people_life", "人像", "Portraits", "person.crop.square", 1),
        // v17：自拍不看畫面判斷，改用 iPhone「照片」App 內建的「自拍」相簿（見 PeopleHints），所以這裡是「只能手動」
        l3("selfie", "portraits", "自拍", "Selfie", .manualOnly, [], order: 1),
        // v17：單人照、雙人合照、多人合照合併成「人物照」——照片向量數不出人數，只判斷照片主角是不是人。
        //      人形立牌、競選看板、小卡上的人不算。
        l3("portrait", "portraits", "人物照", "People", .visual,
           ["a photo of a person posing for the camera", "a group of friends posing for a photo", "people smiling together for a photo"],
           order: 2, suppressedBy: ["merch", "poster", "tv_screen", "photo_sticker"],
           confusers: ["a life-size cardboard cutout of a person or character", "a political campaign poster with a candidate's face",
                       "a printed photo of a person on a card or poster",
                       // v18：公車站廣告牌、路燈上的應援旗、看板上的人也不算
                       "a billboard advertisement with a person's photo at a bus stop",
                       "fan support banners with a celebrity's photo hanging on street lamp posts",
                       "a large advertising banner on a building showing a person's face"]),
        // 照片看不出人和人的關係，所以不會自動標成情侶；情侶合照只能手動加入。
        l3("couple", "portraits", "情侶合照", "Couple", .manualOnly, [], order: 3),
        l2("family", "people_life", "家庭", "Family", "figure.2.and.child.holdinghands", 2),
        // v16：「家庭合照」移除——照片看不出人和人的關係，和「多人合照」抓到的是同一批照片
        l3("baby", "family", "寶寶", "Baby", .visual, ["a baby"], order: 1),
        l2("milestones", "people_life", "重要時刻", "Milestones", "gift", 3),
        // v22：生日派對、KTV 合併成「派對聚會」；移除「婚禮」（v21 已移除「畢業」）
        l3("party", "milestones", "派對聚會", "Parties & Gatherings", .visual,
           ["a birthday party with a cake and candles", "friends celebrating at a party with balloons and decorations",
            "a private karaoke room with a large TV screen, sofas and microphones",
            "people singing with microphones in a karaoke booth"], order: 1,
           // v20：掛彩色吊燈的小吃店、早餐店牆上的價目表很像 KTV 包廂
           confusers: ["a menu board with prices on a restaurant wall", "a small breakfast shop with decorative hanging lamps",
                       "a restaurant counter with staff"]),
        l2("daily", "people_life", "日常", "Daily Life", "house", 4),
        l3("home_daily", "daily", "居家日常", "At Home", .visual, ["a cozy room at home"], order: 1),

        // ───────── 5. 旅遊與地點 ─────────
        l1("travel_places", "旅遊與地點", "Travel & Places", "景點、街景、建築、交通與住宿", "Sights, streets, transport and stays", "地標、城堡、夜景、飯店", "map.fill", 5),
        l2("sights", "travel_places", "景點", "Sights", "building.columns", 1),
        l3("landmark", "sights", "地標", "Landmark", .visual, ["a famous landmark", "a tourist attraction"], order: 1),
        l3("temple", "sights", "寺廟神社", "Temple & Shrine", .visual, ["a temple", "a japanese shrine"], order: 2),
        l3("castle", "sights", "城堡古蹟", "Castles & Heritage", .visual, ["a japanese castle", "a historic castle"], order: 3),
        l3("city_street", "sights", "城市街景", "City Street", .visual, ["a city street", "an urban street scene"], order: 4),
        l3("night_view", "sights", "夜景", "Night View", .visual, ["a city night view"], order: 5),
        l2("venues", "travel_places", "建築", "Architecture", "storefront", 2),
        l3("architecture", "venues", "建築", "Architecture", .visual, ["architecture", "a building facade"], order: 1),
        l2("transport", "travel_places", "交通與住宿", "Transport & Stay", "tram", 3),
        l3("transport_vehicle", "transport", "交通工具", "Vehicles", .visual, ["a train", "a view from an airplane window"], order: 1),
        l3("airport", "transport", "機場", "Airport", .visual, ["an airport terminal"], order: 2),
        l3("hotel_room", "transport", "飯店住宿", "Hotel Stay", .visual, ["a hotel room with a bed"], order: 3),
        // 機票、登機證：畫面像只用來觸發文字辨識，要有「登機證、BOARDING PASS、電子機票…」才標上（requiresText）。
        // 手機錢包裡的登機證截圖也算（文字辨識過才會判斷）
        l3("boarding_pass", "transport", "機票與登機證", "Boarding Passes", .visual,
           ["a paper airline boarding pass with flight number, gate and seat", "a mobile boarding pass with a barcode on a phone screen"],
           order: 4, suppressedBy: ["receipt"],
           confusers: plainPaperOrCard + ["a movie ticket", "a train ticket"],
           requiresText: true),
        l2("travel_memories", "travel_places", "旅行紀錄", "Travel Memories", "suitcase", 4),
        l3("travel_group_photo", "travel_memories", "旅行合照", "Travel Group Photo", .derived, [],
           requires: [["portrait", "selfie", "couple"], ["landmark", "temple", "castle", "city_street", "beach", "mountain"]], order: 1),

        // ───────── 6. 電影與藝文 ─────────
        l1("film_arts", "電影與藝文", "Film & Arts", "電影、海報、展覽、舞台劇與閱讀", "Movies, posters, exhibitions, theater and books", "電影院、電影票根、電影海報、美術館、書", "film.fill", 6),
        l2("film", "film_arts", "電影", "Movies", "film", 1),
        // v21：「電影院」和「票根與門票」合併成「電影」。
        //   ・畫面：電影院的影廳、大廳（看畫面就標）
        //   ・電影票：模型分不出票根和收據、座位表、海報，所以只靠照片文字（放映、影廳、級數、影城…）決定（見 PhotoTextHints.paperRules）；
        //     票根的樣子寫在「收據發票」的描述裡，用來觸發文字辨識（收據發票本身也只靠文字標上）。
        //   ・演唱會、展覽的門票不算電影（文字裡要有電影相關的字）。
        l3("movie", "film", "電影", "Movies", .visual, ["a movie theater auditorium with a big screen", "the lobby of a cinema"], order: 1),
        l3("poster", "film", "電影海報", "Movie Poster", .visual, ["a movie poster", "a large printed poster on a wall"], order: 3),
        l2("arts", "film_arts", "展覽與藝術", "Exhibitions & Art", "building.columns", 2),
        l3("exhibition", "arts", "展覽", "Exhibition", .visual, ["an exhibition hall with displays"], order: 1),
        l3("museum", "arts", "美術館與博物館", "Museums", .visual, ["paintings displayed in an art museum", "a museum gallery with exhibits"], order: 2),
        l2("stage", "film_arts", "舞台表演", "Stage", "theatermasks", 3),
        l3("theater_show", "stage", "舞台劇與音樂劇", "Theater & Musicals", .assisted,
           ["actors performing a play on a theater stage under stage lights", "a musical performance on a large theater stage"],
           order: 1, suppressedBy: ["exhibition", "museum"],
           confusers: schoolHall + ["an exhibition hall with displays and visitors", "artworks displayed in a gallery"]),
        l2("reading", "film_arts", "閱讀", "Reading", "books.vertical", 4),
        // 休閒閱讀；課本、講義、單字書歸「學習與工作 › 課本與講義」
        l3("books", "reading", "書籍與閱讀", "Books & Reading", .visual,
           ["a novel or picture book being read", "books on a bookshelf"], order: 1,
           suppressedBy: ["textbook"], confusers: ["a study workbook with handwritten answers and highlighter marks"]),

        // ───────── 7. 音樂與表演 ─────────
        l1("music_shows", "音樂與表演", "Music & Live Shows", "演唱會、音樂祭、樂器與偶像", "Concerts, festivals, instruments and idols", "演唱會、音樂祭、Live House、應援手燈", "music.mic", 7),
        l2("live_music", "music_shows", "現場演出", "Live Shows", "music.note.house", 1),
        // v25：音樂祭、Live House 併入演唱會（描述一起保留：戶外音樂祭舞台、小型 Live House 舞台）
        l3("concert", "live_music", "演唱會", "Concert", .assisted,
           ["a concert stage with bright lights and big screens", "a crowd holding light sticks at a concert",
            "a crowd in front of a big outdoor music festival stage",
            "a band playing on a small stage in a dark live music club"],
           order: 1, suppressedBy: [], confusers: notAConcert),
        l2("instruments", "music_shows", "樂器", "Instruments", "guitars", 2),
        l3("instrument", "instruments", "樂器演奏", "Instruments", .visual, ["a guitar", "a piano"], order: 1),
        l2("idol_fans", "music_shows", "偶像與粉絲", "Idols & Fans", "star", 3),
        // v23：「專輯」併入「專輯與周邊」（收藏與手作 › 收藏品）
        l3("cheering_goods", "idol_fans", "應援手燈", "Light Sticks", .assisted, ["a light stick", "a cheering banner with a name"], order: 2),
        l3("fansign", "idol_fans", "見面會與簽名會", "Fan Meetings & Signings", .manualOnly, [], order: 3),
        l3("tv_screen", "idol_fans", "螢幕翻拍", "Screen Photos", .assisted, ["a photo of a TV screen showing a performance"], order: 4),

        // ───────── 8. 動漫與遊戲 ─────────
        l1("anime_games", "動漫與遊戲", "Anime & Games", "漫畫、動畫、遊戲、Cosplay 與動漫展", "Manga, anime, games, cosplay and conventions", "漫畫、動畫截圖、遊戲畫面、桌遊", "gamecontroller.fill", 8),
        l2("manga_comics", "anime_games", "漫畫與動畫", "Manga & Anime", "book.closed", 1),
        // 不用「對話框 speech bubbles」描述：聊天 App 也有對話框，容易把聊天截圖誤判成漫畫
        l3("manga", "manga_comics", "漫畫", "Manga", .visual,
           ["a page of black and white japanese manga with panels and screentone", "a vertical webtoon comic strip with drawn panels",
            "manga comic books"],
           order: 1, suppressedBy: ["chat_screenshot"]),
        l3("anime_art", "manga_comics", "動畫截圖與插圖", "Anime Screenshots & Art", .visual, ["an anime screenshot", "an anime illustration"], order: 2),
        l2("games", "anime_games", "遊戲", "Games", "gamecontroller", 2),
        l3("video_game", "games", "遊戲畫面", "Video Games", .visual, ["a video game screenshot", "playing a video game"], order: 1),
        l3("board_game", "games", "桌遊", "Board Games", .visual, ["a board game on a table"], order: 2),
        l3("arcade", "games", "電玩與夾娃娃", "Arcade & Claw Machines", .visual, ["arcade machines", "a claw machine"], order: 3),
        l2("anime_events", "anime_games", "動漫活動", "Anime Events", "person.3", 3),
        l3("cosplay", "anime_events", "Cosplay", "Cosplay", .assisted, ["a person in an anime cosplay costume and colorful wig"], order: 1,
           confusers: ["a person in everyday clothes posing for a photo"]),
        l3("comic_convention", "anime_events", "動漫展", "Anime Conventions", .assisted, ["a crowded anime convention hall"], order: 2),

        // ───────── 9. 收藏與手作 ─────────
        l1("items_collections", "收藏與手作", "Collections & Crafts", "收藏品、玩偶、模型、文具手帳與手作", "Collectibles, plush toys, models, journals and crafts", "小卡、公仔、玩偶、樂高、手帳", "shippingbox.fill", 9),
        l2("collectibles", "items_collections", "收藏品", "Collectibles", "cube", 1),
        // v21：小卡、卡冊、壓克力立牌、徽章、吊飾合併——照片向量分不清這幾種（都是印著角色或偶像的小東西），
        //      分開時常常互相標錯；合在一起，判斷器也有更多照片可以學。
        // v23：專輯也併進來，改名「專輯與周邊」
        l3("merch", "collectibles", "專輯與周邊", "Albums & Merch", .visual,
           ["a single photo card held in a hand", "a few loose photo cards laid out on a table",
            "a photo card in a hard plastic toploader", "a binder page with many photo cards in clear plastic pockets",
            "a clear acrylic standee of a character standing on a base", "round button badges with anime characters",
            "small acrylic keychains and phone charms",
            "a music album CD case with a photo booklet", "an unboxed k-pop album with a photobook and a CD"], order: 1,
           confusers: plainPaperOrCard + ["a card with a large qr code", "a paper number tag", "a package wrapped in bubble wrap",
                                          "a life-size cardboard cutout of a character",
                                          "a decorated notebook page with stickers, washi tape and handwriting",
                                          "a large concert billboard outside a stadium", "a big group photo of students",
                                          "a screenshot of a phone app"]),
        l3("figure", "collectibles", "公仔", "Figure", .visual, ["an anime figure", "a collectible figurine"], order: 5),
        l3("stuffed_toy", "collectibles", "玩偶與娃娃", "Plush Toys & Dolls", .visual,
           ["a stuffed animal toy", "a teddy bear", "a small plush doll"], order: 6),
        l3("model_kit", "collectibles", "模型", "Model Kit", .visual, ["a plastic model kit", "an assembled robot model"], order: 8),
        l3("lego", "collectibles", "積木", "LEGO & Bricks", .visual, ["a lego brick build"], order: 9),
        // v19：「有可愛裝飾的貼紙」會抓到卡通貼紙、立牌、杯套；改成拍貼機拍出來的照片
        l3("photo_sticker", "collectibles", "拍貼與明信片", "Photo Stickers & Postcards", .visual,
           ["a photo booth print of friends posing with cute decorations", "a postcard with a printed picture"], order: 11,
           suppressedBy: ["merch"],
           confusers: ["a sheet of cartoon character stickers", "cardboard character standees", "framed photos hanging on a wall",
                       "a paper cup sleeve with cartoon characters"]),
        l2("stationery_craft", "items_collections", "手作與文具", "Crafts & Stationery", "pencil.and.scribble", 2),
        // v19：「stationery」太廣，換成具體的文具
        l3("stationery", "stationery_craft", "文具", "Stationery", .visual,
           ["pens, highlighters and erasers", "a pencil case with pens", "notebooks and pens on a desk"], order: 1,
           confusers: ["a table covered with letters, flowers and photos left by fans", "packaged snacks with cartoon characters",
                       "a face mask in a plastic package", "products on a store shelf"]),
        l3("journal", "stationery_craft", "手帳", "Journal", .visual, ["a decorated journal planner with stickers"], order: 2),
        l3("handcraft", "stationery_craft", "手作", "Handcraft", .visual, ["handmade crafts"], order: 3),
        l3("painting", "stationery_craft", "繪畫", "Painting", .visual, ["a painting on canvas", "a hand-drawn illustration"], order: 4),
        // v22：3C 與相機獨立成大分類（見 tech_gear）

        // ───────── 15. 3C 與相機（v22 從「收藏與手作」獨立出來）─────────
        l1("tech_gear", "3C 與相機", "Tech & Cameras", "手機、電腦、耳機與相機器材", "Phones, computers, headphones and cameras", "筆電、手機、耳機、相機、鏡頭", "laptopcomputer", 15),
        l2("gadgets_l2", "tech_gear", "3C 與相機", "Gadgets & Cameras", "laptopcomputer", 1),
        l3("gadgets", "gadgets_l2", "3C 產品", "Gadgets", .visual, ["a laptop", "a smartphone and electronic gadgets"], order: 1),
        l3("camera_gear", "gadgets_l2", "相機器材", "Camera Gear", .visual, ["a camera and lenses"], order: 2),

        // ───────── 10. 休閒與節慶 ─────────
        l1("entertainment_events", "休閒與節慶", "Leisure & Festivals", "主題樂園、煙火與節慶", "Theme parks, fireworks and festivals", "遊樂園、煙火、燈會、聖誕節", "ticket.fill", 10),
        l2("outings", "entertainment_events", "休閒娛樂", "Outings", "figure.wave", 1),
        // 同一天、同一個樂園的照片會整理成「場次」（LiveEventProfile.themePark）
        l3("theme_park", "outings", "主題樂園", "Theme Park", .visual,
           ["an amusement park ride", "a roller coaster at an amusement park", "a fairytale castle and crowds at a theme park",
            "a parade with costumed characters at a theme park"], order: 1),
        l2("festivals", "entertainment_events", "節慶", "Festivals", "sparkles", 2),
        l3("fireworks", "festivals", "煙火", "Fireworks", .visual, ["fireworks in the night sky"], order: 1),
        l3("lantern_festival", "festivals", "燈會與祭典", "Lantern Festivals", .visual, ["a traditional festival with lanterns"], order: 2),
        l3("christmas", "festivals", "聖誕節", "Christmas", .visual, ["christmas decorations"], order: 3),

        // ───────── 11. 運動與戶外 ─────────
        l1("sports_outdoor", "運動與戶外", "Sports & Outdoors", "健身房、球類、觀賽、登山與露營", "Gym, ball games, matches, hiking and camping", "重訓、跑步、球場觀賽、登山、露營", "figure.run", 11),
        l2("gym", "sports_outdoor", "健身房", "Gym", "dumbbell", 1),
        l3("workout", "gym", "健身", "Workout", .visual, ["a person exercising with fitness equipment at a gym"], order: 1,
           confusers: schoolHall),
        l3("weight_training", "gym", "重訓", "Weight Training", .visual,
           ["lifting dumbbells at a gym", "a barbell on a squat rack"], order: 2),
        l3("cardio_machine", "gym", "有氧器材", "Cardio Machines", .visual,
           ["treadmills and exercise bikes in a gym", "a rowing machine at a gym"], order: 3),
        // 體組成屬於身體資料：月報預設不放（見 InterestTracker）。
        // 模型分不出 InBody 報告和菜單、表格，所以只靠照片文字（InBody、體脂肪…）成為待確認，或手動加入。
        l3("body_composition", "gym", "體組成紀錄", "Body Composition", .manualOnly, [], order: 4),
        l2("sports", "sports_outdoor", "運動", "Sports", "sportscourt", 2),
        // 只認「正在跑」：跑步服、號碼布、馬拉松；單腳站著擺姿勢拍照不算
        l3("running", "sports", "跑步", "Running", .visual,
           ["a runner jogging in running clothes and sneakers", "people running a marathon race wearing bib numbers"],
           order: 2, confusers: posingPerson),
        // 只認「正在打球」；學校體育館裡的表演、集會不算
        l3("ball_sports", "sports", "球類運動", "Ball Sports", .visual,
           ["basketball players shooting at a hoop during a game", "a person hitting a shuttlecock with a badminton racket",
            "volleyball players jumping at the net", "a table tennis player hitting a ball over the net"],
           order: 3, confusers: schoolHall),
        l3("swimming", "sports", "游泳", "Swimming", .visual, ["people swimming laps in a swimming pool"], order: 4),
        // v19：「在路上騎腳踏車」會抓到沒有腳踏車的道路、自行車道風景
        l3("cycling", "sports", "騎單車", "Cycling", .visual, ["a cyclist riding a bicycle", "a person riding a bike, seen up close"], order: 5,
           confusers: ["bicycles parked on a street", "an empty road", "a footpath through a park with no people",
                       "a person riding a motor scooter", "a city street with cars"]),
        l3("sports_game", "sports", "球場觀賽", "Watching Games", .visual,
           ["spectators watching a baseball game from the stands", "a view of a sports field from the stadium seats"], order: 7),
        l3("sports_gear", "sports", "運動用品", "Sports Gear", .visual,
           ["sports equipment like rackets, balls and dumbbells", "a yoga mat and sports gear laid out"], order: 8),
        l2("outdoor", "sports_outdoor", "戶外活動", "Outdoors", "tent", 3),
        l3("hiking", "outdoor", "登山健行", "Hiking", .visual, ["a hiker with a backpack walking on a mountain trail"], order: 1),
        l3("camping", "outdoor", "露營", "Camping", .visual, ["a camping tent outdoors"], order: 2),
        l3("skiing", "outdoor", "滑雪", "Skiing", .visual, ["skiing on a snowy slope"], order: 3),
        l3("diving", "outdoor", "潛水與浮潛", "Diving", .visual, ["snorkeling underwater"], order: 4),

        // ───────── 12. 穿搭與美妝 ─────────
        l1("fashion_beauty", "穿搭與美妝", "Fashion & Beauty", "每日穿搭、配件、美妝與美甲", "Outfits, accessories, makeup and nails", "每日穿搭、鞋子、包包、美甲", "tshirt.fill", 12),
        l2("outfits", "fashion_beauty", "穿搭", "Outfits", "tshirt", 1),
        l3("outfit", "outfits", "每日穿搭", "Outfit", .visual, ["a full-body mirror photo of a person's outfit", "a person showing a fashion outfit"], order: 1),
        l3("shoes", "outfits", "鞋子", "Shoes", .visual, ["a pair of sneakers", "shoes"], order: 2),
        l3("bags", "outfits", "包包", "Bags", .visual, ["a handbag"], order: 3),
        l3("accessories", "outfits", "飾品", "Accessories", .visual, ["jewelry and accessories"], order: 4),
        l2("beauty", "fashion_beauty", "美妝保養", "Beauty", "sparkles", 2),
        l3("cosmetics", "beauty", "美妝", "Cosmetics", .visual, ["makeup and cosmetics"], order: 1),
        l3("nails", "beauty", "美甲", "Nail Art", .visual, ["manicured nails with nail art"], order: 2),
        l3("hairstyle", "beauty", "髮型", "Hairstyle", .visual, ["a hairstyle photo at a salon"], order: 3),

        // ───────── 13. 學習與工作 ─────────
        l1("study_work", "學習與工作", "Study & Work", "筆記、文件、截圖與簡報", "Notes, documents, screenshots and slides", "白板筆記、文件、手機截圖", "book.fill", 13),
        l2("documents", "study_work", "文件與筆記", "Documents & Notes", "doc.text", 1),
        l3("document", "documents", "文件", "Document", .visual, ["a document", "printed text on paper"], order: 1),
        l3("handwritten_notes", "documents", "手寫筆記", "Handwritten Notes", .visual, ["handwritten notes", "notes on a whiteboard"], order: 2),
        l3("slides", "documents", "簡報", "Slides", .visual, ["presentation slides on a screen"], order: 3),
        l3("textbook", "documents", "課本與講義", "Textbooks & Handouts", .visual,
           ["an open school textbook with exercises and vocabulary lists", "printed class handouts with questions"], order: 4),
        l3("id_card", "documents", "證件與卡片", "IDs & Cards", .visual,
           ["a student ID card or identity card with a photo", "a membership card or transit card held in a hand"], order: 5),
        l2("screens", "study_work", "螢幕截圖", "Screenshots", "iphone", 2),
        // v24：「手機截圖」移除，改成「照片」分頁的「截圖」切換（用 iPhone 的截圖標記，和系統「截圖」相簿相同）
        l3("chat_screenshot", "screens", "聊天截圖", "Chat Screenshot", .visual,
           ["a screenshot of a chat conversation in a messaging app", "a messaging app screenshot with chat bubbles and stickers"], order: 2),
        l2("workspace", "study_work", "工作環境", "Workspace", "desktopcomputer", 3),
        l3("desk_setup", "workspace", "桌面環境", "Desk Setup", .visual, ["a desk setup with a computer"], order: 1),

        // ───────── 14. 購物與生活管理 ─────────
        l1("shopping_life", "購物與生活管理", "Shopping & Life Admin", "收據、商品、居家與植栽", "Receipts, products, home and plants", "收據、商品照、家具、植栽", "cart.fill", 14),
        l2("receipts", "shopping_life", "單據", "Receipts", "receipt", 1),
        // 有 QR code 的東西（海報、桌貼、手機畫面、點餐單）畫面上都很像電子發票：
        // 畫面像只會去辨識照片文字，要有「電子發票、統一編號、收據…」才標成收據發票（requiresText）
        // v21：多兩條票根的描述——票根和收據一樣是印著字的小紙條，看起來像就去辨識文字，由文字決定是電影還是收據
        l3("receipt", "receipts", "收據發票", "Receipt", .visual,
           ["a long thermal paper shopping receipt listing items and prices", "a small printed electronic invoice slip held in hand",
            "a movie ticket stub", "a printed paper ticket held in a hand"],
           order: 1, suppressedBy: ["menu", "id_card"],
           confusers: plainPaperOrCard + ["a QR code displayed on a phone screen", "a QR code sticker or sign",
                                          "a poster with a QR code"],
           requiresText: true),
        l2("products", "shopping_life", "商品", "Products", "bag.fill", 2),
        l3("product_photo", "products", "商品照", "Product Photo", .visual, ["a product photo", "items on a store shelf"], order: 1),
        l3("clothing", "products", "服飾", "Clothing", .visual, ["clothes on hangers in a store"], order: 2),
        l3("groceries", "products", "生鮮雜貨", "Groceries", .visual, ["groceries"], order: 3),
        l2("home", "shopping_life", "居家", "Home", "sofa", 3),
        l3("furniture", "home", "家具", "Furniture", .visual, ["furniture", "a room interior"], order: 1),
        l3("houseplants", "home", "植栽", "Houseplants", .visual, ["potted plants indoors"], order: 2),
    ]

    static let interests: [InterestProfile] = [
        InterestProfile(id: "food_cafe", nameZh: "美食探店", nameEn: "Foodie",
                        summaryZh: "餐廳、麵食、壽司、燒烤與夜市", summaryEn: "Restaurants, noodles, sushi, grills and night markets",
                        icon: "fork.knife",
                        recommendedTopLevelIds: ["food_drink", "travel_places", "people_life"],
                        relatedNodeIds: ["restaurant_meal", "noodle_dish", "bento", "sushi", "bbq", "pizza_burger", "fried_chicken",
                                         "hotpot", "night_market"],
                        sortOrder: 1),
        InterestProfile(id: "cafe_hopping", nameZh: "咖啡與甜點", nameEn: "Cafes & Desserts",
                        summaryZh: "咖啡廳、咖啡、蛋糕與手搖飲", summaryEn: "Cafes, coffee, cakes and bubble tea",
                        icon: "cup.and.saucer.fill",
                        recommendedTopLevelIds: ["food_drink", "travel_places", "people_life"],
                        relatedNodeIds: ["cafe", "coffee", "cake", "bakery", "ice_cream", "bubble_tea"],
                        sortOrder: 2),
        InterestProfile(id: "travel_photo", nameZh: "旅遊與攝影", nameEn: "Travel & Photography",
                        summaryZh: "景點、街景、夜景與四季風景", summaryEn: "Sights, streets, night views and seasons",
                        icon: "airplane",
                        recommendedTopLevelIds: ["travel_places", "nature_scenery", "people_life"],
                        relatedNodeIds: ["landmark", "castle", "city_street", "night_view", "flowers", "autumn_leaves",
                                         "travel_group_photo", "hotel_room", "boarding_pass", "camera_gear"],
                        sortOrder: 3),
        InterestProfile(id: "pets_animals", nameZh: "貓狗與動物", nameEn: "Cats, Dogs & Animals",
                        summaryZh: "貓、狗、兔子與各種動物", summaryEn: "Cats, dogs, rabbits and more",
                        icon: "pawprint.fill",
                        recommendedTopLevelIds: ["animals_pets", "people_life"],
                        relatedNodeIds: ["cat", "dog", "rabbit", "small_pet", "reptile", "aquarium"],
                        sortOrder: 4),
        InterestProfile(id: "sports_outdoor", nameZh: "運動與健身", nameEn: "Sports & Fitness",
                        summaryZh: "健身房、跑步、球類與球場觀賽", summaryEn: "Gym, running, ball games and matches",
                        icon: "figure.run",
                        recommendedTopLevelIds: ["sports_outdoor", "people_life"],
                        relatedNodeIds: ["workout", "weight_training", "cardio_machine", "running", "ball_sports", "swimming",
                                         "cycling", "sports_game", "sports_gear"],
                        sortOrder: 5),
        InterestProfile(id: "outdoor_hiking", nameZh: "戶外與登山", nameEn: "Outdoors & Hiking",
                        summaryZh: "登山、露營、滑雪、潛水與山海風景", summaryEn: "Hiking, camping, skiing, diving and landscapes",
                        icon: "mountain.2.fill",
                        recommendedTopLevelIds: ["sports_outdoor", "nature_scenery", "travel_places"],
                        relatedNodeIds: ["hiking", "camping", "skiing", "diving", "mountain", "forest", "lake_river", "starry_sky"],
                        sortOrder: 6),
        InterestProfile(id: "film_arts", nameZh: "電影與藝文", nameEn: "Film & Arts",
                        summaryZh: "電影、海報、展覽、舞台劇與閱讀", summaryEn: "Movies, posters, exhibitions, theater and books",
                        icon: "film.fill",
                        recommendedTopLevelIds: ["film_arts", "entertainment_events", "people_life"],
                        relatedNodeIds: ["movie", "poster", "exhibition", "museum", "theater_show", "books"],
                        sortOrder: 7),
        InterestProfile(id: "music_live", nameZh: "音樂與演出", nameEn: "Music & Live Shows",
                        summaryZh: "演唱會、音樂祭、樂器、專輯與偶像", summaryEn: "Concerts, festivals, instruments, albums and idols",
                        icon: "music.mic",
                        recommendedTopLevelIds: ["music_shows", "film_arts", "people_life"],
                        relatedNodeIds: ["concert", "instrument", "cheering_goods",
                                         "fansign", "tv_screen", "merch"],
                        sortOrder: 8),
        InterestProfile(id: "anime_games", nameZh: "動漫與遊戲", nameEn: "Anime & Games",
                        summaryZh: "漫畫、動畫、遊戲、Cosplay 與動漫展", summaryEn: "Manga, anime, games, cosplay and conventions",
                        icon: "gamecontroller.fill",
                        recommendedTopLevelIds: ["anime_games", "items_collections", "entertainment_events"],
                        relatedNodeIds: ["manga", "anime_art", "video_game", "board_game", "arcade", "cosplay", "comic_convention",
                                         "figure", "merch"],
                        sortOrder: 9),
        InterestProfile(id: "crafts_collecting", nameZh: "收藏與手作", nameEn: "Collections & Crafts",
                        summaryZh: "小卡、公仔、玩偶、模型、手帳與手作", summaryEn: "Cards, figures, plush toys, models, journals and crafts",
                        icon: "paintbrush.pointed.fill",
                        recommendedTopLevelIds: ["items_collections", "anime_games"],
                        relatedNodeIds: ["merch", "figure", "stuffed_toy",
                                         "model_kit", "lego", "journal", "handcraft", "painting", "stationery"],
                        sortOrder: 10),
        InterestProfile(id: "fashion_lifestyle", nameZh: "穿搭與美妝", nameEn: "Fashion & Beauty",
                        summaryZh: "每日穿搭、鞋包配件、美妝與美甲", summaryEn: "Outfits, accessories, makeup and nails",
                        icon: "tshirt.fill",
                        recommendedTopLevelIds: ["fashion_beauty", "people_life", "shopping_life"],
                        relatedNodeIds: ["outfit", "shoes", "bags", "accessories", "cosmetics", "nails", "hairstyle", "clothing"],
                        sortOrder: 11),
        InterestProfile(id: "family_life", nameZh: "家庭與生活", nameEn: "Family & Life",
                        summaryZh: "家人、寶寶、生日與派對聚會", summaryEn: "Family, babies, birthdays and gatherings",
                        icon: "house.fill",
                        recommendedTopLevelIds: ["people_life", "food_drink", "shopping_life"],
                        relatedNodeIds: ["portrait", "baby", "party", "home_daily"],
                        sortOrder: 12),
        InterestProfile(id: "study_work", nameZh: "學習與工作", nameEn: "Study & Work",
                        summaryZh: "筆記、文件、截圖與簡報", summaryEn: "Notes, documents, screenshots and slides",
                        icon: "book.fill",
                        recommendedTopLevelIds: ["study_work", "shopping_life"],
                        relatedNodeIds: ["document", "handwritten_notes", "textbook", "chat_screenshot", "slides", "desk_setup"],
                        sortOrder: 13),
        InterestProfile(id: "general", nameZh: "一般", nameEn: "General",
                        summaryZh: "不特別設定，顯示完整分類", summaryEn: "No preference, show everything",
                        icon: "sparkles",
                        recommendedTopLevelIds: [],
                        relatedNodeIds: [],
                        sortOrder: 14),
    ]
}

import XCTest
import SQLite
@testable import PersonalizationCore

/// 驗收 1–5、9：興趣定位、大分類、子分類自動啟用、修改偏好不刪向量。
final class PreferenceAndRecommendationTests: XCTestCase {

    func testCatalogIsValid() {
        let catalog = TaxonomyCatalog.builtIn
        XCTAssertEqual(catalog.validationErrors(), [])
        XCTAssertGreaterThanOrEqual(catalog.interests.count, 10, "第一階段至少提供 10 個興趣定位")
        XCTAssertGreaterThanOrEqual(catalog.topLevelNodes.count, 10, "第二階段至少提供 10 個大分類")
        for id in ["food_drink", "film_arts", "music_shows", "anime_games", "items_collections", "sports_outdoor", "fashion_beauty"] {
            XCTAssertEqual(catalog.node(id)?.level, 1, "應涵蓋興趣族群：\(id)")
        }
        for top in catalog.topLevelNodes {
            XCTAssertFalse(catalog.children(of: top.id).isEmpty, "\(top.id) 應有中分類")
            XCTAssertFalse(top.examplesZh.isEmpty, "\(top.id) 應有例子")
        }
    }

    // 1. 可以複選興趣定位
    func testUserCanSelectMultipleInterests() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "a@example.com", displayName: "A")
        try store.saveInterests(userId: userId, interestIds: ["music_live", "crafts_collecting", "food_cafe"])
        XCTAssertEqual(try store.interestIds(userId: userId), ["music_live", "crafts_collecting", "food_cafe"])

        // 取消選取
        try store.saveInterests(userId: userId, interestIds: ["crafts_collecting"])
        XCTAssertEqual(try store.interestIds(userId: userId), ["crafts_collecting"])

        // 已移除的舊興趣不能再存
        XCTAssertThrowsError(try store.saveInterests(userId: userId, interestIds: ["idol_fandom"]))
    }

    func testUnknownInterestIsRejected() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "a@example.com", displayName: nil)
        XCTAssertThrowsError(try store.saveInterests(userId: userId, interestIds: ["gps_location"]))
    }

    // 2. 可以跳過興趣定位
    func testUserCanSkipInterestsAndStillSeeFullCategoryList() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "skip@example.com", displayName: nil)
        XCTAssertEqual(try store.onboardingStatus(userId: userId), .pending)

        try store.setOnboardingStatus(userId: userId, .skipped)
        XCTAssertEqual(try store.onboardingStatus(userId: userId), .skipped)
        XCTAssertEqual(try store.interestIds(userId: userId), [])

        let ranked = InterestRecommender.rankTopLevel(selectedInterestIds: [])
        XCTAssertEqual(ranked.count, TaxonomyCatalog.builtIn.topLevelNodes.count, "未選興趣時仍顯示完整大分類清單")
        XCTAssertTrue(ranked.allSatisfy { !$0.isRecommended })
        XCTAssertEqual(ranked.map(\.node.id), TaxonomyCatalog.builtIn.topLevelNodes.map(\.id), "未選興趣時維持預設順序")
    }

    // 3. 興趣定位影響大分類推薦與排序
    func testInterestsAffectTopLevelRanking() {
        let music = InterestRecommender.rankTopLevel(selectedInterestIds: ["music_live"])
        let recommended = music.filter(\.isRecommended).map(\.node.id)
        XCTAssertEqual(Set(recommended), ["music_shows", "film_arts", "people_life"])
        XCTAssertEqual(music.count, TaxonomyCatalog.builtIn.topLevelNodes.count, "推薦只影響排序，不隱藏其他大分類")
        XCTAssertEqual(music.first?.node.id, "music_shows", "第一順位推薦排最前")

        let crafts = InterestRecommender.rankTopLevel(selectedInterestIds: ["crafts_collecting"])
        XCTAssertEqual(crafts.first?.node.id, "items_collections")

        // 多個興趣同時推薦的分類分數較高
        let both = InterestRecommender.rankTopLevel(selectedInterestIds: ["music_live", "film_arts"])
        XCTAssertEqual(both.first?.node.id, "film_arts", "兩個興趣都推薦的「電影與藝文」排最前")
        XCTAssertEqual(both.first?.recommendedBy.sorted(), ["film_arts", "music_live"])
    }

    func testGeneralInterestDoesNotHideAnything() {
        let ranked = InterestRecommender.rankTopLevel(selectedInterestIds: ["general"])
        XCTAssertEqual(ranked.count, TaxonomyCatalog.builtIn.topLevelNodes.count)
        XCTAssertTrue(ranked.allSatisfy { !$0.isRecommended })
    }

    // 4. 可以選擇多個大分類；5. 對應子分類自動啟用
    func testSelectingTopLevelEnablesDefaultSubcategories() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "c@example.com", displayName: nil)

        try store.saveTopLevelSelection(userId: userId, topLevelIds: ["food_drink", "items_collections"])
        XCTAssertEqual(try store.selectedTopLevelIds(userId: userId), ["food_drink", "items_collections"])

        let enabled = try store.enabledNodeIds(userId: userId)
        for id in ["meals", "noodle_dish", "restaurant_meal", "sushi", "cafe", "collectibles", "stuffed_toy", "merch"] {
            XCTAssertTrue(enabled.contains(id), "\(id) 應自動啟用")
        }
        XCTAssertFalse(enabled.contains("cat"), "未選取的大分類子分類不應被啟用")

        // 取消大分類 → 自動啟用的子分類一併取消
        try store.saveTopLevelSelection(userId: userId, topLevelIds: ["items_collections"])
        let after = try store.enabledNodeIds(userId: userId)
        XCTAssertFalse(after.contains("noodle_dish"))
        XCTAssertTrue(after.contains("stuffed_toy"))
    }

    func testManualSubcategoryOverrideSurvivesTopLevelChanges() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "d@example.com", displayName: nil)
        try store.saveTopLevelSelection(userId: userId, topLevelIds: ["food_drink"])
        try store.setNodeEnabled(userId: userId, nodeId: "noodle_dish", enabled: false)

        try store.saveTopLevelSelection(userId: userId, topLevelIds: ["food_drink", "travel_places"])
        XCTAssertFalse(try store.enabledNodeIds(userId: userId).contains("noodle_dish"), "手動關閉的子分類不應被重新自動啟用")
    }

    func testNonTopLevelSelectionIsRejected() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "e@example.com", displayName: nil)
        XCTAssertThrowsError(try store.saveTopLevelSelection(userId: userId, topLevelIds: ["noodle_dish"]))
    }

    func testSavedPreferencesPersistAcrossStoreInstances() throws {
        let db = try TestDatabase.makeLegacyConnection()
        let first = PersonalizationStore(db: db)
        try first.migrate()
        try first.seedCatalogIfNeeded()
        let userId = try first.resolveUser(email: "persist@example.com", displayName: nil)
        try first.savePersonalization(userId: userId, interestIds: ["travel_photo"], topLevelIds: ["nature_scenery"], status: .completed)

        // 模擬重新啟動 App：新的 Store、同一個資料庫
        let second = PersonalizationStore(db: db)
        try second.migrate()
        XCTAssertFalse(try second.seedCatalogIfNeeded(), "目錄版本相同時不重複寫入")
        XCTAssertEqual(try second.resolveUser(email: "PERSIST@example.com ", displayName: nil), userId, "同一 email 對應同一本機帳號")
        XCTAssertEqual(try second.interestIds(userId: userId), ["travel_photo"])
        XCTAssertEqual(try second.selectedTopLevelIds(userId: userId), ["nature_scenery"])
        XCTAssertEqual(try second.onboardingStatus(userId: userId), .completed)
    }

    func testEachPersonaHasDetailedCategories() {
        let catalog = TaxonomyCatalog.builtIn
        for interest in catalog.interests where interest.id != "general" {
            XCTAssertGreaterThanOrEqual(interest.relatedNodeIds.count, 4, "\(interest.id) 應有足夠的族群細分類")
        }
        XCTAssertNil(catalog.node("album_cd"), "v23 專輯併入專輯與周邊")
        XCTAssertEqual(catalog.nodeRedirects["album_cd"], "merch")
        XCTAssertEqual(catalog.node("merch")?.nameZh, "專輯與周邊")
        XCTAssertEqual(catalog.topLevelId(of: "merch"), "items_collections")
        XCTAssertEqual(catalog.topLevelId(of: "coffee"), "food_drink")
        XCTAssertEqual(catalog.topLevelId(of: "cafe"), "food_drink")
        XCTAssertEqual(catalog.topLevelId(of: "movie"), "film_arts")
        XCTAssertEqual(catalog.topLevelId(of: "manga"), "anime_games")
        XCTAssertEqual(catalog.topLevelId(of: "stuffed_toy"), "items_collections")
        XCTAssertNil(catalog.node("yoga_dance"), "v12 刪除瑜伽與舞蹈")
        XCTAssertEqual(catalog.nodeRedirects["yoga_dance"], "sports")
        XCTAssertEqual(catalog.node("theater_show")?.recognition, .assisted, "舞台劇只會成為待確認")
    }

    /// 收藏品只出現在「收藏與手作」一個大分類，不會同一張照片同時算進音樂與動漫兩邊。
    func testCollectiblesLiveInOneTopLevel() {
        let catalog = TaxonomyCatalog.builtIn
        for id in ["merch", "figure", "stuffed_toy"] {
            XCTAssertEqual(catalog.topLevelId(of: id), "items_collections", id)
        }
        XCTAssertEqual(catalog.topLevelId(of: "poster"), "film_arts")
        let musicNames = Set(catalog.descendants(of: "music_shows").map(\.nameZh))
        let animeNames = Set(catalog.descendants(of: "anime_games").map(\.nameZh))
        XCTAssertTrue(musicNames.isDisjoint(with: animeNames))
    }

    /// v6：興趣平均分配，不偏重追星與動漫，也不用流行用語當分類名稱。
    func testV6CatalogIsBalancedAndPlain() {
        let catalog = TaxonomyCatalog.builtIn
        for removed in ["idol_fandom", "fan_goods", "doll_photography", "cafe_dessert", "ramen", "pasta", "theme_cafe",
                        "oshi_photo_with_goods", "ita_bag", "doll_meetup", "birthday_support", "idol_billboard", "pilgrimage"] {
            XCTAssertNil(catalog.node(removed), removed)
            XCTAssertNotNil(catalog.nodeRedirects[removed], "\(removed) 的標籤要有地方搬")
        }
        for slang in ["推活", "痛包", "娃聚", "娃活", "跑咖", "OOTD", "聖地巡禮"] {
            XCTAssertTrue(catalog.nodes.allSatisfy { !$0.nameZh.contains(slang) && !$0.examplesZh.contains(slang) && !$0.summaryZh.contains(slang) }, slang)
        }
        XCTAssertEqual(catalog.interests.count, 14)
        XCTAssertNil(catalog.interest("idol_fandom"))
        XCTAssertEqual(catalog.interestRedirects["idol_fandom"], "music_live")
        XCTAssertEqual(catalog.interestRedirects["doll_photo"], "crafts_collecting")
        // 具體料理都要比一般「餐點」明顯更像才自動標記
        for id in ["noodle_dish", "bento", "sushi", "bbq", "pizza_burger", "fried_chicken", "hotpot"] {
            XCTAssertEqual(catalog.node(id)?.suppressedBy, ["restaurant_meal"], id)
        }
    }

    func testRemovedDollOptionsAndCoupleIsManualOnly() {
        let catalog = TaxonomyCatalog.builtIn
        XCTAssertNil(catalog.node("bjd_doll"))
        XCTAssertNil(catalog.node("character_doll"))
        XCTAssertTrue(catalog.nodes.allSatisfy { !$0.nameZh.contains("棉花娃") && !$0.nameZh.contains("BJD") && !$0.nameZh.contains("人形") })
        XCTAssertEqual(catalog.node("couple")?.recognition, .manualOnly, "兩人合照不會自動被當成情侶")
        XCTAssertNil(catalog.node("duo_photo"), "v17：雙人、多人合照併入人物照")
        XCTAssertEqual(catalog.node("portrait")?.recognition, .visual)
        XCTAssertEqual(catalog.node("selfie")?.recognition, .manualOnly, "自拍改用系統自拍相簿")
        XCTAssertEqual(catalog.nodeRedirects["group_photo"], "portrait")
    }

    func testBillboardsAndStorefrontsAreNotPeopleOrCafes() {
        let catalog = TaxonomyCatalog.builtIn
        let portraitConfusers = catalog.node("portrait")?.confusers ?? []
        XCTAssertTrue(portraitConfusers.contains { $0.contains("billboard") }, "公車站廣告牌不算人物照")
        XCTAssertTrue(portraitConfusers.contains { $0.contains("lamp post") }, "路燈上的應援旗不算人物照")
        let cafe = catalog.node("cafe")
        XCTAssertFalse(cafe?.prompts.contains { $0.contains("storefront") } ?? true, "咖啡廳不再比對店門")
        XCTAssertFalse(cafe?.confusers.isEmpty ?? true)
    }

    /// v22：生日派對、KTV 合併成「派對聚會」；早餐店牆上的價目表不算 KTV 包廂
    func testRestaurantMenuWallIsNotKaraoke() {
        let catalog = TaxonomyCatalog.builtIn
        let party = catalog.node("party")
        XCTAssertTrue(party?.confusers.contains { $0.contains("menu board") } ?? false)
        XCTAssertNil(catalog.node("karaoke"))
        XCTAssertEqual(catalog.nodeRedirects["karaoke"], "party")
        XCTAssertEqual(catalog.nodeRedirects["birthday_party"], "party")
        XCTAssertNil(catalog.node("wedding"), "v22 移除婚禮")
        XCTAssertEqual(catalog.nodeRedirects["cherry_blossom"], "flowers")
        XCTAssertEqual(catalog.topLevelId(of: "camera_gear"), "tech_gear", "3C 與相機是自己的大分類")
        XCTAssertEqual(catalog.topLevelAdditions["tech_gear"], ["items_collections"])
    }

    /// 舊版 → v6：被合併節點的手動標籤搬到新節點；選過「追星」的使用者自動選取「音樂與表演」；舊興趣改成新興趣。
    func testCatalogUpgradeMovesTagsAndAddsNewTopLevel() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "upgrade@example.com", displayName: nil)
        try store.db.run("DELETE FROM UserCategoryPreferences WHERE user_id = ?", userId)
        try store.db.run("""
        INSERT INTO UserCategoryPreferences (user_id, node_id, is_enabled, source) VALUES (?, 'idol_fandom', 1, 'selection')
        """, userId)
        try store.db.run("""
        INSERT INTO PhotoTags (user_id, asset_id, node_id, score, source, status, tagger_version)
        VALUES (?, 'p1', 'bjd_doll', NULL, 'manual', 'accepted', 'manual'),
               (?, 'p1', 'plush_doll', 0.3, 'auto', 'accepted', 'old'),
               (?, 'p2', 'character_doll', NULL, 'manual', 'rejected', 'manual')
        """, userId, userId, userId)
        try store.db.run("INSERT INTO UserInterests (user_id, interest_id) VALUES (?, 'idol_fandom'), (?, 'doll_photo'), (?, 'food_cafe')",
                         userId, userId, userId)
        try store.db.run("UPDATE PersonalizationMeta SET meta_value = '3' WHERE meta_key = 'catalog_version'")

        XCTAssertTrue(try store.seedCatalogIfNeeded())

        let rows = try store.db.prepare("SELECT asset_id, node_id, source, status FROM PhotoTags WHERE user_id = ? ORDER BY asset_id", userId)
            .map { "\($0[0]!)|\($0[1]!)|\($0[2]!)|\($0[3]!)" }
        XCTAssertEqual(rows, ["p1|stuffed_toy|manual|accepted", "p2|stuffed_toy|manual|rejected"], "手動標籤與拒絕紀錄都保留")
        XCTAssertTrue(try store.selectedTopLevelIds(userId: userId).contains("music_shows"))
        XCTAssertFalse(try store.selectedTopLevelIds(userId: userId).contains("idol_fandom"))
        XCTAssertTrue(try store.enabledNodeIds(userId: userId).contains("concert"), "新大分類的預設子分類一起啟用")
        XCTAssertEqual(try store.interestIds(userId: userId), ["music_live", "crafts_collecting", "food_cafe"])
    }

    // 9. 修改偏好不會刪除既有向量
    func testChangingPreferencesNeverDeletesVectors() throws {
        let store = try TestDatabase.makeStore()
        let userId = try store.resolveUser(email: "f@example.com", displayName: nil)
        try TestDatabase.insertPhoto(store.db, assetId: "p1", owner: userId)
        try TestDatabase.insertPhoto(store.db, assetId: "p2", owner: userId, embedding: TestDatabase.vector(3))
        let before = try ["p1", "p2"].map { try TestDatabase.embeddingBytes(store.db, $0) }

        try store.savePersonalization(userId: userId, interestIds: ["music_live"], topLevelIds: ["items_collections"], status: .completed)
        try store.savePersonalization(userId: userId, interestIds: [], topLevelIds: [], status: .completed)
        try store.saveInterests(userId: userId, interestIds: ["pets_animals", "study_work"])

        let after = try ["p1", "p2"].map { try TestDatabase.embeddingBytes(store.db, $0) }
        XCTAssertEqual(before, after)
        XCTAssertNotNil(after[0])
    }
}

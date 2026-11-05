// swift-tools-version:5.9
//
// PersonalizationCore：個人化分類系統中與平台無關的核心邏輯（分類目錄、推薦、多標籤、資料庫）。
// App target 直接編譯 Sources/PersonalizationCore 底下的檔案（見 project.pbxproj 的 Personalization 群組），
// 這個 Package 只是讓同一份程式碼可以在 macOS 上用 `swift test` 執行單元測試。
//
// 執行方式（需要 Xcode / Swift 工具鏈）：
//   cd PersonalizationCore && swift test

import PackageDescription

let package = Package(
    name: "PersonalizationCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "PersonalizationCore", targets: ["PersonalizationCore"]),
    ],
    dependencies: [
        // 與 App 相同版本（MobileCLIPExplore.xcodeproj Package.resolved：SQLite.swift 0.16.0）
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.16.0"),
    ],
    targets: [
        .target(
            name: "PersonalizationCore",
            dependencies: [.product(name: "SQLite", package: "SQLite.swift")]
        ),
        .testTarget(
            name: "PersonalizationCoreTests",
            dependencies: ["PersonalizationCore", .product(name: "SQLite", package: "SQLite.swift")]
        ),
    ]
)

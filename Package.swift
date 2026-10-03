// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoMCP",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.9.0"),
    ],
    targets: [
        // Shared: XPCプロトコル定義（両ターゲット共有）
        .target(
            name: "PhotoMCPShared",
            path: "Shared"
        ),

        // PhotoMCPHelper: Claude Desktop が stdio 経由で起動する MCP サーバー
        .executableTarget(
            name: "MCPServer",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                "PhotoMCPShared",
            ],
            path: "PhotoMCPHelper",
            // NSXPCConnectionのcompletion-handler APIはSendable適合が難しいため、
            // このターゲットのみSwift 5の並行性チェックに緩和する。
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // PhotoMCPApp: PhotoKit 許可を保持し XPC で応答する常駐アプリ
        // ビルドはSPM (`swift build`) で行う。Xcodeプロジェクトは使わない。
        // entitlements・署名・Photos権限の扱いはREADME.mdの「ビルド方法」
        // 「ハマりどころ」セクション参照（2026-09-27に全面更新済み）。
        .executableTarget(
            name: "PhotoMCPApp",
            dependencies: [
                "PhotoMCPShared",
            ],
            path: "PhotoMCPApp",
            exclude: [
                "Info.plist",
                "PhotoMCPApp.entitlements",
                // AppIcon.icns生成用のソース原本（1024x1024）。実行時には不要なのでバンドルしない。
                "Resources/Icons/AppIcon-1024.png",
            ],
            resources: [
                // アプリアイコン（.icns）とメニューバーアイコン（1x/2x）。
                // 2026-09-27追加。Bundle.module経由で読み込む。
                .copy("Resources/Icons/AppIcon.icns"),
                .copy("Resources/Icons/MenuBarIcon.png"),
                .copy("Resources/Icons/MenuBarIcon@2x.png"),
            ],
            // NSXPCConnection / AppKitのcompletion-handler APIはSendable適合が難しいため、
            // このターゲットのみSwift 5の並行性チェックに緩和する。
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

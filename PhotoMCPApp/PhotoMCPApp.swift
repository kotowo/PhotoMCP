import AppKit
import Foundation

/// PhotoMCPApp のエントリポイント。
///
/// このアプリはDockアイコンを持たない常駐アプリ（Info.plistでLSUIElement=true）。
/// 役割は2つだけ:
///   1. PhotoKit (Photos.app) へのアクセス許可 (TCC) を保持する
///   2. XPC (Mach Service) 経由で PhotoMCPHelper からのリクエストに応答する
///
/// メニューバーにステータスアイコンを表示し、終了用のメニューを提供する。
@main
final class PhotoMCPAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Dockアイコン非表示・メニューバーのみ
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AppDelegate] launched. XPC_SERVICE_NAME=\(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "(nil)")")

        // ユーザーがダブルクリックで起動した場合は、LaunchAgentの登録だけ行って終了する
        // （XPCの待ち受けはlaunchd管理下の常駐プロセスが行う）。2026-09-28追加。
        guard AgentRegistration.isLaunchedByLaunchd else {
            AgentRegistration.runSetupAndTerminate()
            return
        }

        setUpStatusItem()

        // Photos権限のダイアログはDockアイコンのない.accessoryアプリだと
        // OSに表示されず自動拒否される（2026-09-27に実機で確認）。
        // 許可リクエストの間だけ一時的に.regularへ切り替えてダイアログを出し、
        // 完了後（許可・拒否・確認スキップいずれの場合も）.accessoryへ戻す。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // activate直後だとWindowServer/TCC側の認識が間に合わず即座に自動拒否されることがあるため、
        // リクエストを少し遅らせる。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            PhotoKitService.shared.requestAuthorizationIfNeeded {
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        XPCListenerManager.start()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = Self.menuBarIcon() {
            item.button?.image = icon
        } else {
            // アイコン読み込みに失敗した場合のフォールバック
            item.button?.title = "📷"
        }
        item.button?.toolTip = "PhotoMCP — Claude Desktop から Photos.app へのブリッジ"

        let menu = NSMenu()
        menu.addItem(
            withTitle: "PhotoMCP 実行中",
            action: nil,
            keyEquivalent: ""
        )
        menu.items.first?.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "終了",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        // 「終了」は正常終了なのでKeepAliveで再起動されないが、MCPServerからの接続で再び起動する。
        // 完全に止める（アンインストール前など）には常駐を解除する。
        menu.addItem(
            withTitle: "常駐を解除して終了",
            action: #selector(unregisterAgent),
            keyEquivalent: ""
        )
        item.menu = menu
        statusItem = item
    }

    /// メニューバー用アイコンを1x/2xの2枚から組み立てる。
    /// テンプレート画像として扱い、ライト/ダークのメニューバーに自動追従させる。
    /// (2026-09-27追加。読み込みに失敗した場合はnilを返し、呼び出し側で絵文字にフォールバック)
    private static func menuBarIcon() -> NSImage? {
        guard
            let url1x = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
            let url2x = Bundle.module.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
            let rep1x = NSImage(contentsOf: url1x)?.representations.first,
            let rep2x = NSImage(contentsOf: url2x)?.representations.first
        else {
            return nil
        }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.addRepresentation(rep1x)
        image.addRepresentation(rep2x)
        image.isTemplate = true
        return image
    }

    @objc private func unregisterAgent() {
        AgentRegistration.unregister()
        NSApplication.shared.terminate(nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

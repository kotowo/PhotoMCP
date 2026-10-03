import AppKit
import Foundation
import ServiceManagement

/// SMAppService による LaunchAgent の登録・起動モード判定（2026-09-28追加）。
///
/// PhotoMCPApp は2通りの起動のされ方をする:
///   - launchd から LaunchAgent として起動（常駐モード）: XPC を待ち受け、メニューバーに常駐する
///   - ユーザーが Finder 等からダブルクリックで起動（セットアップモード）:
///     LaunchAgent を登録（まだなら）し、状態を表示して終了する。
///     Mach Service のチェックインは launchd 管理下のプロセスしかできないため、
///     このモードでは XPC を待ち受けない。
enum AgentRegistration {

    /// Contents/Library/LaunchAgents/ に同梱した plist のファイル名（= Label + ".plist"）
    static let label = "com.makoto.photomcp.agent"
    static let plistName = label + ".plist"

    /// 旧方式（手動で ~/Library/LaunchAgents に置く plist）の Label とパス
    static let legacyLabel = "com.makoto.photomcp.xpc"
    static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    /// launchd からジョブとして起動されたか。
    /// launchd はジョブの環境変数 XPC_SERVICE_NAME に Label を入れる
    /// （Finder 起動時は "application.<bundle id>..." などになる）。
    /// 旧方式の Label でも常駐モードとして扱う（移行期間の互換のため）。
    static var isLaunchedByLaunchd: Bool {
        let name = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        return name == label || name == legacyLabel
    }

    static var hasLegacyAgent: Bool {
        FileManager.default.fileExists(atPath: legacyPlistURL.path)
    }

    static func statusDescription(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "未登録"
        case .enabled: return "有効"
        case .requiresApproval: return "承認待ち（システム設定 > 一般 > ログイン項目）"
        case .notFound: return "plist が見つからない"
        @unknown default: return "不明(\(status.rawValue))"
        }
    }

    // MARK: - セットアップモード

    /// ユーザー起動時の処理。登録して結果をダイアログで示し、アプリを終了する。
    static func runSetupAndTerminate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if hasLegacyAgent {
            showAlert(
                title: "旧方式の LaunchAgent が残っています",
                text: """
                \(legacyPlistURL.path) が見つかりました。
                同じ Mach Service 名を使うため、新方式と同時には動かせません。
                ターミナルで次を実行して旧方式を外してから、もう一度このアプリを開いてください。

                launchctl bootout gui/$(id -u)/\(legacyLabel)
                rm \(legacyPlistURL.path)
                """)
            NSApp.terminate(nil)
            return
        }

        let service = self.service
        var message: String
        do {
            if service.status != .enabled {
                try service.register()
            }
            message = "常駐エージェントの状態: \(statusDescription(service.status))"
        } catch {
            NSLog("[AgentRegistration] register failed: \(error)")
            message = "常駐エージェントの登録に失敗しました: \(error.localizedDescription)\n" +
                      "状態: \(statusDescription(service.status))"
        }
        NSLog("[AgentRegistration] \(message)")

        if service.status == .requiresApproval {
            showAlert(
                title: "ログイン項目での許可が必要です",
                text: message + "\n\n「システム設定 > 一般 > ログイン項目」で PhotoMCPApp をオンにしてください。")
            SMAppService.openSystemSettingsLoginItems()
        } else {
            showAlert(
                title: "PhotoMCP",
                text: message + "\n\nメニューバーのアイコンから常駐を解除できます。")
        }
        NSApp.terminate(nil)
    }

    /// 常駐を解除する（メニューから呼ぶ）。解除後、launchd がこのプロセスを終了させる。
    static func unregister() {
        do {
            try service.unregister()
            NSLog("[AgentRegistration] unregistered")
        } catch {
            NSLog("[AgentRegistration] unregister failed: \(error)")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            showAlert(title: "常駐の解除に失敗しました", text: error.localizedDescription)
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

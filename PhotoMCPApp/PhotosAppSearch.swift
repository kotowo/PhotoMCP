import Foundation

/// Photos.app 内蔵の検索（画像認識によるシーン・物体インデックス）を
/// AppleScript の `search for` コマンド経由で呼び出す。
///
/// PhotoKit には被写体での検索APIが無いため、この経路で候補IDを取得し、
/// 画像・メタデータの取得は従来どおり PhotoKit で行う（2026-09-28追加）。
///
/// 前提・制約（2026-09-28に実機で確認）:
/// - 返るIDは `PHAsset.localIdentifier` と同じ形式（例: `UUID/L0/001`）。
/// - 検索対象は (1) 被写体・シーンのラベル、(2)「ピープルとペット」の名前、(3) 写真内の文字（テキスト認識）。
///   (1) は英語で効く（"teddy bear" 76件, "cat" 836件）。日本語ラベルはほぼヒットしない（「ぬいぐるみ」0件）。
///   (2) は登録名で完全一致（ペット名「剣太」223件、ローマ字「kenta」ではヒットせず）。
///   (3) は写っている言語のまま効く（「大塚誠」で名刺・書類など7件）。
///   空白区切りの複数語はAND、語順は無関係（"OTSUKA Makoto" と "Makoto OTSUKA" が同じ105件）。
/// - 各要素に `id of` を問い合わせるループは836件で約15秒かかる。リストをそのまま返し、
///   オブジェクト指定子のキーデータ（'seld'）からIDを取り出すと約0.3秒で済む。
/// - Apple Events の送信許可（TCC: オートメーション）が必要。Hardened Runtime では
///   `com.apple.security.automation.apple-events` entitlement と Info.plist の
///   `NSAppleEventsUsageDescription` が必要。
/// - Photos.app が起動していなければ起動される。
enum PhotosAppSearch {

    /// Apple Event のタイムアウト（秒）。XPC側（MCPServer）のタイムアウトより短くしておく。
    static let appleEventTimeoutSeconds = 25

    /// オブジェクト指定子のキーデータを表すキーワード（keyAEKeyData = 'seld'）。
    private static let keyAEKeyDataCode: AEKeyword = 0x7365_6C64

    /// AppleScriptの文字列リテラル用にエスケープする。
    static func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func makeScript(keyword: String) -> String {
        """
        with timeout of \(appleEventTimeoutSeconds) seconds
            tell application id "com.apple.Photos"
                return (search for "\(escapeForAppleScript(keyword))")
            end tell
        end timeout
        """
    }

    /// キーワードで Photos.app を検索し、ヒットした写真のIDを返す。
    /// NSAppleScript はスレッドセーフではないためメインスレッドで実行し、
    /// completion はグローバルキューで呼ぶ（呼び出し側でPhotoKit処理を続けるため）。
    static func search(keyword: String, completion: @escaping (Result<[String], String>) -> Void) {
        DispatchQueue.main.async {
            let result = runOnMain(keyword: keyword)
            DispatchQueue.global(qos: .userInitiated).async {
                completion(result)
            }
        }
    }

    private static func runOnMain(keyword: String) -> Result<[String], String> {
        guard let script = NSAppleScript(source: makeScript(keyword: keyword)) else {
            return .failure("Photos.app検索用のAppleScriptを生成できませんでした")
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            NSLog("[PhotosAppSearch] AppleScript error \(number): \(message)")
            if number == -1743 {
                return .failure(
                    "Photos.appの操作が許可されていません(-1743)。" +
                    "システム設定 > プライバシーとセキュリティ > オートメーション で PhotoMCPApp に「写真」を許可してください。")
            }
            return .failure("Photos.app検索に失敗しました(\(number)): \(message)")
        }
        return .success(extractIDs(from: descriptor))
    }

    /// `search for` の戻り値（media item のオブジェクト指定子のリスト）からIDを取り出す。
    static func extractIDs(from descriptor: NSAppleEventDescriptor) -> [String] {
        let count = descriptor.numberOfItems
        guard count > 0 else { return [] }
        var ids: [String] = []
        ids.reserveCapacity(count)
        for index in 1...count {
            guard let item = descriptor.atIndex(index) else { continue }
            if let id = item.forKeyword(keyAEKeyDataCode)?.stringValue {
                ids.append(id)
            } else if let id = item.stringValue {
                ids.append(id)
            }
        }
        return ids
    }
}

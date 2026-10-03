import Foundation

/// XPCプロトコル定義。
///
/// PhotoMCPHelper（CLI / MCPサーバー、Claude Desktopが起動）から
/// PhotoMCPApp（PhotoKit + TCC許可を保持する常駐アプリ）を呼び出すためのインターフェース。
///
/// NSXPCConnection はオブジェクトを直接 Codable で受け渡しできないため、
/// 戻り値は NSSecureCoding に準拠する基本型（NSDictionary, NSArray, NSString, NSData, NSDate, Bool, Int 等）に統一する。
/// このファイルは PhotoMCPApp / PhotoMCPHelper の両ターゲットに追加すること（Target Membership両方にチェック）。
@objc public protocol PhotoMCPXPCProtocol {

    /// 疎通確認用
    func ping(reply: @escaping (Bool) -> Void)

    /// アルバム一覧を取得する
    /// reply: (json, error)
    ///   json = { "albums": [ { "id": String, "title": String, "count": Int }, ... ] }
    func listAlbums(reply: @escaping (NSDictionary?, String?) -> Void)

    /// 指定IDの写真データを取得する（縮小版）
    /// - id: PHAsset.localIdentifier
    /// - maxSize: 長辺の最大ピクセル数（0以下の場合はデフォルト1024pxを使用）
    /// reply: (imageData, mimeType, width, height, error)
    func getPhoto(
        id: String,
        maxSize: Int,
        reply: @escaping (Data?, String?, Int, Int, String?) -> Void
    )

    /// 写真を検索する（条件はすべて省略可・AND条件）
    /// - keyword: Photos.app の検索（AppleScript `search for`）に渡す。
    ///   被写体・シーンは英語、ピープル/ペット名は登録どおり、写真内の文字はその言語のまま
    /// - dateFrom / dateTo: 撮影日時の範囲
    /// reply: (json, error)
    ///   json = { "photos": [ { "id": String, "createdAt": String?, "width": Int, "height": Int }, ... ],
    ///            "total": Int, "searchMode": "none" | "photos_app" | "date_string_fallback",
    ///            "warning": String? }
    func searchPhotos(
        keyword: String?,
        dateFrom: Date?,
        dateTo: Date?,
        location: String?,
        reply: @escaping (NSDictionary?, String?) -> Void
    )

    /// メタデータを取得する
    /// reply: (json, error)
    ///   json = { "createdAt": String?, "latitude": Double?, "longitude": Double?,
    ///            "cameraMake": String?, "cameraModel": String?,
    ///            "pixelWidth": Int, "pixelHeight": Int, "isFavorite": Bool }
    func getMetadata(
        id: String,
        reply: @escaping (NSDictionary?, String?) -> Void
    )

    /// 指定したアルバム（PHAssetCollection.localIdentifier）に含まれる写真一覧を取得する
    /// - albumId: list_albums で取得した id
    /// reply: (json, error)
    ///   json = { "photos": [ { "id": String, "createdAt": String?, "width": Int, "height": Int }, ... ] }
    func listPhotosInAlbum(
        albumId: String,
        reply: @escaping (NSDictionary?, String?) -> Void
    )
}

/// Mach Service名。
/// LaunchAgent plist（Resources/com.makoto.photomcp.xpc.plist）の MachServices キーと
/// 必ず一致させること。変更する場合は両方を同時に変更する。
public enum PhotoMCPXPC {
    public static let machServiceName = "com.makoto.PhotoMCP.xpc"
}

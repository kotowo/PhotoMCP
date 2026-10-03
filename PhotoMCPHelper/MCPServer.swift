import Foundation
import MCP

/// 5つのMCPツールをサーバーに登録する。
/// 実処理はすべて XPCClient 経由で PhotoMCPApp（PhotoKit保持プロセス）に委譲する。
func registerHandlers(on server: Server) async {

    await server.withMethodHandler(ListTools.self) { _ in
        let tools: [Tool] = [
            Tool(
                name: "list_albums",
                description: "Photos.appのアルバム一覧（ID・タイトル・枚数）を取得する",
                inputSchema: [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ),
            Tool(
                name: "get_photo",
                description: "指定したIDの写真を縮小画像（デフォルト長辺1024px）として取得する",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "PHAsset.localIdentifier（search_photos / list_albums で取得したID）"
                        ],
                        "max_size": [
                            "type": "integer",
                            "description": "長辺の最大ピクセル数。省略時は1024。"
                        ]
                    ],
                    "required": ["id"]
                ]
            ),
            Tool(
                name: "save_photo",
                description: "指定したIDの写真をローカルファイルとして保存する（縮小画像、デフォルト長辺1024px）。Photos.appは起動しない。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "PHAsset.localIdentifier（search_photos / list_albums で取得したID）"
                        ],
                        "path": [
                            "type": "string",
                            "description": "保存先パス。ディレクトリを指定した場合はID由来のファイル名で保存。省略時は ~/Downloads 配下にID由来のファイル名で保存。"
                        ],
                        "max_size": [
                            "type": "integer",
                            "description": "長辺の最大ピクセル数。省略時は1024。"
                        ]
                    ],
                    "required": ["id"]
                ]
            ),
            Tool(
                name: "search_photos",
                description: "条件（キーワード・撮影日範囲・位置情報）で写真を検索する。すべて省略可・AND条件、撮影日の新しい順で最大200件。keywordはPhotos.appの検索機能と同じ結果になる。レスポンスのsearchModeが\"date_string_fallback\"の場合はPhotos.app検索が使えず、撮影日文字列での簡易検索に切り替わっている（理由はwarning）。totalは条件に合った総件数（200件を超える場合、photosは切り詰められる）。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "keyword": [
                            "type": "string",
                            "description": "Photos.appの検索窓と同じキーワード。対象と指定方法: (1) 被写体・シーン → 英語で指定（例: \"cat\", \"teddy bear\", \"beach\"）。日本語のラベルはほぼヒットしない。(2) Photos.appの「ピープルとペット」に登録された名前 → 登録どおりの表記で指定（例: \"剣太\"）。部分一致しない。(3) 写真に写っている文字（書類・スクリーンショット・看板など）→ 写っている言語のまま指定（例: \"大塚誠\"）。空白区切りの複数語はAND条件（語順は無関係）。"
                        ],
                        "date_from": [
                            "type": "string",
                            "description": "撮影日の開始（ISO8601形式、例: 2026-01-01T00:00:00Z）"
                        ],
                        "date_to": [
                            "type": "string",
                            "description": "撮影日の終了（ISO8601形式）"
                        ],
                        "location": [
                            "type": "string",
                            "description": "位置情報による絞り込み（現状は未実装、将来の拡張用）"
                        ]
                    ],
                    "required": []
                ]
            ),
            Tool(
                name: "get_metadata",
                description: "指定したIDの写真のメタデータ（撮影日・GPS座標・お気に入り等）を取得する",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "PHAsset.localIdentifier"
                        ]
                    ],
                    "required": ["id"]
                ]
            ),
            Tool(
                name: "get_album_photos",
                description: "指定したアルバムIDに含まれる写真一覧（ID・撮影日・サイズ）を取得する。最大500件。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "album_id": [
                            "type": "string",
                            "description": "PHAssetCollection.localIdentifier（list_albums で取得したid）"
                        ]
                    ],
                    "required": ["album_id"]
                ]
            )
        ]
        return .init(tools: tools)
    }

    await server.withMethodHandler(CallTool.self) { params in
        do {
            switch params.name {
            case "list_albums":
                let json = try await XPCClient.shared.listAlbums()
                return .init(content: [textContent(fromJSON: json)], isError: false)

            case "get_photo":
                guard let id = params.arguments?["id"]?.stringValue else {
                    return errorResult("id パラメータは必須です")
                }
                let maxSize = params.arguments?["max_size"]?.intValue ?? 0
                let photo = try await XPCClient.shared.getPhoto(id: id, maxSize: maxSize)
                let base64 = photo.data.base64EncodedString()
                return .init(
                    content: [
                        .image(data: base64, mimeType: photo.mimeType, annotations: nil, _meta: nil),
                        .text(
                            text: "width=\(photo.width), height=\(photo.height)",
                            annotations: nil, _meta: nil)
                    ],
                    isError: false
                )

            case "save_photo":
                guard let id = params.arguments?["id"]?.stringValue else {
                    return errorResult("id パラメータは必須です")
                }
                let maxSize = params.arguments?["max_size"]?.intValue ?? 0
                let photo = try await XPCClient.shared.getPhoto(id: id, maxSize: maxSize)
                let requestedPath = params.arguments?["path"]?.stringValue
                do {
                    let fileURL = try resolveSaveURL(
                        requestedPath: requestedPath, id: id, mimeType: photo.mimeType)
                    try photo.data.write(to: fileURL, options: .atomic)
                    let json: [String: Any] = [
                        "path": fileURL.path,
                        "width": photo.width,
                        "height": photo.height,
                        "bytes": photo.data.count
                    ]
                    return .init(content: [textContent(fromJSON: json)], isError: false)
                } catch {
                    return errorResult("保存に失敗しました: \(error)")
                }

            case "search_photos":
                let keyword = params.arguments?["keyword"]?.stringValue
                let location = params.arguments?["location"]?.stringValue
                let dateFrom = params.arguments?["date_from"]?.stringValue.flatMap(parseISO8601)
                let dateTo = params.arguments?["date_to"]?.stringValue.flatMap(parseISO8601)
                let json = try await XPCClient.shared.searchPhotos(
                    keyword: keyword, dateFrom: dateFrom, dateTo: dateTo, location: location)
                return .init(content: [textContent(fromJSON: json)], isError: false)

            case "get_metadata":
                guard let id = params.arguments?["id"]?.stringValue else {
                    return errorResult("id パラメータは必須です")
                }
                let json = try await XPCClient.shared.getMetadata(id: id)
                return .init(content: [textContent(fromJSON: json)], isError: false)

            case "get_album_photos":
                guard let albumId = params.arguments?["album_id"]?.stringValue else {
                    return errorResult("album_id パラメータは必須です")
                }
                let json = try await XPCClient.shared.listPhotosInAlbum(albumId: albumId)
                return .init(content: [textContent(fromJSON: json)], isError: false)

            default:
                return errorResult("Unknown tool: \(params.name)")
            }
        } catch {
            return errorResult("\(error)")
        }
    }
}

// MARK: - Helpers

private func textContent(fromJSON dict: [String: Any]) -> Tool.Content {
    let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    let text = String(data: data, encoding: .utf8) ?? "{}"
    return .text(text: text, annotations: nil, _meta: nil)
}

private func errorResult(_ message: String) -> CallTool.Result {
    .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}

private func parseISO8601(_ string: String) -> Date? {
    ISO8601DateFormatter().date(from: string)
}

/// save_photo の保存先を決定する。
/// - requestedPath が nil → ~/Downloads/<id由来のファイル名>
/// - requestedPath がディレクトリ（末尾 "/" または既存ディレクトリ）→ そのディレクトリ配下にID由来のファイル名
/// - それ以外 → requestedPath をそのままファイルパスとして使う
private func resolveSaveURL(requestedPath: String?, id: String, mimeType: String) throws -> URL {
    let ext = mimeType == "image/png" ? "png" : "jpg"
    let safeName = id.replacingOccurrences(of: "/", with: "_") + "." + ext

    let fileManager = FileManager.default
    let expandedPath = (requestedPath as NSString?)?.expandingTildeInPath

    let fileURL: URL
    if let expandedPath, !expandedPath.isEmpty {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory)
        if expandedPath.hasSuffix("/") || (exists && isDirectory.boolValue) {
            fileURL = URL(fileURLWithPath: expandedPath, isDirectory: true).appendingPathComponent(safeName)
        } else {
            fileURL = URL(fileURLWithPath: expandedPath)
        }
    } else {
        let downloads = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        fileURL = downloads.appendingPathComponent(safeName)
    }

    try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    return fileURL
}

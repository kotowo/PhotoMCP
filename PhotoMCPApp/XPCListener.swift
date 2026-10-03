import Foundation
import PhotoMCPShared

/// XPC公開オブジェクト。PhotoMCPXPCProtocol の実装。
/// 実処理は PhotoKitService に委譲する。
final class PhotoMCPXPCExportedObject: NSObject, PhotoMCPXPCProtocol {

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func listAlbums(reply: @escaping (NSDictionary?, String?) -> Void) {
        switch PhotoKitService.shared.listAlbums() {
        case .success(let dict):
            reply(dict as NSDictionary, nil)
        case .failure(let error):
            reply(nil, error)
        }
    }

    func getPhoto(
        id: String,
        maxSize: Int,
        reply: @escaping (Data?, String?, Int, Int, String?) -> Void
    ) {
        PhotoKitService.shared.getPhoto(id: id, maxSize: maxSize, completion: reply)
    }

    func searchPhotos(
        keyword: String?,
        dateFrom: Date?,
        dateTo: Date?,
        location: String?,
        reply: @escaping (NSDictionary?, String?) -> Void
    ) {
        // keyword指定時はPhotos.app検索（AppleScript）を挟むため非同期。
        PhotoKitService.shared.searchPhotos(
            keyword: keyword, dateFrom: dateFrom, dateTo: dateTo, location: location
        ) { result in
            switch result {
            case .success(let dict):
                reply(dict as NSDictionary, nil)
            case .failure(let error):
                reply(nil, error)
            }
        }
    }

    func getMetadata(id: String, reply: @escaping (NSDictionary?, String?) -> Void) {
        PhotoKitService.shared.getMetadata(id: id) { dict, error in
            if let error = error {
                reply(nil, error)
            } else {
                reply((dict ?? [:]) as NSDictionary, nil)
            }
        }
    }

    func listPhotosInAlbum(albumId: String, reply: @escaping (NSDictionary?, String?) -> Void) {
        switch PhotoKitService.shared.listPhotosInAlbum(albumId: albumId) {
        case .success(let dict):
            reply(dict as NSDictionary, nil)
        case .failure(let error):
            reply(nil, error)
        }
    }
}

/// NSXPCListener のデリゲート。新規接続ごとに公開オブジェクトを割り当てる。
final class PhotoMCPXPCDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: PhotoMCPXPCProtocol.self)
        newConnection.exportedObject = PhotoMCPXPCExportedObject()
        newConnection.invalidationHandler = {
            NSLog("[XPCListener] connection invalidated")
        }
        newConnection.interruptionHandler = {
            NSLog("[XPCListener] connection interrupted")
        }
        newConnection.resume()
        NSLog("[XPCListener] accepted new connection")
        return true
    }
}

/// Mach Service 経由でリッスンするラッパー。
/// 前提: このプロセスは LaunchAgent (Resources/com.makoto.photomcp.xpc.plist) 経由で
/// 起動されており、launchd が PhotoMCPXPC.machServiceName を予約済みであること。
/// （詳細はリポジトリ直下の README.md を参照）
enum XPCListenerManager {
    // static mutable stateだが、start() は起動時に一度だけ呼ばれ、
    // 以降このプロセス内で並行に書き換えられないためnonisolated(unsafe)で許容する。
    private nonisolated(unsafe) static var listener: NSXPCListener?
    private nonisolated(unsafe) static let delegate = PhotoMCPXPCDelegate()

    static func start() {
        let listener = NSXPCListener(machServiceName: PhotoMCPXPC.machServiceName)
        listener.delegate = delegate
        listener.resume()
        self.listener = listener
        NSLog("[XPCListener] listening on mach service: \(PhotoMCPXPC.machServiceName)")
    }
}

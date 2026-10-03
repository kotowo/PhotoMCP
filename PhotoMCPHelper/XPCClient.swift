import Foundation
import PhotoMCPShared

enum XPCClientError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case remoteError(String)

    var description: String {
        switch self {
        case .connectionFailed(let msg): return "XPC接続エラー: \(msg)"
        case .remoteError(let msg): return "PhotoMCPAppエラー: \(msg)"
        }
    }
}

/// PhotoMCPApp への XPC クライアント。
/// completion-handlerベースのXPC APIを async/await でラップする。
final class XPCClient {

    // MCPServerプロセスはシングルスレッド的にstdioを処理するため、
    // 単純化のためnonisolated(unsafe)で許容する（XPCListenerManager/PhotoKitServiceと同じ方針）。
    nonisolated(unsafe) static let shared = XPCClient()

    private var connection: NSXPCConnection?
    private let defaultTimeout: TimeInterval = 30

    /// 接続を取得する。切れていれば張り直す。
    private func connect() throws -> NSXPCConnection {
        if connection == nil {
            let conn = NSXPCConnection(machServiceName: PhotoMCPXPC.machServiceName, options: [])
            conn.remoteObjectInterface = NSXPCInterface(with: PhotoMCPXPCProtocol.self)
            conn.invalidationHandler = { [weak self] in
                NSLog("[XPCClient] connection invalidated")
                self?.connection = nil
            }
            conn.interruptionHandler = {
                NSLog("[XPCClient] connection interrupted")
            }
            conn.resume()
            connection = conn
        }
        guard let conn = connection else {
            throw XPCClientError.connectionFailed("connection is nil")
        }
        return conn
    }

    /// XPC呼び出しを一度だけ確実に完了させるラッパー。
    ///
    /// 従来は `remoteObjectProxyWithErrorHandler` のエラーハンドラがNSLogするだけで
    /// continuationをresumeしていなかったため、接続断・中断などが起きると
    /// `await` が永久に返らず呼び出し元ごと固まっていた（特にget_photoのような
    /// 処理時間の長い呼び出しほど踏みやすい）。ここでは
    /// (1) エラーハンドラ発火時、(2) reply受信時、(3) タイムアウト時
    /// のいずれでも必ず一度だけresumeするようにする。
    private func call<T>(
        timeout: TimeInterval? = nil,
        _ body: @escaping (PhotoMCPXPCProtocol, @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let conn = try connect()
        let effectiveTimeout = timeout ?? defaultTimeout

        return try await withCheckedThrowingContinuation { cont in
            let lock = NSLock()
            var isResolved = false
            func resolve(_ result: Result<T, Error>) {
                lock.lock()
                let alreadyResolved = isResolved
                isResolved = true
                lock.unlock()
                guard !alreadyResolved else { return }
                switch result {
                case .success(let value): cont.resume(returning: value)
                case .failure(let error): cont.resume(throwing: error)
                }
            }

            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                NSLog("[XPCClient] remote proxy error: \(error)")
                resolve(.failure(XPCClientError.connectionFailed(error.localizedDescription)))
            }) as? PhotoMCPXPCProtocol else {
                resolve(.failure(XPCClientError.connectionFailed("remoteObjectProxy cast failed")))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + effectiveTimeout) {
                resolve(.failure(XPCClientError.connectionFailed("timed out after \(effectiveTimeout)s")))
            }

            body(proxy) { result in
                resolve(result)
            }
        }
    }

    func ping() async throws -> Bool {
        try await call { proxy, done in
            proxy.ping { ok in done(.success(ok)) }
        }
    }

    func listAlbums() async throws -> [String: Any] {
        try await call { proxy, done in
            proxy.listAlbums { dict, error in
                if let error = error {
                    done(.failure(XPCClientError.remoteError(error)))
                } else {
                    done(.success((dict as? [String: Any]) ?? [:]))
                }
            }
        }
    }

    struct PhotoResult {
        let data: Data
        let mimeType: String
        let width: Int
        let height: Int
    }

    func getPhoto(id: String, maxSize: Int) async throws -> PhotoResult {
        // iCloudからのダウンロードを伴う可能性があるため長めのタイムアウトにする
        try await call(timeout: 60) { proxy, done in
            proxy.getPhoto(id: id, maxSize: maxSize) { data, mimeType, width, height, error in
                if let error = error {
                    done(.failure(XPCClientError.remoteError(error)))
                } else if let data = data, let mimeType = mimeType {
                    done(.success(PhotoResult(data: data, mimeType: mimeType, width: width, height: height)))
                } else {
                    done(.failure(XPCClientError.remoteError("empty response")))
                }
            }
        }
    }

    func searchPhotos(
        keyword: String?,
        dateFrom: Date?,
        dateTo: Date?,
        location: String?
    ) async throws -> [String: Any] {
        // keyword指定時はPhotos.app検索（AppleScript、Apple Eventタイムアウト25秒）を挟むため長めにする。
        // 初回はオートメーション許可ダイアログの応答待ちも含まれる。
        try await call(timeout: 60) { proxy, done in
            proxy.searchPhotos(keyword: keyword, dateFrom: dateFrom, dateTo: dateTo, location: location) { dict, error in
                if let error = error {
                    done(.failure(XPCClientError.remoteError(error)))
                } else {
                    done(.success((dict as? [String: Any]) ?? [:]))
                }
            }
        }
    }

    func getMetadata(id: String) async throws -> [String: Any] {
        // requestContentEditingInputでのiCloudアクセスを伴う可能性があるため長めにする
        try await call(timeout: 60) { proxy, done in
            proxy.getMetadata(id: id) { dict, error in
                if let error = error {
                    done(.failure(XPCClientError.remoteError(error)))
                } else {
                    done(.success((dict as? [String: Any]) ?? [:]))
                }
            }
        }
    }

    func listPhotosInAlbum(albumId: String) async throws -> [String: Any] {
        try await call { proxy, done in
            proxy.listPhotosInAlbum(albumId: albumId) { dict, error in
                if let error = error {
                    done(.failure(XPCClientError.remoteError(error)))
                } else {
                    done(.success((dict as? [String: Any]) ?? [:]))
                }
            }
        }
    }
}

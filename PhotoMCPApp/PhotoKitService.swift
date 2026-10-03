import Foundation
import Photos
import AppKit
import ImageIO

/// エラーメッセージを Result<_, String> の Failure として使えるようにする最小限の適合。
/// （新しいエラー型を作って全呼び出し元を書き換えるより低リスクなため、この形にしている）
extension String: @retroactive Error {}

/// PhotoKit (Photos.framework) を使った写真アクセスの実装。
/// PhotoMCPApp プロセス内でのみ動作する（TCC許可はこのプロセスに紐づく）。
final class PhotoKitService {

    // XPC/PhotoKitのコールバックは複数スレッドから呼ばれ得るが、
    // 本サービスはprocess内シングルトンとして単純化のため許容する。
    nonisolated(unsafe) static let shared = PhotoKitService()

    private let imageManager = PHCachingImageManager()
    private let defaultMaxSize = 1024
    // iCloudダウンロード待ち等でcompletionが呼ばれずXPC呼び出し元を無限に固まらせないためのガード。
    private let imageFetchTimeout: TimeInterval = 45

    // MARK: - 認可

    /// 起動時に呼ぶ。未許可ならOSのダイアログを表示する。
    /// completion は許可フロー（表示不要な場合も含む）が一区切りついたタイミングで呼ばれる。
    /// 呼び出し側（AppDelegate）はこれを使って、ダイアログ表示のために一時的に
    /// activationPolicyを.regularに切り替えていた場合、.accessoryに戻すタイミングとして使う。
    func requestAuthorizationIfNeeded(completion: @escaping () -> Void = {}) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                NSLog("[PhotoKitService] authorization status: \(newStatus.rawValue)")
                completion()
            }
        case .authorized, .limited:
            completion()
        default:
            NSLog("[PhotoKitService] Photos access not granted (status=\(status.rawValue)). " +
                  "システム設定 > プライバシーとセキュリティ > 写真 から許可してください。")
            completion()
        }
    }

    private var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    // MARK: - listAlbums

    func listAlbums() -> Result<[String: Any], String> {
        guard isAuthorized else { return .failure("Photos access not authorized") }

        var albums: [[String: Any]] = []

        func appendAlbums(from collections: PHFetchResult<PHAssetCollection>) {
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                albums.append([
                    "id": collection.localIdentifier,
                    "title": collection.localizedTitle ?? "(無題)",
                    "count": assets.count
                ])
            }
        }

        // ユーザー作成アルバム
        appendAlbums(from: PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil))
        // スマートアルバム（よく使うもののみ: お気に入り・セルフィー・スクリーンショット等）
        appendAlbums(from: PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .albumRegular, options: nil))

        return .success(["albums": albums])
    }

    // MARK: - getPhoto

    func getPhoto(
        id: String,
        maxSize: Int,
        completion: @escaping (Data?, String?, Int, Int, String?) -> Void
    ) {
        guard isAuthorized else {
            completion(nil, nil, 0, 0, "Photos access not authorized")
            return
        }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetchResult.firstObject else {
            completion(nil, nil, 0, 0, "Asset not found: \(id)")
            return
        }

        let targetLength = CGFloat(maxSize > 0 ? maxSize : defaultMaxSize)
        let scale = min(1.0, targetLength / CGFloat(max(asset.pixelWidth, asset.pixelHeight)))
        let targetSize = CGSize(
            width: CGFloat(asset.pixelWidth) * scale,
            height: CGFloat(asset.pixelHeight) * scale
        )

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true // iCloud上の写真も取得を試みる

        // requestImageのcompletionはiCloudダウンロードが詰まると呼ばれないことがあるため、
        // 一度だけ発火するガード付きでタイムアウトを設ける。
        let lock = NSLock()
        var didComplete = false
        func completeOnce(_ data: Data?, _ mimeType: String?, _ width: Int, _ height: Int, _ error: String?) {
            lock.lock()
            let already = didComplete
            didComplete = true
            lock.unlock()
            guard !already else { return }
            completion(data, mimeType, width, height, error)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + imageFetchTimeout) { [imageFetchTimeout] in
            completeOnce(nil, nil, 0, 0, "画像取得がタイムアウトしました（\(Int(imageFetchTimeout))秒）")
        }

        imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            guard let image = image else {
                let isCloudError = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                let message = isCloudError
                    ? "iCloudからのダウンロードに失敗、またはタイムアウトしました"
                    : "画像の取得に失敗しました"
                completeOnce(nil, nil, 0, 0, message)
                return
            }
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            else {
                completeOnce(nil, nil, 0, 0, "JPEGへの変換に失敗しました")
                return
            }
            completeOnce(jpegData, "image/jpeg", Int(image.size.width), Int(image.size.height), nil)
        }
    }

    // MARK: - searchPhotos

    /// search_photos の返却件数の上限（暴走防止）
    private let searchLimit = 200

    /// 写真を検索する（条件はすべて省略可・AND条件）。
    ///
    /// - keyword あり: Photos.app 内蔵の検索（画像認識インデックス）でIDを絞り込み、
    ///   日付条件と組み合わせる（`PhotosAppSearch` 参照。2026-09-28追加）。
    ///   Photos.app 検索が使えない場合（オートメーション未許可など）は、従来の
    ///   「撮影日文字列への部分一致」にフォールバックし、理由を `warning` に入れる。
    /// - keyword なし: 日付条件のみで撮影日の新しい順に返す。
    ///
    /// レスポンスの追加キー:
    ///   searchMode = "none" | "photos_app" | "date_string_fallback"
    ///   total      = 条件に合った件数（photos は最大 searchLimit 件に切り詰める）
    ///   warning    = フォールバックした理由（フォールバック時のみ）
    func searchPhotos(
        keyword: String?,
        dateFrom: Date?,
        dateTo: Date?,
        location: String?,
        completion: @escaping (Result<[String: Any], String>) -> Void
    ) {
        guard isAuthorized else {
            completion(.failure("Photos access not authorized"))
            return
        }
        // location は未実装（将来の拡張用）。

        let trimmed = keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            var result = fetchPhotoEntries(identifiers: nil, dateFrom: dateFrom, dateTo: dateTo)
            result["searchMode"] = "none"
            completion(.success(result))
            return
        }

        PhotosAppSearch.search(keyword: trimmed) { [self] searchResult in
            switch searchResult {
            case .success(let ids):
                var result = fetchPhotoEntries(identifiers: ids, dateFrom: dateFrom, dateTo: dateTo)
                result["searchMode"] = "photos_app"
                completion(.success(result))

            case .failure(let message):
                // 従来動作: 新しい順 searchLimit 件のうち、撮影日文字列にkeywordを含むもの
                var result = fetchPhotoEntries(identifiers: nil, dateFrom: dateFrom, dateTo: dateTo)
                let photos = (result["photos"] as? [[String: Any]] ?? []).filter { entry in
                    (entry["createdAt"] as? String)?.localizedCaseInsensitiveContains(trimmed) ?? false
                }
                result["photos"] = photos
                result["total"] = photos.count
                result["searchMode"] = "date_string_fallback"
                result["warning"] = message
                completion(.success(result))
            }
        }
    }

    /// 日付条件で写真（静止画のみ）を取得し、撮影日の新しい順に最大 searchLimit 件を返す。
    /// identifiers を渡した場合はそのIDに限定する（空配列なら0件）。
    private func fetchPhotoEntries(
        identifiers: [String]?,
        dateFrom: Date?,
        dateTo: Date?
    ) -> [String: Any] {
        if let identifiers = identifiers, identifiers.isEmpty {
            return ["photos": [], "total": 0]
        }

        let options = PHFetchOptions()
        var predicates: [NSPredicate] = [
            NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        ]
        if let dateFrom = dateFrom {
            predicates.append(NSPredicate(format: "creationDate >= %@", dateFrom as NSDate))
        }
        if let dateTo = dateTo {
            predicates.append(NSPredicate(format: "creationDate <= %@", dateTo as NSDate))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let fetchResult: PHFetchResult<PHAsset>
        if let identifiers = identifiers {
            fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: options)
        } else {
            options.fetchLimit = searchLimit
            fetchResult = PHAsset.fetchAssets(with: .image, options: options)
        }

        var photos: [[String: Any]] = []
        let formatter = ISO8601DateFormatter()
        let limit = searchLimit
        fetchResult.enumerateObjects { asset, index, stop in
            if index >= limit {
                stop.pointee = true
                return
            }
            var entry: [String: Any] = [
                "id": asset.localIdentifier,
                "width": asset.pixelWidth,
                "height": asset.pixelHeight
            ]
            if let date = asset.creationDate {
                entry["createdAt"] = formatter.string(from: date)
            }
            photos.append(entry)
        }

        return ["photos": photos, "total": fetchResult.count]
    }

    // MARK: - listPhotosInAlbum

    func listPhotosInAlbum(albumId: String) -> Result<[String: Any], String> {
        guard isAuthorized else { return .failure("Photos access not authorized") }

        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumId], options: nil)
        guard let collection = collections.firstObject else {
            return .failure("Album not found: \(albumId)")
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 500 // 暴走防止の上限（アルバム内容の一覧表示なのでsearch_photosより広め）

        let fetchResult = PHAsset.fetchAssets(in: collection, options: options)
        var photos: [[String: Any]] = []
        let formatter = ISO8601DateFormatter()

        fetchResult.enumerateObjects { asset, _, _ in
            var entry: [String: Any] = [
                "id": asset.localIdentifier,
                "width": asset.pixelWidth,
                "height": asset.pixelHeight
            ]
            if let date = asset.creationDate {
                entry["createdAt"] = formatter.string(from: date)
            }
            photos.append(entry)
        }

        return .success(["photos": photos])
    }

    // MARK: - getMetadata

    /// 指定IDの写真のメタデータを取得する。
    /// カメラ機種情報は PHContentEditingInput 経由でオリジナルファイルURLを取得し、
    /// ImageIO で EXIF/TIFF の Make/Model を読み取る（非同期・ネットワークアクセス許可あり = iCloud上の写真も対象）。
    func getMetadata(id: String, completion: @escaping ([String: Any]?, String?) -> Void) {
        guard isAuthorized else {
            completion(nil, "Photos access not authorized")
            return
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetchResult.firstObject else {
            completion(nil, "Asset not found: \(id)")
            return
        }

        var meta: [String: Any] = [
            "pixelWidth": asset.pixelWidth,
            "pixelHeight": asset.pixelHeight,
            "isFavorite": asset.isFavorite
        ]
        if let date = asset.creationDate {
            meta["createdAt"] = ISO8601DateFormatter().string(from: date)
        }
        if let location = asset.location {
            meta["latitude"] = location.coordinate.latitude
            meta["longitude"] = location.coordinate.longitude
        }

        let editOptions = PHContentEditingInputRequestOptions()
        editOptions.isNetworkAccessAllowed = true

        // requestContentEditingInputのcompletionもiCloudダウンロード待ちで呼ばれないことがあるため、
        // getPhoto同様に一度だけ発火するガード付きタイムアウトを設ける。
        let lock = NSLock()
        var didComplete = false
        func completeOnce() {
            lock.lock()
            let already = didComplete
            didComplete = true
            lock.unlock()
            guard !already else { return }
            completion(meta, nil)
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + imageFetchTimeout) {
            // タイムアウトした場合もcameraMake/cameraModel以外の基本メタデータは返す。
            completeOnce()
        }

        asset.requestContentEditingInput(with: editOptions) { input, _ in
            if let url = input?.fullSizeImageURL,
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                if let make = tiff[kCGImagePropertyTIFFMake] as? String {
                    meta["cameraMake"] = make
                }
                if let model = tiff[kCGImagePropertyTIFFModel] as? String {
                    meta["cameraModel"] = model
                }
            }
            // 取得できない場合（RAW以外の一部形式・アクセス失敗等）はcameraMake/cameraModelを省略し、
            // 他のメタデータのみで成功として返す。
            completeOnce()
        }
    }
}

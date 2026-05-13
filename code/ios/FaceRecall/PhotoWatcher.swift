import Foundation
import Photos
import UIKit

@MainActor
final class PhotoWatcher: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var photoAuthorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var isProcessing = false
    @Published var lastResult: RecognitionResponse?
    @Published var lastScannedImageData: Data?
    @Published var pendingUnknownImageData: Data?
    @Published var events: [AppEvent] = []

    private let apiClient = APIClient()
    private var isObserving = false
    private var recentImageFetchResult: PHFetchResult<PHAsset>?
    private var pendingInsertedPhotoIDs: [String] = []

    deinit {
        if isObserving {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    func requestPermission() async {
        photoAuthorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        startObservingIfAllowed()
    }

    func startObservingIfAllowed() {
        guard photoAuthorizationStatus == .authorized || photoAuthorizationStatus == .limited else {
            return
        }
        guard !isObserving else {
            return
        }
        recentImageFetchResult = fetchRecentImageAssets()
        PHPhotoLibrary.shared().register(self)
        isObserving = true
        appendEvent(title: "Photos observer active", detail: "Watching for changes while the app is running.")
    }

    func scanLatestPhoto(baseURL: String, notifications: NotificationManager) async {
        guard photoAuthorizationStatus == .authorized || photoAuthorizationStatus == .limited else {
            appendEvent(title: "Photos permission needed", detail: "Grant Photos access before scanning.")
            return
        }
        guard !isProcessing else {
            return
        }
        isProcessing = true
        defer { isProcessing = false }

        do {
            guard let asset = newestUnprocessedImageAsset() else {
                appendEvent(title: "No new photo", detail: "All recent photos have already been processed.")
                return
            }

            let imageData = try await jpegData(for: asset)
            lastScannedImageData = imageData
            let response = try await apiClient.recognize(imageData: imageData, baseURL: baseURL)
            markProcessed(asset)
            lastResult = response
            appendEvent(title: "Scanned photo", detail: photoDetail(for: asset))

            switch response.status {
            case .recognized:
                pendingUnknownImageData = nil
                if let person = response.person {
                    appendEvent(title: "Recognized \(person.name)", detail: "Distance: \(formattedDistance(response.distance))")
                    notifications.notifyRecognized(person: person)
                }
            case .unknown:
                pendingUnknownImageData = imageData
                appendEvent(title: "Unknown person", detail: "Tap notification or Create Person to enroll.")
                notifications.notifyUnknown()
            }
        } catch {
            appendEvent(title: "Scan failed", detail: error.localizedDescription)
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            if let recentImageFetchResult,
               let changeDetails = changeInstance.changeDetails(for: recentImageFetchResult) {
                self.recentImageFetchResult = changeDetails.fetchResultAfterChanges
                let insertedIDs = changeDetails.insertedObjects.map(\.localIdentifier)
                if !insertedIDs.isEmpty {
                    pendingInsertedPhotoIDs.append(contentsOf: insertedIDs)
                    pendingInsertedPhotoIDs = Array(NSOrderedSet(array: pendingInsertedPhotoIDs).compactMap { $0 as? String })
                    appendEvent(
                        title: "New photo detected",
                        detail: "\(insertedIDs.count) new photo(s) queued from Photos."
                    )
                    return
                }
            } else {
                recentImageFetchResult = fetchRecentImageAssets()
            }

            appendEvent(title: "Photos changed", detail: "Tap Scan Latest Photo to process the latest visible image.")
        }
    }

    func clearPendingUnknown() {
        pendingUnknownImageData = nil
    }

    private func newestUnprocessedImageAsset() -> PHAsset? {
        let processedIDs = Set(UserDefaults.standard.stringArray(forKey: "processedPhotoIDs") ?? [])

        while !pendingInsertedPhotoIDs.isEmpty {
            let assetID = pendingInsertedPhotoIDs.removeLast()
            if processedIDs.contains(assetID) {
                continue
            }
            if let asset = fetchAsset(id: assetID) {
                return asset
            }
        }

        let assets = fetchRecentImageAssets()
        recentImageFetchResult = assets
        return assets.objects()
            .filter { !processedIDs.contains($0.localIdentifier) }
            .sorted { newestDate(for: $0) > newestDate(for: $1) }
            .first
    }

    private func fetchRecentImageAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 50

        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumRecentlyAdded,
            options: nil
        )

        if let recentlyAdded = collections.firstObject {
            return PHAsset.fetchAssets(in: recentlyAdded, options: options)
        }

        options.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    private func fetchAsset(id: String) -> PHAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        return assets.firstObject
    }

    private func jpegData(for asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = image?.jpegData(compressionQuality: 0.86) else {
                    continuation.resume(throwing: PhotoWatcherError.imageConversionFailed)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func markProcessed(_ asset: PHAsset) {
        var ids = UserDefaults.standard.stringArray(forKey: "processedPhotoIDs") ?? []
        ids.append(asset.localIdentifier)
        UserDefaults.standard.set(Array(ids.suffix(500)), forKey: "processedPhotoIDs")
    }

    private func newestDate(for asset: PHAsset) -> Date {
        asset.modificationDate ?? asset.creationDate ?? .distantPast
    }

    private func photoDetail(for asset: PHAsset) -> String {
        let created = asset.creationDate.map { Self.dateFormatter.string(from: $0) } ?? "unknown"
        let modified = asset.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "unknown"
        return "Created: \(created). Modified: \(modified)."
    }

    private func appendEvent(title: String, detail: String) {
        events.insert(AppEvent(title: title, detail: detail), at: 0)
        events = Array(events.prefix(20))
    }

    private func formattedDistance(_ distance: Double?) -> String {
        guard let distance else {
            return "n/a"
        }
        return String(format: "%.3f", distance)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

private extension PHFetchResult where ObjectType == PHAsset {
    func objects() -> [PHAsset] {
        var assets: [PHAsset] = []
        enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }
}

enum PhotoWatcherError: Error, LocalizedError {
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            return "Could not convert the Photos asset to JPEG."
        }
    }
}

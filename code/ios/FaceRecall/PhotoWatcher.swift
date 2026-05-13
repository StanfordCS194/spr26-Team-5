import Foundation
import Photos
import UIKit

@MainActor
final class PhotoWatcher: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var photoAuthorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var isProcessing = false
    @Published var lastResult: RecognitionResponse?
    @Published var pendingUnknownImageData: Data?
    @Published var events: [AppEvent] = []

    private let apiClient = APIClient()
    private var isObserving = false

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
            let response = try await apiClient.recognize(imageData: imageData, baseURL: baseURL)
            markProcessed(asset)
            lastResult = response

            switch response.status {
            case .recognized:
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
            appendEvent(title: "Photos changed", detail: "Open the app and tap Scan Latest Photo to process deterministically.")
        }
    }

    func clearPendingUnknown() {
        pendingUnknownImageData = nil
    }

    private func newestUnprocessedImageAsset() -> PHAsset? {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 25

        let processedIDs = Set(UserDefaults.standard.stringArray(forKey: "processedPhotoIDs") ?? [])
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var result: PHAsset?
        assets.enumerateObjects { asset, _, stop in
            if !processedIDs.contains(asset.localIdentifier) {
                result = asset
                stop.pointee = true
            }
        }
        return result
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

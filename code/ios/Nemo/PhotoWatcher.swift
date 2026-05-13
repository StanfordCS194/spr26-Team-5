import Foundation
import Photos
import UIKit

@MainActor
final class PhotoWatcher: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var photoAuthorizationStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var isProcessing = false
    @Published var hasNewPhoto = false
    @Published var lastResult: RecognitionResponse?
    @Published var lastScannedImageData: Data?
    @Published var pendingUnknownImageData: Data?
    @Published var lastScanMessage: String?
    @Published var scanIssue: ScanIssue?
    @Published var pendingPhotoIdentifier: String?
    @Published var recognitionRuns: [RecognitionRun] = []

    private let apiClient = APIClient()
    private var isObserving = false
    private var recentImageFetchResult: PHFetchResult<PHAsset>?
    private var latestInsertedPhotoID: String?
    private var knownRecentPhotoIDs = Set<String>()

    override init() {
        recognitionRuns = Self.loadRecognitionRuns()
        UserDefaults.standard.removeObject(forKey: Self.legacyRecognitionRunsStorageKey)
        super.init()
    }

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
        knownRecentPhotoIDs = Set(recentImageFetchResult?.objects().map(\.localIdentifier) ?? [])
        refreshForRecentUnprocessedPhoto()
        PHPhotoLibrary.shared().register(self)
        isObserving = true
    }

    func refreshForPhotoChanges() {
        guard photoAuthorizationStatus == .authorized || photoAuthorizationStatus == .limited else {
            return
        }

        let assets = fetchRecentImageAssets()
        recentImageFetchResult = assets

        let currentAssets = assets.objects()
        let currentIDs = Set(currentAssets.map(\.localIdentifier))
        let processedIDs = Set(UserDefaults.standard.stringArray(forKey: "processedPhotoIDs") ?? [])

        let newAssets = currentAssets
            .filter { !knownRecentPhotoIDs.contains($0.localIdentifier) }
            .filter { !processedIDs.contains($0.localIdentifier) }
            .sorted { newestDate(for: $0) > newestDate(for: $1) }

        knownRecentPhotoIDs = currentIDs

        if let latest = newAssets.first {
            setNewPhoto(latest)
            return
        }

        if latestInsertedPhotoID == nil {
            refreshForRecentUnprocessedPhoto()
        }
    }

    func scanLatestPhoto(baseURL: String, notifications: NotificationManager) async {
        guard photoAuthorizationStatus == .authorized || photoAuthorizationStatus == .limited else {
            scanIssue = .failed("Grant Photos access before scanning.")
            return
        }
        guard !isProcessing else {
            return
        }
        isProcessing = true
        defer { isProcessing = false }

        do {
            guard let asset = newestUnprocessedImageAsset() else {
                hasNewPhoto = false
                latestInsertedPhotoID = nil
                scanIssue = nil
                lastScanMessage = nil
                return
            }

            let imageData = try await jpegData(
                for: asset,
                targetSize: Self.scanImageTargetSize,
                compressionQuality: 0.84
            )
            let thumbnailData = try await jpegData(
                for: asset,
                targetSize: Self.historyThumbnailTargetSize,
                compressionQuality: 0.72
            )
            lastScannedImageData = thumbnailData
            let response: RecognitionResponse
            do {
                response = try await apiClient.recognize(imageData: imageData, baseURL: baseURL)
            } catch let error as APIClientError where error.statusCode == 400 && error.message.localizedCaseInsensitiveContains("No face detected") {
                markProcessed(asset)
                hasNewPhoto = false
                latestInsertedPhotoID = nil
                pendingPhotoIdentifier = nil
                lastResult = nil
                pendingUnknownImageData = nil
                lastScanMessage = nil
                scanIssue = .noFaceDetected
                return
            }

            markProcessed(asset)
            lastResult = response
            hasNewPhoto = false
            latestInsertedPhotoID = nil
            pendingPhotoIdentifier = nil
            scanIssue = nil
            lastScanMessage = scanSummary(for: response)
            recognitionRuns.insert(
                RecognitionRun(
                    thumbnailData: thumbnailData,
                    result: response,
                    photoCreatedAt: asset.creationDate,
                    photoModifiedAt: asset.modificationDate
                ),
                at: 0
            )
            recognitionRuns = Array(recognitionRuns.prefix(50))
            saveRecognitionRuns()

            switch response.status {
            case .recognized:
                pendingUnknownImageData = nil
                if let person = response.person {
                    notifications.notifyRecognized(person: person)
                }
            case .unknown:
                pendingUnknownImageData = imageData
                notifications.notifyUnknown()
            }
        } catch {
            scanIssue = .failed(error.localizedDescription)
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            if let recentImageFetchResult,
               let changeDetails = changeInstance.changeDetails(for: recentImageFetchResult) {
                self.recentImageFetchResult = changeDetails.fetchResultAfterChanges
                if let latest = changeDetails.insertedObjects
                    .filter({ isRecentEnough($0) })
                    .sorted(by: { newestDate(for: $0) > newestDate(for: $1) })
                    .first {
                    knownRecentPhotoIDs.insert(latest.localIdentifier)
                    setNewPhoto(latest)
                    return
                }

                let processedIDs = Set(UserDefaults.standard.stringArray(forKey: "processedPhotoIDs") ?? [])
                if let latest = changeDetails.changedObjects
                    .filter({ !processedIDs.contains($0.localIdentifier) })
                    .sorted(by: { newestDate(for: $0) > newestDate(for: $1) })
                    .first,
                   isRecentEnough(latest) {
                    knownRecentPhotoIDs.insert(latest.localIdentifier)
                    setNewPhoto(latest)
                }
            } else {
                recentImageFetchResult = fetchRecentImageAssets()
                knownRecentPhotoIDs = Set(recentImageFetchResult?.objects().map(\.localIdentifier) ?? [])
            }
        }
    }

    func clearPendingUnknown() {
        pendingUnknownImageData = nil
    }

    func deleteRecognitionRun(id: UUID) {
        recognitionRuns.removeAll { $0.id == id }
        saveRecognitionRuns()
    }

    func deleteAllRecognitionRuns() {
        recognitionRuns = []
        saveRecognitionRuns()
    }

    func updatePersonInHistory(_ person: Person) {
        var didChange = false
        recognitionRuns = recognitionRuns.map { run in
            guard run.result.person?.id == person.id else {
                return run
            }
            didChange = true
            return run.replacingPerson(person)
        }

        if lastResult?.person?.id == person.id {
            lastResult = lastResult?.replacingPerson(person)
        }

        if didChange {
            saveRecognitionRuns()
        }
    }

    func removePersonFromHistory(personID: String) {
        var didChange = false
        recognitionRuns = recognitionRuns.map { run in
            guard run.result.person?.id == personID else {
                return run
            }
            didChange = true
            return run.removingPerson()
        }

        if lastResult?.person?.id == personID {
            lastResult = lastResult?.removingPerson()
        }

        if didChange {
            saveRecognitionRuns()
        }
    }

    func syncHistory(with people: [Person]) {
        let peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        var didChange = false

        recognitionRuns = recognitionRuns.map { run in
            guard let personID = run.result.person?.id else {
                return run
            }
            if let person = peopleByID[personID] {
                if run.result.person != person {
                    didChange = true
                    return run.replacingPerson(person)
                }
                return run
            }

            didChange = true
            return run.removingPerson()
        }

        if let personID = lastResult?.person?.id {
            if let person = peopleByID[personID] {
                if lastResult?.person != person {
                    lastResult = lastResult?.replacingPerson(person)
                }
            } else {
                lastResult = lastResult?.removingPerson()
            }
        }

        if didChange {
            saveRecognitionRuns()
        }
    }

    private func newestUnprocessedImageAsset() -> PHAsset? {
        let processedIDs = Set(UserDefaults.standard.stringArray(forKey: "processedPhotoIDs") ?? [])

        if let latestInsertedPhotoID,
           !processedIDs.contains(latestInsertedPhotoID),
           let asset = fetchAsset(id: latestInsertedPhotoID) {
                return asset
        }

        return nil
    }

    private func fetchRecentImageAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [
            NSSortDescriptor(key: "modificationDate", ascending: false),
            NSSortDescriptor(key: "creationDate", ascending: false),
        ]
        options.fetchLimit = 50

        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumRecentlyAdded,
            options: nil
        )

        if let recentlyAdded = collections.firstObject {
            return PHAsset.fetchAssets(in: recentlyAdded, options: options)
        }

        return PHAsset.fetchAssets(with: .image, options: options)
    }

    private func fetchAsset(id: String) -> PHAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        return assets.firstObject
    }

    private func jpegData(for asset: PHAsset, targetSize: CGSize, compressionQuality: CGFloat) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.resizeMode = .fast

            var didResume = false

            func resumeOnce(_ result: Result<Data, Error>) {
                guard !didResume else {
                    return
                }
                didResume = true
                switch result {
                case let .success(data):
                    continuation.resume(returning: data)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool, isDegraded {
                    return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    resumeOnce(.failure(error))
                    return
                }
                guard let data = image?.jpegData(compressionQuality: compressionQuality) else {
                    resumeOnce(.failure(PhotoWatcherError.imageConversionFailed))
                    return
                }
                resumeOnce(.success(data))
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

    private func setNewPhoto(_ asset: PHAsset) {
        latestInsertedPhotoID = asset.localIdentifier
        pendingPhotoIdentifier = asset.localIdentifier
        hasNewPhoto = true
        lastScanMessage = nil
        scanIssue = nil
    }

    private func refreshForRecentUnprocessedPhoto() {
        let processedIDs = Set(UserDefaults.standard.stringArray(forKey: "processedPhotoIDs") ?? [])
        let latest = fetchRecentImageAssets()
            .objects()
            .filter { !processedIDs.contains($0.localIdentifier) }
            .filter { isRecentEnough($0) }
            .sorted { newestDate(for: $0) > newestDate(for: $1) }
            .first

        if let latest {
            setNewPhoto(latest)
        }
    }

    private func isRecentEnough(_ asset: PHAsset) -> Bool {
        let candidateDate = asset.creationDate ?? asset.modificationDate ?? .distantPast
        return Date().timeIntervalSince(candidateDate) <= Self.newPhotoWindowSeconds
    }

    private func formattedDistance(_ distance: Double?) -> String {
        guard let distance else {
            return "n/a"
        }
        return String(format: "%.3f", distance)
    }

    private func scanSummary(for response: RecognitionResponse) -> String {
        switch response.status {
        case .recognized:
            guard let person = response.person else {
                return "Recognized a saved person."
            }
            return "Recognized \(person.name). Distance: \(formattedDistance(response.distance))."
        case .unknown:
            return "Unknown person. Create a profile to save this face."
        }
    }

    private func saveRecognitionRuns() {
        guard let data = try? JSONEncoder().encode(recognitionRuns) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.recognitionRunsStorageKey)
    }

    private static func loadRecognitionRuns() -> [RecognitionRun] {
        guard let data = UserDefaults.standard.data(forKey: recognitionRunsStorageKey),
              let runs = try? JSONDecoder().decode([RecognitionRun].self, from: data) else {
            return []
        }
        return Array(runs.prefix(50))
    }

    private static let newPhotoWindowSeconds: TimeInterval = 60 * 60 * 12
    private static let scanImageTargetSize = CGSize(width: 1600, height: 1600)
    private static let historyThumbnailTargetSize = CGSize(width: 360, height: 360)
    private static let recognitionRunsStorageKey = "recognitionRuns.v2"
    private static let legacyRecognitionRunsStorageKey = "recognitionRuns"
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

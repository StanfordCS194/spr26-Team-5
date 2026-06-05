import SwiftUI
import UIKit
import Photos
import UserNotifications
import AVFoundation

private enum AppExperience: String {
    case patient
    case caregiver

    var title: String {
        switch self {
        case .patient:
            return "Patient"
        case .caregiver:
            return "Caregiver"
        }
    }

    var subtitle: String {
        switch self {
        case .patient:
            return "Simple recognition, large text, and calm guidance."
        case .caregiver:
            return "Manage people, memories, recognition history, and settings."
        }
    }

    var systemImage: String {
        switch self {
        case .patient:
            return "figure.roll"
        case .caregiver:
            return "person.crop.circle.badge.checkmark"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var notifications: NotificationManager
    @EnvironmentObject private var speechManager: SpeechManager
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var photoWatcher = PhotoWatcher()
    @AppStorage("backendURL") private var backendURL = "http://127.0.0.1:8000"
    @AppStorage("ttsEnabled") private var ttsEnabled = true
    @AppStorage("patientMode") private var patientMode = false

    @State private var selectedTab = 0
    @State private var selectedPersonID: String?
    @State private var showingCreatePerson = false
    @State private var healthStatus = "Not checked"
    @State private var isCheckingHealth = false
    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var selectedExperience: AppExperience?
    @State private var caregiverAccessGranted = false

    private let apiClient = APIClient()
    private let caregiverPIN = "1234"

    var body: some View {
        TabView(selection: $selectedTab) {
            Group {
                if patientMode {
                    PatientModeView(
                        photoWatcher: photoWatcher,
                        backendURL: backendURL,
                        notifications: notifications,
                        onRetry: {
                            Task {
                                await photoWatcher.retryLatestPhoto(
                                    baseURL: backendURL,
                                    notifications: notifications
                                )
                            }
                        }
                    )
                } else {
                    RecognitionTabView(
                        photoWatcher: photoWatcher,
                        backendURL: backendURL,
                        showingCreatePerson: $showingCreatePerson,
                        notifications: notifications,
                        onRetry: {
                            Task {
                                await photoWatcher.retryLatestPhoto(
                                    baseURL: backendURL,
                                    notifications: notifications
                                )
                            }
                        },
                        onOpenSettings: {
                            selectedTab = 2
                        }
                    )
                }
            }
            .tabItem {
                Label("Recognize", systemImage: "camera.viewfinder")
            }
            .tag(0)

                            HistoryTabView(
                                backendURL: backendURL,
                                runs: photoWatcher.recognitionRuns,
                                onPersonUpdated: { person in
                                    photoWatcher.updatePersonInHistory(person)
                                },
                                onPersonDeleted: { personID in
                                    photoWatcher.removePersonFromHistory(personID: personID)
                                },
                                onDatabaseLoaded: { people in
                                    photoWatcher.syncHistory(with: people)
                                },
                                onDeleteRun: { runID in
                                    photoWatcher.deleteRecognitionRun(id: runID)
                                },
                                onDeleteAllRuns: {
                                    photoWatcher.deleteAllRecognitionRuns()
                                }
                            )
                            .tabItem {
                                Label("History", systemImage: "clock")
                            }
                            .tag(1)

            SettingsTabView(
                backendURL: $backendURL,
                ttsEnabled: $ttsEnabled,
                patientMode: $patientMode,
                photoAuthorizationStatus: photoWatcher.photoAuthorizationStatus,
                cameraAuthorizationStatus: cameraAuthorizationStatus,
                notificationAuthorizationStatus: notifications.authorizationStatus,
                healthStatus: healthStatus,
                isCheckingHealth: isCheckingHealth,
                requestPhotos: {
                    Task {
                        await photoWatcher.requestPermission()
                    }
                },
                requestCamera: {
                    Task {
                        await requestCameraPermission()
                    }
                },
                requestNotifications: {
                    Task {
                        await notifications.requestPermission()
                    }
                },
                checkHealth: {
                    Task {
                        await checkHealth()
                    }
                }
            )
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(2)
        }
        .sheet(isPresented: $showingCreatePerson) {
            CreatePersonView(
                backendURL: backendURL,
                imageData: photoWatcher.pendingUnknownImageData,
                onCreated: { person in
                    photoWatcher.clearPendingUnknown()
                    selectedPersonID = person.id
                    selectedTab = 1
                }
            )
        }
        .onAppear {
            photoWatcher.startObservingIfAllowed()
            photoWatcher.onRecognitionResult = { response in
                guard ttsEnabled else { return }
                speechManager.speak(Self.speechText(for: response))
            }
            Task {
                await autoScanIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                photoWatcher.startObservingIfAllowed()
                photoWatcher.refreshForPhotoChanges()
                cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                photoWatcher.onRecognitionResult = { response in
                    guard ttsEnabled else { return }
                    speechManager.speak(Self.speechText(for: response))
                }
                Task {
                    await autoScanIfNeeded()
                }
            }
        }
        .onChange(of: photoWatcher.pendingPhotoIdentifier) { _, identifier in
            guard identifier != nil else {
                return
            }
            Task {
                await autoScanIfNeeded()
            }
        }
        .onChange(of: notifications.route) { _, route in
            guard let route else {
                return
            }
            switch route {
            case let .person(personID):
                if selectedExperience == .caregiver || selectedExperience == .patient {
                    selectedPersonID = personID
                    selectedTab = 1
                }
            case .createPerson:
                if selectedExperience == .caregiver {
                    selectedTab = 0
                    showingCreatePerson = true
                }
            }
            notifications.route = nil
        }
    }

    private func checkHealth() async {
        isCheckingHealth = true
        defer { isCheckingHealth = false }

        do {
            let response = try await apiClient.health(baseURL: backendURL)
            healthStatus = "Online: \(response.status)"
        } catch {
            healthStatus = error.localizedDescription
        }
    }

    private func requestCameraPermission() async {
        if cameraAuthorizationStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }

        cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }

    private func autoScanIfNeeded() async {
        guard photoWatcher.pendingPhotoIdentifier != nil, !photoWatcher.isProcessing else {
            return
        }
        await photoWatcher.scanLatestPhoto(baseURL: backendURL, notifications: notifications)
    }

    private static func speechText(for response: RecognitionResponse) -> String {
        switch response.status {
        case .recognized:
            guard let person = response.person else { return "Person recognized." }
            return person.description.isEmpty ? "This is \(person.name)." : "This is \(person.name). \(person.description)"
        case .unknown:
            return "Unknown person detected."
        }
    }
}

private struct CaregiverAccessView: View {
    let expectedPIN: String
    let onAuthenticated: () -> Void
    let onBack: () -> Void

    @State private var pin = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemGroupedBackground), Color.green.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 24) {
                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Caregiver Access")
                            .font(.system(size: 34, weight: .bold))
                        Text("Enter the caregiver PIN to open admin tools.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SecureField("PIN", text: $pin)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16))

                        Text("Demo PIN: \(expectedPIN)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    Button(action: submit) {
                        Label("Continue", systemImage: "lock.open")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
                .padding(24)
            }
            .navigationBarHidden(true)
        }
    }

    private func submit() {
        if pin == expectedPIN {
            errorMessage = nil
            onAuthenticated()
        } else {
            errorMessage = "Incorrect PIN. Try again."
        }
    }
}

private struct ExperienceSelectionView: View {
    let onSelect: (AppExperience) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemGroupedBackground), Color.blue.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 28) {
                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Welcome to Nemo")
                            .font(.system(size: 36, weight: .bold))
                        Text("Choose the experience you want to open.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 18) {
                        ForEach([AppExperience.patient, .caregiver], id: \.rawValue) { experience in
                            Button {
                                onSelect(experience)
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: experience.systemImage)
                                        .font(.system(size: 28, weight: .semibold))
                                        .frame(width: 56, height: 56)
                                        .background(Color.accentColor.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 16))

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(experience.title)
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(experience.subtitle)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(20)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemGroupedBackground))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("You can switch experiences again later from Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(24)
            }
            .navigationBarHidden(true)
        }
    }
}

private struct RecognitionTabView: View {
    @ObservedObject var photoWatcher: PhotoWatcher
    let backendURL: String
    @Binding var showingCreatePerson: Bool
    let notifications: NotificationManager
    let onRetry: () -> Void
    let onOpenSettings: () -> Void
    @State private var showingCamera = false
    @State private var cameraMessage: String?
    @State private var showingChangePerson = false
    @State private var correctionMessage: String?
    @State private var isChangingPerson = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    CameraCaptureStatusView(
                        message: cameraMessage,
                        isProcessing: photoWatcher.isProcessing,
                        onTakePhoto: presentCamera
                    )

                    NewPhotoStatusView(
                        hasNewPhoto: photoWatcher.hasNewPhoto,
                        isProcessing: photoWatcher.isProcessing,
                        lastScanDate: photoWatcher.lastCompletedScanAt
                    )

                    if let imageData = photoWatcher.lastScannedImageData {
                        PhotoPreview(imageData: imageData)
                    }

                    if let issue = photoWatcher.scanIssue {
                        ScanIssueView(
                            issue: issue,
                            onRetry: onRetry,
                            onOpenSettings: onOpenSettings
                        )
                    }

                    if let result = photoWatcher.lastResult {
                        RecognitionResultView(
                            backendURL: backendURL,
                            result: result,
                            isChangingPerson: isChangingPerson,
                            onChangePerson: result.status == .recognized ? {
                                showingChangePerson = true
                            } : nil
                        )
                        if let correctionMessage {
                            Text(correctionMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if result.status == .unknown {
                            UnknownRecognitionView(
                                onRetry: onRetry,
                                onRetake: presentCamera,
                                isProcessing: photoWatcher.isProcessing,
                                showingCreatePerson: $showingCreatePerson
                            )
                        }
                    } else if photoWatcher.scanIssue == nil {
                        EmptyRecognitionView()
                    }

                    if let message = photoWatcher.lastScanMessage {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if photoWatcher.pendingUnknownImageData != nil && photoWatcher.lastResult?.status != .unknown {
                        Button {
                            showingCreatePerson = true
                        } label: {
                            Label("Create Person From Unknown", systemImage: "person.crop.circle.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    if photoWatcher.scanIssue == nil,
                       photoWatcher.lastResult?.status != .unknown,
                       photoWatcher.lastScanSupportsPhotoRetry,
                       (photoWatcher.lastScannedImageData != nil || photoWatcher.lastResult != nil) {
                        Button(action: onRetry) {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(photoWatcher.isProcessing)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Recognition")
            .sheet(isPresented: $showingCamera) {
                CameraCaptureView(
                    onCapture: { imageData in
                        showingCamera = false
                        cameraMessage = nil
                        Task {
                            await photoWatcher.scanCapturedImage(
                                imageData: imageData,
                                baseURL: backendURL,
                                notifications: notifications
                            )
                        }
                    },
                    onCancel: {
                        showingCamera = false
                    },
                    onError: { error in
                        cameraMessage = error.localizedDescription
                        showingCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingChangePerson) {
                ChangeRecognizedPersonView(
                    backendURL: backendURL,
                    currentPersonID: photoWatcher.lastResult?.person?.id,
                    recognitionImageData: photoWatcher.lastScannedRecognitionImageData,
                    isSaving: isChangingPerson,
                    onSelect: { person in
                        Task {
                            await changeRecognition(to: person)
                        }
                    },
                    onCreatePerson: { person in
                        Task {
                            await changeRecognitionToCreatedPerson(person)
                        }
                    }
                )
            }
        }
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraMessage = CameraCaptureError.unavailable.localizedDescription
            return
        }

        showingCamera = true
    }

    private func changeRecognition(to person: Person) async {
        isChangingPerson = true
        correctionMessage = nil
        defer { isChangingPerson = false }

        do {
            try await photoWatcher.changeLastRecognition(to: person, baseURL: backendURL)
            showingChangePerson = false
        } catch {
            correctionMessage = error.localizedDescription
        }
    }

    private func changeRecognitionToCreatedPerson(_ person: Person) async {
        isChangingPerson = true
        correctionMessage = nil
        defer { isChangingPerson = false }

        do {
            try await photoWatcher.replaceLastRecognitionWithCreatedPerson(person, baseURL: backendURL)
            showingChangePerson = false
        } catch {
            correctionMessage = error.localizedDescription
        }
    }
}

private struct CameraCaptureStatusView: View {
    let message: String?
    let isProcessing: Bool
    let onTakePhoto: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if isProcessing {
                    ProgressView()
                } else {
                    Image(systemName: "camera")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Camera Capture")
                        .font(.headline)
                    Text(isProcessing ? "Nemo is sending the captured photo to the backend." : "Take a photo directly inside Nemo.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(action: onTakePhoto) {
                Label("Take Photo", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isProcessing)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct NewPhotoStatusView: View {
    let hasNewPhoto: Bool
    let isProcessing: Bool
    let lastScanDate: Date?

    private var icon: String {
        if isProcessing {
            return "waveform.path.ecg"
        }
        return hasNewPhoto ? "checkmark.circle.fill" : "photo"
    }

    private var title: String {
        if isProcessing {
            return "Scanning New Photo"
        }
        return hasNewPhoto ? "New Photo Ready" : "No New Photos"
    }

    private var subtitle: String {
        if isProcessing {
            return "Nemo is sending the newest photo to the backend."
        }
        return hasNewPhoto ? "A recent Photos change was detected and will scan automatically." : "Open Nemo, then take or import a photo to scan it."
    }

    private var tint: Color {
        if isProcessing {
            return .blue
        }
        return hasNewPhoto ? .green : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if isProcessing {
                    ProgressView()
                } else {
                    Image(systemName: icon)
                        .font(.title2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let lastScanDate {
                        Text("Last scan \(Self.timestampFormatter.localizedString(for: lastScanDate, relativeTo: Date()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(tint)
        .background(isProcessing ? Color.blue.opacity(0.12) : hasNewPhoto ? Color.green.opacity(0.14) : Color(.secondarySystemGroupedBackground))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isProcessing ? Color.blue.opacity(0.45) : hasNewPhoto ? Color.green.opacity(0.45) : Color(.separator), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static let timestampFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private struct ScanIssueView: View {
    let issue: ScanIssue
    let onRetry: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: issueIcon)
                    .font(.title3)
                    .foregroundStyle(issueTint)

                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.title)
                        .font(.headline)
                    Text(issue.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(issue.nextStep)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }

                Spacer()
            }

            HStack(spacing: 12) {
                Button(action: onRetry) {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if case .backendUnavailable = issue {
                    Button(action: onOpenSettings) {
                        Label("Open Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(issueTint.opacity(0.12))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(issueTint.opacity(0.35), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var issueIcon: String {
        switch issue {
        case .noFaceDetected:
            return "person.crop.rectangle.badge.xmark"
        case .backendUnavailable:
            return "wifi.exclamationmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var issueTint: Color {
        switch issue {
        case .noFaceDetected:
            return .orange
        case .backendUnavailable:
            return .red
        case .failed:
            return .orange
        }
    }
}

private struct PhotoPreview: View {
    let imageData: Data

    var body: some View {
        if let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 320)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Latest scanned photo")
        } else {
            Text("Could not display scanned photo.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct EmptyRecognitionView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.square")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Recognition Yet")
                .font(.headline)
            Text("Scan a new photo to see the face match here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct RecognitionResultView: View {
    let backendURL: String
    let result: RecognitionResponse
    let isChangingPerson: Bool
    let onChangePerson: (() -> Void)?

    var body: some View {
        if result.status == .recognized, let person = result.person {
            recognizedBody(person: person)
        } else {
            unknownBody
        }
    }

    private func recognizedBody(person: Person) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                PersonReferenceImageView(
                    personID: person.id,
                    backendURL: backendURL,
                    size: 96
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, .green)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(person.name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Spacer(minLength: 0)
                    }

                    if !person.relationship.isEmpty {
                        Label(person.relationship.capitalized, systemImage: "person.text.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    }

                    Text(person.description.isEmpty ? "No description saved." : person.description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Label("Recognized", systemImage: "person.fill.checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())

                Spacer()

                HStack(spacing: 8) {
                    Text("Faces \(result.faceCount)")
                    if let distance = result.distance {
                        Text("Distance \(String(format: "%.3f", distance))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let onChangePerson {
                Button(action: onChangePerson) {
                    if isChangingPerson {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Change Person", systemImage: "person.2")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isChangingPerson)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(0.28), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var unknownBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(result.status.rawValue.capitalized, systemImage: "questionmark.circle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                Text("Faces \(result.faceCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("No matching person found.")
                .foregroundStyle(.secondary)

            if let distance = result.distance {
                Text("Distance \(String(format: "%.3f", distance))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ChangeRecognizedPersonView: View {
    let backendURL: String
    let currentPersonID: String?
    let recognitionImageData: Data?
    let isSaving: Bool
    let onSelect: (Person) -> Void
    let onCreatePerson: (Person) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingCreatePerson = false

    private let apiClient = APIClient()

    private var selectablePeople: [Person] {
        people.filter { $0.id != currentPersonID }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView()
                }

                Section {
                    Button {
                        showingCreatePerson = true
                    } label: {
                        Label("Add New Person", systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(isSaving || recognitionImageData == nil)

                    if recognitionImageData == nil {
                        Text("No scanned photo is available for a new person.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("People") {
                    if selectablePeople.isEmpty && !isLoading {
                        Text("No other saved people.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectablePeople) { person in
                            Button {
                                onSelect(person)
                            } label: {
                                HStack(spacing: 12) {
                                    PersonReferenceImageView(
                                        personID: person.id,
                                        backendURL: backendURL,
                                        size: 48
                                    )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(person.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text(person.description.isEmpty ? "No description." : person.description)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(isSaving)
                        }
                    }
                }
            }
            .navigationTitle("Change Person")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            }
            .task {
                await loadPeople()
            }
            .sheet(isPresented: $showingCreatePerson) {
                CreatePersonView(
                    backendURL: backendURL,
                    imageData: recognitionImageData,
                    onCreated: onCreatePerson
                )
            }
        }
    }

    private func loadPeople() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            people = try await apiClient.people(baseURL: backendURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct UnknownRecognitionView: View {
    let onRetry: () -> Void
    let onRetake: () -> Void
    let isProcessing: Bool
    @Binding var showingCreatePerson: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unknown Person")
                .font(.headline)
            Text("No saved match was found. If you know this person, ask a caregiver to save them. Otherwise, scan again with a clearer photo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: onRetake) {
                if isProcessing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Retake Photo", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)

            HStack(spacing: 12) {
                Button(action: onRetry) {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing)

                Button {
                    showingCreatePerson = true
                } label: {
                    Label("Save Person", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct HistoryTabView: View {
    let backendURL: String
    let runs: [RecognitionRun]
    let onPersonUpdated: (Person) -> Void
    let onPersonDeleted: (String) -> Void
    let onDatabaseLoaded: ([Person]) -> Void
    let onDeleteRun: (UUID) -> Void
    let onDeleteAllRuns: () -> Void

    private var recentRuns: [RecognitionRun] {
        Array(runs.prefix(5))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Recognition Runs") {
                    if runs.isEmpty {
                        Text("No recognition runs yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentRuns) { run in
                            RecognitionRunRow(run: run)
                            .swipeActions {
                                Button(role: .destructive) {
                                    onDeleteRun(run.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }

                        if runs.count > 5 {
                            NavigationLink {
                                AllRecognitionRunsView(
                                    runs: runs,
                                    onDeleteRun: onDeleteRun,
                                    onDeleteAllRuns: onDeleteAllRuns
                                )
                            } label: {
                                Label("See All Recognition Runs", systemImage: "list.bullet")
                            }
                        }

                        Button(role: .destructive) {
                            onDeleteAllRuns()
                        } label: {
                            Label("Delete All Historical Runs", systemImage: "trash")
                        }
                    }
                }

                Section("Database") {
                    NavigationLink {
                        PeopleDatabaseView(
                            backendURL: backendURL,
                            onPersonUpdated: onPersonUpdated,
                            onPersonDeleted: onPersonDeleted,
                            onDatabaseLoaded: onDatabaseLoaded
                        )
                    } label: {
                        Label("View and Edit People", systemImage: "person.3")
                    }
                }
            }
            .navigationTitle("History")
        }
    }
}

private struct PatientPeopleTabView: View {
    let backendURL: String

    @State private var people: [Person] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let apiClient = APIClient()

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView()
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("Saved People") {
                    if people.isEmpty && !isLoading {
                        Text("No people have been saved yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(people) { person in
                            NavigationLink {
                                PersonDetailView(personID: person.id, backendURL: backendURL, allowsMemoryManagement: true)
                            } label: {
                                HStack(spacing: 12) {
                                    PersonReferenceImageView(
                                        personID: person.id,
                                        backendURL: backendURL,
                                        size: 58
                                    )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(person.name)
                                            .font(.headline)
                                        if let relationshipLabel = person.patientRelationshipLabel {
                                            Text(relationshipLabel)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.green)
                                        }
                                        Text(person.description.isEmpty ? "No description." : person.description)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("People")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await loadPeople()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .task {
                await loadPeople()
            }
        }
    }

    private func loadPeople() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            people = try await apiClient.people(baseURL: backendURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AllRecognitionRunsView: View {
    let runs: [RecognitionRun]
    let onDeleteRun: (UUID) -> Void
    let onDeleteAllRuns: () -> Void

    var body: some View {
        List {
            ForEach(runs) { run in
                RecognitionRunRow(run: run)
                .swipeActions {
                    Button(role: .destructive) {
                        onDeleteRun(run.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("All Runs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    onDeleteAllRuns()
                } label: {
                    Label("Delete All", systemImage: "trash")
                }
            }
        }
    }
}

private struct RecognitionRunRow: View {
    let run: RecognitionRun

    var body: some View {
        HStack(spacing: 12) {
            if let image = UIImage(data: run.thumbnailData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(run.result.person?.name ?? run.result.status.rawValue.capitalized)
                    .font(.headline)
                Text(Self.dateFormatter.string(from: run.createdAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("Faces \(run.result.faceCount)")
                    if let distance = run.result.distance {
                        Text("Distance \(String(format: "%.3f", distance))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 3)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct SettingsTabView: View {
    @Binding var backendURL: String
    @Binding var ttsEnabled: Bool
    @Binding var patientMode: Bool
    let photoAuthorizationStatus: PHAuthorizationStatus
    let cameraAuthorizationStatus: AVAuthorizationStatus
    let notificationAuthorizationStatus: UNAuthorizationStatus
    let healthStatus: String
    let isCheckingHealth: Bool
    let requestPhotos: () -> Void
    let requestCamera: () -> Void
    let requestNotifications: () -> Void
    let checkHealth: () -> Void
    let chooseExperience: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Experience") {
                    StatusLine(title: "Current", value: selectedExperienceTitle)
                    Button(action: chooseExperience) {
                        Label("Switch Experience", systemImage: "person.2.crop.square.stack")
                    }
                }

                Section("Accessibility") {
                    Toggle("Speak Recognition Results", isOn: $ttsEnabled)
                    Toggle("Voice Commands", isOn: $voiceCommandsEnabled)
                }

                Section("Backend") {
                    TextField("Backend URL", text: $backendURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    Button(action: checkHealth) {
                        if isCheckingHealth {
                            ProgressView()
                        } else {
                            Label("Check Backend", systemImage: "network")
                        }
                    }

                    Text(healthStatus)
                        .foregroundStyle(.secondary)
                }

                Section("Permissions") {
                    Button(action: requestPhotos) {
                        Label("Request Photos Access", systemImage: "photo.on.rectangle")
                    }
                    StatusLine(title: "Photos", value: photoStatusText)

                    Button(action: requestCamera) {
                        Label("Request Camera Access", systemImage: "camera")
                    }
                    StatusLine(title: "Camera", value: cameraStatusText)

                    Button(action: requestNotifications) {
                        Label("Request Notifications", systemImage: "bell")
                    }
                    StatusLine(title: "Notifications", value: notificationStatusText)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var photoStatusText: String {
        switch photoAuthorizationStatus {
        case .authorized:
            return "Authorized"
        case .limited:
            return "Limited"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not determined"
        @unknown default:
            return "Unknown"
        }
    }

    private var cameraStatusText: String {
        switch cameraAuthorizationStatus {
        case .authorized:
            return "Authorized"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not determined"
        @unknown default:
            return "Unknown"
        }
    }

    private var notificationStatusText: String {
        switch notificationAuthorizationStatus {
        case .authorized:
            return "Authorized"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not determined"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }
}

private struct StatusLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

struct PersonReferenceImageView: View {
    let personID: String
    let backendURL: String
    let size: CGFloat
    var refreshToken: Int = 0

    @State private var imageData: Data?
    @State private var didLoad = false

    private let apiClient = APIClient()

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if didLoad {
                Image(systemName: "person.crop.square")
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemGroupedBackground))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemGroupedBackground))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: "\(backendURL)-\(personID)-\(refreshToken)") {
            await loadImage()
        }
    }

    private func loadImage() async {
        didLoad = false
        do {
            imageData = try await apiClient.personReferenceImage(id: personID, baseURL: backendURL)
        } catch {
            imageData = nil
        }
        didLoad = true
    }
}

private struct PeopleDatabaseView: View {
    let backendURL: String
    let onPersonUpdated: (Person) -> Void
    let onPersonDeleted: (String) -> Void
    let onDatabaseLoaded: ([Person]) -> Void

    @State private var people: [Person] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let apiClient = APIClient()

    var body: some View {
        List {
            if isLoading {
                ProgressView()
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("People") {
                if people.isEmpty && !isLoading {
                    Text("No people in the database.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(people) { person in
                        NavigationLink {
                            PersonDatabaseEditor(
                                backendURL: backendURL,
                                person: person,
                                onSaved: { updatedPerson in
                                    onPersonUpdated(updatedPerson)
                                    Task {
                                        await loadPeople()
                                    }
                                },
                                onDeleted: { personID in
                                    onPersonDeleted(personID)
                                    Task {
                                        await loadPeople()
                                    }
                                }
                            )
                        } label: {
                            HStack(spacing: 12) {
                                PersonReferenceImageView(
                                    personID: person.id,
                                    backendURL: backendURL,
                                    size: 58
                                )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(person.name)
                                        .font(.headline)
                                    Text(person.description.isEmpty ? "No description." : person.description)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(person.id)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task {
                                    await delete(person)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Database")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await loadPeople()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            await loadPeople()
        }
    }

    private func loadPeople() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            people = try await apiClient.people(baseURL: backendURL)
            onDatabaseLoaded(people)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ person: Person) async {
        errorMessage = nil

        do {
            try await apiClient.deletePerson(id: person.id, baseURL: backendURL)
            people.removeAll { $0.id == person.id }
            onPersonDeleted(person.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PersonDatabaseEditor: View {
    let backendURL: String
    let person: Person
    let onSaved: (Person) -> Void
    let onDeleted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var relationship: String
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var photoCount: Int = 0
    @State private var isAddingPhoto = false
    @State private var showPhotoPicker = false
    @State private var showTrainingPhotos = false
    @State private var addPhotoError: String?
    @State private var isUpdatingReferencePhoto = false
    @State private var showReferencePhotoPicker = false
    @State private var referencePhotoError: String?
    @State private var referencePhotoRefreshToken = 0
    @State private var memoryCount: Int = 0
    @State private var isAddingMemory = false
    @State private var showMemoryPicker = false
    @State private var showMemories = false
    @State private var memoryError: String?

    private let apiClient = APIClient()

    init(
        backendURL: String,
        person: Person,
        onSaved: @escaping (Person) -> Void,
        onDeleted: @escaping (String) -> Void
    ) {
        self.backendURL = backendURL
        self.person = person
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _name = State(initialValue: person.name)
        _description = State(initialValue: person.description)
        _relationship = State(initialValue: person.relationship)
    }

    var body: some View {
        Form {
            Section("Reference Photo") {
                HStack {
                    Spacer()
                    PersonReferenceImageView(
                        personID: person.id,
                        backendURL: backendURL,
                        size: 180,
                        refreshToken: referencePhotoRefreshToken
                    )
                    Spacer()
                }
                Button {
                    showReferencePhotoPicker = true
                } label: {
                    if isUpdatingReferencePhoto {
                        ProgressView()
                    } else {
                        Label("Change Reference Photo", systemImage: "photo")
                    }
                }
                .disabled(isUpdatingReferencePhoto)
                if let referencePhotoError {
                    Text(referencePhotoError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Training Photos") {
                HStack {
                    Text("Saved encodings")
                    Spacer()
                    Text("\(photoCount)")
                        .foregroundStyle(.secondary)
                }
                Button {
                    showPhotoPicker = true
                } label: {
                    if isAddingPhoto {
                        ProgressView()
                    } else {
                        Label("Add Another Photo", systemImage: "photo.badge.plus")
                    }
                }
                .disabled(isAddingPhoto)

                Button {
                    showTrainingPhotos = true
                } label: {
                    Label("Review Saved Photos", systemImage: "rectangle.stack.badge.person.crop")
                }
                .disabled(photoCount == 0)

                if let addPhotoError {
                    Text(addPhotoError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Memories") {
                HStack {
                    Text("Saved memories")
                    Spacer()
                    Text("\(memoryCount)")
                        .foregroundStyle(.secondary)
                }
                Button {
                    showMemoryPicker = true
                } label: {
                    if isAddingMemory {
                        ProgressView()
                    } else {
                        Label("Add Memory", systemImage: "photo.stack")
                    }
                }
                .disabled(isAddingMemory)

                Button {
                    showMemories = true
                } label: {
                    Label("Look Through Memories", systemImage: "rectangle.stack")
                }
                .disabled(memoryCount == 0)

                if let memoryError {
                    Text(memoryError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Record") {
                Text(person.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Created: \(person.createdAt)")
                    .foregroundStyle(.secondary)
            }

            Section("Editable Fields") {
                TextField("Name", text: $name)
                TextField("Relationship", text: $relationship)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section {
                Button(role: .destructive) {
                    Task {
                        await delete()
                    }
                } label: {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Label("Delete Person", systemImage: "trash")
                    }
                }
                .disabled(isSaving || isDeleting)
            }

            if let errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .task { await loadCounts() }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerView { imageData in
                Task { await uploadPhoto(imageData) }
            }
        }
        .sheet(isPresented: $showTrainingPhotos) {
            TrainingPhotosView(
                person: person,
                backendURL: backendURL,
                onDeleted: { _ in
                    photoCount = max(0, photoCount - 1)
                }
            )
        }
        .sheet(isPresented: $showReferencePhotoPicker) {
            PhotoPickerView { imageData in
                Task { await updateReferencePhoto(imageData) }
            }
        }
        .sheet(isPresented: $showMemoryPicker) {
            MemoryPickerView { selection in
                Task { await uploadMemory(selection) }
            }
        }
        .sheet(isPresented: $showMemories) {
            MemoriesGalleryView(
                person: person,
                backendURL: backendURL,
                allowsDelete: true,
                onDeleted: { _ in
                    memoryCount = max(0, memoryCount - 1)
                }
            )
        }
        .navigationTitle("Edit Person")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        await save()
                    }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(trimmedName.isEmpty || isSaving || isDeleting)
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let updatedPerson = try await apiClient.updatePerson(
                id: person.id,
                name: trimmedName,
                description: trimmedDescription,
                relationship: relationship.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: backendURL
            )
            onSaved(updatedPerson)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            try await apiClient.deletePerson(id: person.id, baseURL: backendURL)
            onDeleted(person.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCounts() async {
        photoCount = (try? await apiClient.personPhotoCount(id: person.id, baseURL: backendURL)) ?? 0
        memoryCount = (try? await apiClient.personMemories(id: person.id, baseURL: backendURL).count) ?? 0
    }

    private func uploadPhoto(_ imageData: Data) async {
        isAddingPhoto = true
        addPhotoError = nil
        defer { isAddingPhoto = false }
        do {
            try await apiClient.addPersonPhoto(id: person.id, imageData: imageData, baseURL: backendURL)
            photoCount += 1
        } catch {
            addPhotoError = error.localizedDescription
        }
    }

    private func updateReferencePhoto(_ imageData: Data) async {
        isUpdatingReferencePhoto = true
        referencePhotoError = nil
        defer { isUpdatingReferencePhoto = false }
        do {
            try await apiClient.updatePersonReferenceImage(
                id: person.id,
                imageData: imageData,
                baseURL: backendURL
            )
            referencePhotoRefreshToken += 1
        } catch {
            referencePhotoError = error.localizedDescription
        }
    }

    private func uploadMemory(_ selection: MemoryMediaSelection) async {
        isAddingMemory = true
        memoryError = nil
        defer { isAddingMemory = false }
        do {
            _ = try await apiClient.addPersonMemory(
                id: person.id,
                data: selection.data,
                mimeType: selection.mimeType,
                fileName: selection.fileName,
                baseURL: backendURL
            )
            memoryCount += 1
        } catch {
            memoryError = error.localizedDescription
        }
    }
}

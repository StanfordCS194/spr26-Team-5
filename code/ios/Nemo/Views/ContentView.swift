import SwiftUI
import UIKit
import Photos
import UserNotifications

struct ContentView: View {
    @EnvironmentObject private var notifications: NotificationManager
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var photoWatcher = PhotoWatcher()
    @AppStorage("backendURL") private var backendURL = "http://127.0.0.1:8000"

    @State private var selectedTab = 0
    @State private var selectedPersonID: String?
    @State private var showingCreatePerson = false
    @State private var healthStatus = "Not checked"
    @State private var isCheckingHealth = false

    private let apiClient = APIClient()

    var body: some View {
        TabView(selection: $selectedTab) {
            RecognitionTabView(
                photoWatcher: photoWatcher,
                backendURL: backendURL,
                showingCreatePerson: $showingCreatePerson,
                notifications: notifications
            )
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
                photoAuthorizationStatus: photoWatcher.photoAuthorizationStatus,
                notificationAuthorizationStatus: notifications.authorizationStatus,
                healthStatus: healthStatus,
                isCheckingHealth: isCheckingHealth,
                requestPhotos: {
                    Task {
                        await photoWatcher.requestPermission()
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
            Task {
                await autoScanIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                photoWatcher.startObservingIfAllowed()
                photoWatcher.refreshForPhotoChanges()
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
                selectedPersonID = personID
                selectedTab = 1
            case .createPerson:
                selectedTab = 0
                showingCreatePerson = true
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

    private func autoScanIfNeeded() async {
        guard photoWatcher.pendingPhotoIdentifier != nil, !photoWatcher.isProcessing else {
            return
        }
        await photoWatcher.scanLatestPhoto(baseURL: backendURL, notifications: notifications)
    }
}

private struct RecognitionTabView: View {
    @ObservedObject var photoWatcher: PhotoWatcher
    let backendURL: String
    @Binding var showingCreatePerson: Bool
    let notifications: NotificationManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    NewPhotoStatusView(
                        hasNewPhoto: photoWatcher.hasNewPhoto,
                        isProcessing: photoWatcher.isProcessing
                    )

                    if let imageData = photoWatcher.lastScannedImageData {
                        PhotoPreview(imageData: imageData)
                    }

                    if let issue = photoWatcher.scanIssue {
                        ScanIssueView(issue: issue)
                    }

                    if let result = photoWatcher.lastResult {
                        RecognitionResultView(result: result)
                    } else if photoWatcher.scanIssue == nil {
                        EmptyRecognitionView()
                    }

                    if let message = photoWatcher.lastScanMessage {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if photoWatcher.pendingUnknownImageData != nil {
                        Button {
                            showingCreatePerson = true
                        } label: {
                            Label("Create Person From Unknown", systemImage: "person.crop.circle.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Recognition")
        }
    }
}

private struct NewPhotoStatusView: View {
    let hasNewPhoto: Bool
    let isProcessing: Bool

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
}

private struct ScanIssueView: View {
    let issue: ScanIssue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 6) {
                Text(issue.title)
                    .font(.headline)
                Text(issue.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
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
    let result: RecognitionResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(result.status.rawValue.capitalized, systemImage: result.status == .recognized ? "person.fill.checkmark" : "questionmark.circle")
                    .font(.headline)
                    .foregroundStyle(result.status == .recognized ? .green : .orange)
                Spacer()
                Text("Faces \(result.faceCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let person = result.person {
                Text(person.name)
                    .font(.title3.weight(.semibold))
                Text(person.description.isEmpty ? "No description." : person.description)
                    .foregroundStyle(.secondary)
            } else {
                Text("No matching person found.")
                    .foregroundStyle(.secondary)
            }

            if let distance = result.distance {
                Text("Distance \(String(format: "%.3f", distance))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
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
    let photoAuthorizationStatus: PHAuthorizationStatus
    let notificationAuthorizationStatus: UNAuthorizationStatus
    let healthStatus: String
    let isCheckingHealth: Bool
    let requestPhotos: () -> Void
    let requestNotifications: () -> Void
    let checkHealth: () -> Void

    var body: some View {
        NavigationStack {
            Form {
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

private struct PersonReferenceImageView: View {
    let personID: String
    let backendURL: String
    let size: CGFloat

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
        .task(id: "\(backendURL)-\(personID)") {
            await loadImage()
        }
    }

    private func loadImage() async {
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
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

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
    }

    var body: some View {
        Form {
            Section("Reference Photo") {
                HStack {
                    Spacer()
                    PersonReferenceImageView(
                        personID: person.id,
                        backendURL: backendURL,
                        size: 180
                    )
                    Spacer()
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
}

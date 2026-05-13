import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var notifications: NotificationManager
    @StateObject private var photoWatcher = PhotoWatcher()
    @AppStorage("backendURL") private var backendURL = "http://127.0.0.1:8000"

    @State private var selectedPersonID: String?
    @State private var showingCreatePerson = false
    @State private var showingDatabase = false
    @State private var healthStatus = "Not checked"
    @State private var isCheckingHealth = false

    private let apiClient = APIClient()

    var body: some View {
        NavigationStack {
            List {
                Section("Backend") {
                    TextField("Backend URL", text: $backendURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    Button {
                        Task {
                            await checkHealth()
                        }
                    } label: {
                        if isCheckingHealth {
                            ProgressView()
                        } else {
                            Text("Check Backend")
                        }
                    }

                    Text(healthStatus)
                        .foregroundStyle(.secondary)
                }

                Section("Permissions") {
                    Button("Request Photos Access") {
                        Task {
                            await photoWatcher.requestPermission()
                        }
                    }
                    Text("Photos: \(photoStatusText)")
                        .foregroundStyle(.secondary)

                    Button("Request Notifications") {
                        Task {
                            await notifications.requestPermission()
                        }
                    }
                    Text("Notifications: \(notificationStatusText)")
                        .foregroundStyle(.secondary)
                }

                Section("Recognition") {
                    Button {
                        Task {
                            await photoWatcher.scanLatestPhoto(baseURL: backendURL, notifications: notifications)
                        }
                    } label: {
                        if photoWatcher.isProcessing {
                            ProgressView()
                        } else {
                            Text("Scan Latest Photo")
                        }
                    }
                    .disabled(photoWatcher.isProcessing)

                    if photoWatcher.pendingUnknownImageData != nil {
                        Button("Create Person From Unknown") {
                            showingCreatePerson = true
                        }
                    }

                    if let imageData = photoWatcher.lastScannedImageData {
                        PhotoPreview(imageData: imageData)
                    }

                    if let result = photoWatcher.lastResult {
                        RecognitionResultView(result: result)
                    }
                }

                Section("Database") {
                    Button("View and Edit People") {
                        showingDatabase = true
                    }
                }

                Section("Events") {
                    if photoWatcher.events.isEmpty {
                        Text("No events yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(photoWatcher.events) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title)
                                    .font(.headline)
                                Text(event.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("FaceRecall")
            .navigationDestination(item: $selectedPersonID) { personID in
                PersonDetailView(personID: personID, backendURL: backendURL)
            }
            .sheet(isPresented: $showingCreatePerson) {
                CreatePersonView(
                    backendURL: backendURL,
                    imageData: photoWatcher.pendingUnknownImageData,
                    onCreated: { person in
                        photoWatcher.clearPendingUnknown()
                        selectedPersonID = person.id
                    }
                )
            }
            .sheet(isPresented: $showingDatabase) {
                PeopleDatabaseView(backendURL: backendURL)
            }
            .onAppear {
                photoWatcher.startObservingIfAllowed()
            }
            .onChange(of: notifications.route) { _, route in
                guard let route else {
                    return
                }
                switch route {
                case let .person(personID):
                    selectedPersonID = personID
                case .createPerson:
                    showingCreatePerson = true
                }
                notifications.route = nil
            }
        }
    }

    private var photoStatusText: String {
        switch photoWatcher.photoAuthorizationStatus {
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
        switch notifications.authorizationStatus {
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
}

private struct PhotoPreview: View {
    let imageData: Data

    var body: some View {
        if let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Latest scanned photo")
        } else {
            Text("Could not display scanned photo.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecognitionResultView: View {
    let result: RecognitionResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.status.rawValue.capitalized)
                .font(.headline)
            if let person = result.person {
                Text(person.name)
            }
            Text("Faces: \(result.faceCount)")
                .foregroundStyle(.secondary)
            if let distance = result.distance {
                Text("Distance: \(String(format: "%.3f", distance))")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PeopleDatabaseView: View {
    let backendURL: String

    @Environment(\.dismiss) private var dismiss
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
                                    onChanged: {
                                        Task {
                                            await loadPeople()
                                        }
                                    }
                                )
                            } label: {
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
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task {
                                        await delete(person)
                                    }
                                } label: {
                                    Text("Delete")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Database")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") {
                        Task {
                            await loadPeople()
                        }
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

    private func delete(_ person: Person) async {
        errorMessage = nil

        do {
            try await apiClient.deletePerson(id: person.id, baseURL: backendURL)
            people.removeAll { $0.id == person.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PersonDatabaseEditor: View {
    let backendURL: String
    let person: Person
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private let apiClient = APIClient()

    init(backendURL: String, person: Person, onChanged: @escaping () -> Void) {
        self.backendURL = backendURL
        self.person = person
        self.onChanged = onChanged
        _name = State(initialValue: person.name)
        _description = State(initialValue: person.description)
    }

    var body: some View {
        Form {
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
                        Text("Delete Person")
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
            _ = try await apiClient.updatePerson(
                id: person.id,
                name: trimmedName,
                description: trimmedDescription,
                baseURL: backendURL
            )
            onChanged()
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
            onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

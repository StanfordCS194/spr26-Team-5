import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var notifications: NotificationManager
    @StateObject private var photoWatcher = PhotoWatcher()
    @AppStorage("backendURL") private var backendURL = "http://127.0.0.1:8000"

    @State private var selectedPersonID: String?
    @State private var showingCreatePerson = false
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

                    if let result = photoWatcher.lastResult {
                        RecognitionResultView(result: result)
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

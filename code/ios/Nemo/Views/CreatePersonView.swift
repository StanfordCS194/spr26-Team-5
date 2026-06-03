import SwiftUI

struct CreatePersonView: View {
    let backendURL: String
    let imageData: Data?
    let onCreated: (Person) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var relationship = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isCombining = false
    @State private var duplicatePerson: Person?
    @State private var showingDuplicateAlert = false

    private let apiClient = APIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    TextField("Relationship (e.g. your daughter)", text: $relationship)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    if imageData == nil {
                        Text("No unknown image is currently staged. Scan a photo first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("The staged unknown image will be used for the first face encoding.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create Person")
            .alert("Name Already Exists", isPresented: $showingDuplicateAlert, presenting: duplicatePerson) { person in
                Button("Add Photo to Existing") {
                    Task {
                        await combine(with: person)
                    }
                }
                Button("Use Different Name", role: .cancel) { }
            } message: { person in
                Text("\(person.name) is already saved. You can add this photo as another saved encoding for that person, or change the name to create a separate person.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await save()
                        }
                    } label: {
                        if isSaving || isCombining {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(trimmedName.isEmpty || imageData == nil || isSaving || isCombining)
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        guard let imageData else {
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            if let duplicate = try await existingPerson(named: trimmedName) {
                duplicatePerson = duplicate
                showingDuplicateAlert = true
                return
            }

            let person = try await apiClient.createPerson(
                name: trimmedName,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                relationship: relationship.trimmingCharacters(in: .whitespacesAndNewlines),
                imageData: imageData,
                baseURL: backendURL
            )
            onCreated(person)
            dismiss()
        } catch let error as APIClientError where error.statusCode == 409 {
            if let duplicate = try? await existingPerson(named: trimmedName) {
                duplicatePerson = duplicate
                showingDuplicateAlert = true
            } else {
                errorMessage = error.message
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func existingPerson(named name: String) async throws -> Person? {
        let normalizedName = name.normalizedPersonName
        return try await apiClient.people(baseURL: backendURL).first {
            $0.name.normalizedPersonName == normalizedName
        }
    }

    private func combine(with person: Person) async {
        guard let imageData else {
            return
        }

        isCombining = true
        errorMessage = nil
        defer { isCombining = false }

        do {
            try await apiClient.addPersonPhoto(id: person.id, imageData: imageData, baseURL: backendURL)
            onCreated(person)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension String {
    var normalizedPersonName: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

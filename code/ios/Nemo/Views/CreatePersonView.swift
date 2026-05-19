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
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageData == nil || isSaving)
                }
            }
        }
    }

    private func save() async {
        guard let imageData else {
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let person = try await apiClient.createPerson(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                relationship: relationship.trimmingCharacters(in: .whitespacesAndNewlines),
                imageData: imageData,
                baseURL: backendURL
            )
            onCreated(person)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

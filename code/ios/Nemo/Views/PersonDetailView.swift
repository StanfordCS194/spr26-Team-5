import SwiftUI

struct PersonDetailView: View {
    let personID: String
    let backendURL: String

    @State private var person: Person?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let apiClient = APIClient()

    var body: some View {
        List {
            if isLoading {
                ProgressView()
            }

            if let person {
                Section("Person") {
                    Text(person.name)
                        .font(.headline)
                    Text(person.description.isEmpty ? "No description." : person.description)
                    Text("Created: \(person.createdAt)")
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
        .navigationTitle("Person")
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            person = try await apiClient.person(id: personID, baseURL: backendURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

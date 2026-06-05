import SwiftUI

struct PersonDetailView: View {
    let personID: String
    let backendURL: String
    var allowsMemoryManagement = false

    @State private var person: Person?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var memoryCount = 0
    @State private var isAddingMemory = false
    @State private var showMemoryPicker = false
    @State private var showMemories = false
    @State private var memoryError: String?

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
                    if let relationshipLabel = person.patientRelationshipLabel {
                        Text(relationshipLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    Text(person.description.isEmpty ? "No description." : person.description)
                    Text("Created: \(person.createdAt)")
                        .foregroundStyle(.secondary)
                    if let lastSeenLabel = person.lastSeenLabel {
                        Text("Last seen: \(lastSeenLabel)")
                            .foregroundStyle(.secondary)
                    }
                }

                if !person.notes.isEmpty {
                    Section("Caregiver Notes") {
                        Text(person.notes)
                    }
                }

                if allowsMemoryManagement {
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
                                .foregroundStyle(.red)
                        }
                    }
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
        .sheet(isPresented: $showMemoryPicker) {
            MemoryPickerView { selection in
                Task {
                    await addMemory(selection)
                }
            }
        }
        .sheet(isPresented: $showMemories) {
            if let person {
                MemoriesGalleryView(
                    person: person,
                    backendURL: backendURL,
                    allowsDelete: true,
                    onDeleted: { _ in
                        memoryCount = max(0, memoryCount - 1)
                    }
                )
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            person = try await apiClient.person(id: personID, baseURL: backendURL)
            if allowsMemoryManagement {
                memoryCount = try await apiClient.personMemories(id: personID, baseURL: backendURL).count
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addMemory(_ selection: MemoryMediaSelection) async {
        guard allowsMemoryManagement else {
            return
        }

        isAddingMemory = true
        memoryError = nil
        defer { isAddingMemory = false }

        do {
            _ = try await apiClient.addPersonMemory(
                id: personID,
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

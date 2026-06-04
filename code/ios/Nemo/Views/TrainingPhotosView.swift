import SwiftUI
import UIKit

struct TrainingPhotosView: View {
    let person: Person
    let backendURL: String
    var onDeleted: ((FaceEncodingSummary) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var photos: [FaceEncodingSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let apiClient = APIClient()

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView()
                }

                if photos.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No Training Photos",
                        systemImage: "photo.on.rectangle",
                        description: Text("Add photos from this person's edit screen.")
                    )
                }

                ForEach(photos) { photo in
                    TrainingPhotoRow(
                        personID: person.id,
                        photo: photo,
                        backendURL: backendURL,
                        onDelete: {
                            Task { await delete(photo) }
                        }
                    )
                }

                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Review Face Photos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await load()
            }
            .refreshable {
                await load()
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            photos = try await apiClient.personPhotos(id: person.id, baseURL: backendURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ photo: FaceEncodingSummary) async {
        errorMessage = nil

        do {
            try await apiClient.deletePersonPhotoEncoding(
                personID: person.id,
                encodingID: photo.id,
                baseURL: backendURL
            )
            photos.removeAll { $0.id == photo.id }
            onDeleted?(photo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TrainingPhotoRow: View {
    let personID: String
    let photo: FaceEncodingSummary
    let backendURL: String
    let onDelete: () -> Void

    @State private var imageData: Data?
    @State private var isLoadingImage = false

    private let apiClient = APIClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemBackground))
                    .aspectRatio(1.4, contentMode: .fit)

                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if isLoadingImage {
                    ProgressView()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.title2)
                        Text(photo.hasImage ? "Could not load preview" : "No preview saved")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved \(photo.createdAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(photo.id)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard photo.hasImage, imageData == nil else {
            return
        }

        isLoadingImage = true
        defer { isLoadingImage = false }

        imageData = try? await apiClient.personPhotoImage(
            personID: personID,
            encodingID: photo.id,
            baseURL: backendURL
        )
    }
}

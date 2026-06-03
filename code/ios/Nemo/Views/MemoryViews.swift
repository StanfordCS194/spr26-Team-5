import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MemoryMediaSelection {
    let data: Data
    let mimeType: String
    let fileName: String
}

struct MemoryPickerView: View {
    let onSelected: (MemoryMediaSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                PhotosPicker(selection: $selectedItem, matching: .any(of: [.images, .videos]), photoLibrary: .shared()) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Label("Choose Photo or Video", systemImage: "photo.stack")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .padding(.horizontal)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .navigationTitle("Add Memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isLoading)
                }
            }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                Task {
                    await load(item)
                }
            }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "Could not load selected memory."
                return
            }

            let contentType = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) })
                ?? item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
                ?? .data
            let mimeType = contentType.preferredMIMEType ?? fallbackMIMEType(for: contentType)
            let fileExtension = contentType.preferredFilenameExtension ?? fallbackExtension(for: contentType)
            onSelected(
                MemoryMediaSelection(
                    data: data,
                    mimeType: mimeType,
                    fileName: "memory-\(UUID().uuidString).\(fileExtension)"
                )
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fallbackMIMEType(for contentType: UTType) -> String {
        if contentType.conforms(to: .movie) {
            return "video/quicktime"
        }
        if contentType.conforms(to: .image) {
            return "image/jpeg"
        }
        return "application/octet-stream"
    }

    private func fallbackExtension(for contentType: UTType) -> String {
        contentType.conforms(to: .movie) ? "mov" : "jpg"
    }
}

struct MemoriesGalleryView: View {
    let person: Person
    let backendURL: String
    var allowsDelete = false
    var onDeleted: ((PersonMemory) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var memories: [PersonMemory] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedVideo: VideoPlaybackItem?

    private let apiClient = APIClient()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if memories.isEmpty {
                    ContentUnavailableView(
                        "No Memories Yet",
                        systemImage: "photo.stack",
                        description: Text("Add photos or videos from the person editor.")
                    )
                } else {
                    GeometryReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 18) {
                                ForEach(memories) { memory in
                                    MemoryTile(
                                        personID: person.id,
                                        backendURL: backendURL,
                                        memory: memory,
                                        height: max(280, proxy.size.height - 88),
                                        onPlayVideo: { videoURL in
                                            selectedVideo = VideoPlaybackItem(url: videoURL)
                                        }
                                    )
                                    .frame(width: max(260, proxy.size.width - 48))
                                    .contextMenu {
                                        if allowsDelete {
                                            Button(role: .destructive) {
                                                Task {
                                                    await delete(memory)
                                                }
                                            } label: {
                                                Label("Delete Memory", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollIndicators(.visible)
                    }
                }
            }
            .navigationTitle("Memories")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await load()
            }
            .alert("Memory Error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $selectedVideo) { item in
                NavigationStack {
                    VideoPlayer(player: AVPlayer(url: item.url))
                        .ignoresSafeArea()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
                                    selectedVideo = nil
                                }
                            }
                        }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            memories = try await apiClient.personMemories(id: person.id, baseURL: backendURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ memory: PersonMemory) async {
        do {
            try await apiClient.deletePersonMemory(personID: person.id, memoryID: memory.id, baseURL: backendURL)
            memories.removeAll { $0.id == memory.id }
            onDeleted?(memory)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MemoryTile: View {
    let personID: String
    let backendURL: String
    let memory: PersonMemory
    var height: CGFloat = 170
    let onPlayVideo: (URL) -> Void

    @State private var imageData: Data?
    @State private var videoURL: URL?
    @State private var isLoading = false
    @State private var failed = false

    private let apiClient = APIClient()

    var body: some View {
        Button {
            if let videoURL {
                onPlayVideo(videoURL)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemGroupedBackground))

                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if isLoading {
                    ProgressView()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: memory.isVideo ? "play.rectangle.fill" : "photo")
                            .font(.system(size: 34))
                        Text(failed ? "Could not load" : memory.isVideo ? "Video" : "Photo")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }

                if memory.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(memory.isVideo && videoURL == nil)
        .task {
            await load()
        }
    }

    private func load() async {
        guard !isLoading, imageData == nil, videoURL == nil else {
            return
        }

        isLoading = true
        failed = false
        defer { isLoading = false }

        do {
            let data = try await apiClient.personMemoryData(
                personID: personID,
                memoryID: memory.id,
                baseURL: backendURL
            )
            if memory.isVideo {
                videoURL = try writeTemporaryVideo(data)
            } else {
                imageData = data
            }
        } catch {
            failed = true
        }
    }

    private func writeTemporaryVideo(_ data: Data) throws -> URL {
        let fileExtension = memory.fileName.split(separator: ".").last.map(String.init) ?? "mov"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemo-memory-\(memory.id)")
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }
}

private struct VideoPlaybackItem: Identifiable {
    let id = UUID()
    let url: URL
}

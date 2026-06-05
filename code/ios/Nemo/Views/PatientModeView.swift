import SwiftUI
import UIKit

struct PatientModeView: View {
    @ObservedObject var photoWatcher: PhotoWatcher
    let backendURL: String
    let notifications: NotificationManager
    let voiceCommandsEnabled: Bool
    let onRetry: () -> Void
    @State private var showingCamera = false
    @State private var showingMemories = false
    @State private var showingMemoryPicker = false
    @State private var showingVoiceCommands = false
    @State private var cameraMessage: String?
    @State private var memoryMessage: String?
    @State private var isAddingMemory = false

    private let apiClient = APIClient()

    @StateObject private var voiceCommandManager = VoiceCommandManager()
    @StateObject private var speechManager = SpeechManager()

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            VStack(spacing: 40) {
                Spacer()
                if photoWatcher.isProcessing {
                    processingView
                } else if let result = photoWatcher.lastResult, result.status == .recognized, let person = result.person {
                    recognizedView(person: person)
                } else if photoWatcher.scanIssue != nil || photoWatcher.lastResult?.status == .unknown {
                    unknownView
                } else {
                    waitingView
                }
                Spacer()
                if let cameraMessage {
                    cameraErrorBanner(message: cameraMessage)
                }
            }
            .padding(.vertical, 32)
            .padding(.horizontal, 46)

            if voiceCommandsEnabled {
                topRightVoiceButton
                    .padding(.top, 18)
                    .padding(.trailing, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .onAppear {
            NotificationCenter.default.addObserver(
                forName: .triggerRecognition,
                object: nil,
                queue: .main
            ) { _ in
                showingVoiceCommands = false
                presentCamera()
            }
        }
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
        .onChange(of: voiceCommandsEnabled) { _, enabled in
            if !enabled {
                showingVoiceCommands = false
                voiceCommandManager.stopListening()
            }
        }
        .fullScreenCover(isPresented: $showingVoiceCommands) {
            VoiceCommandListeningView(
                voiceCommandManager: voiceCommandManager,
                backendURL: backendURL,
                speechManager: speechManager
            )
        }
        .sheet(isPresented: $showingMemories) {
            if let person = photoWatcher.lastResult?.person {
                MemoriesGalleryView(person: person, backendURL: backendURL, allowsDelete: true)
            }
        }
        .sheet(isPresented: $showingMemoryPicker) {
            MemoryPickerView { selection in
                if let person = photoWatcher.lastResult?.person {
                    Task {
                        await uploadMemory(selection, for: person)
                    }
                }
            }
        }
    }

    private func presentCamera() {
        cameraMessage = nil
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraMessage = CameraCaptureError.unavailable.localizedDescription
            return
        }
        showingCamera = true
    }

    private func cameraErrorBanner(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 22, weight: .medium))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button {
                cameraMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
    }

    private var topRightVoiceButton: some View {
        Button {
            showingVoiceCommands = true
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.blue))
                .shadow(radius: 4, y: 2)
        }
        .accessibilityLabel("Voice Commands")
    }

    private var backgroundColor: Color {
        if photoWatcher.isProcessing { return Color(.systemBackground) }
        if let result = photoWatcher.lastResult {
            return result.status == .recognized ? Color.green.opacity(0.15) : Color.orange.opacity(0.15)
        }
        return Color(.systemBackground)
    }

    private var processingView: some View {
        VStack(spacing: 24) {
            ProgressView().scaleEffect(2.5)
            Text("Scanning...").font(.system(size: 36, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private func recognizedView(person: Person) -> some View {
        VStack(spacing: 12) {
            if let imageData = photoWatcher.lastScannedImageData {
                scannedPhotoView(imageData: imageData)
            }

            VStack(spacing: 8) {
                Text(person.name)
                    .font(.system(size: 52, weight: .bold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.65)

                if let relationshipLabel = person.patientRelationshipLabel {
                    Label(relationshipLabel, systemImage: person.isCloseFriend ? "heart.fill" : "person.text.rectangle")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }

                if !person.description.isEmpty {
                    Text(person.description)
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }

                if let memoryMessage {
                    Text(memoryMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer(minLength: 28)

            Button {
                showingMemoryPicker = true
            } label: {
                if isAddingMemory {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                } else {
                    Label("Add Memory", systemImage: "plus.rectangle.on.folder")
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(.purple)
            .disabled(isAddingMemory)

            Button {
                showingMemories = true
            } label: {
                Label("Look through Memories", systemImage: "photo.stack")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(.green)

            Button(action: presentCamera) {
                Label("Take Another Photo", systemImage: "camera.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(.blue)
            .padding(.top, 4)

            Spacer()
        }
        .padding(.top, 24)
    }

    private var unknownView: some View {
        VStack(spacing: 28) {
            if let imageData = photoWatcher.lastScannedImageData {
                scannedPhotoView(imageData: imageData)
            }

            Image(systemName: "questionmark.circle.fill").font(.system(size: 80)).foregroundStyle(.orange)
            Text("Unknown Person").font(.system(size: 48, weight: .bold)).multilineTextAlignment(.center)
            Text("Ask a caregiver for help.").font(.system(size: 26)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: presentCamera) {
                Label("Take Photo", systemImage: "camera.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .padding(.top, 8)
            Button(action: onRetry) {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.orange)
        }
    }

    private var waitingView: some View {
        VStack(spacing: 28) {
            Image(systemName: "camera.viewfinder").font(.system(size: 80)).foregroundStyle(.secondary)
            Text("Ready to Recognize").font(.system(size: 40, weight: .semibold)).multilineTextAlignment(.center)
            Text("Take a photo to see who it is.").font(.system(size: 26)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: presentCamera) {
                Label("Take Photo", systemImage: "camera.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .padding(.top, 8)
        }
    }

    private func scannedPhotoView(imageData: Data) -> some View {
        Group {
            if let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 260)
            }
        }
    }

    private func uploadMemory(_ selection: MemoryMediaSelection, for person: Person) async {
        isAddingMemory = true
        memoryMessage = nil
        defer { isAddingMemory = false }

        do {
            _ = try await apiClient.addPersonMemory(
                id: person.id,
                data: selection.data,
                mimeType: selection.mimeType,
                fileName: selection.fileName,
                baseURL: backendURL
            )
            memoryMessage = "Memory added."
        } catch {
            memoryMessage = error.localizedDescription
        }
    }
}

private struct VoiceCommandListeningView: View {
    @ObservedObject var voiceCommandManager: VoiceCommandManager
    let backendURL: String
    let speechManager: SpeechManager

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image(systemName: voiceCommandManager.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 92, weight: .semibold))
                    .foregroundStyle(voiceCommandManager.isListening ? .red : .blue)

                Text(voiceCommandManager.isListening ? "Listening..." : "Starting...")
                    .font(.system(size: 46, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("Say \"Hey Nemo, who is this\".")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                Button {
                    voiceCommandManager.stopListening()
                    dismiss()
                } label: {
                    Label("Done", systemImage: "xmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            voiceCommandManager.requestPermissions()
            voiceCommandManager.startListening(baseURL: backendURL, speechManager: speechManager)
        }
        .onDisappear {
            voiceCommandManager.stopListening()
        }
    }
}

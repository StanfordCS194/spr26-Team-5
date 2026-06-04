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
    @State private var cameraMessage: String?

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
                Spacer()
                if voiceCommandsEnabled {
                    voiceCommandButton
                        .padding(.bottom, 24)
                }
            }
            .padding(.vertical, 32)
            .padding(.horizontal, 46)
        }
        .onAppear {
            if voiceCommandsEnabled {
                voiceCommandManager.requestPermissions()
                voiceCommandManager.startListening(baseURL: backendURL, speechManager: speechManager)
            }
            NotificationCenter.default.addObserver(
                forName: .triggerRecognition,
                object: nil,
                queue: .main
            ) { _ in
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
            if enabled {
                voiceCommandManager.requestPermissions()
                voiceCommandManager.startListening(baseURL: backendURL, speechManager: speechManager)
            } else {
                voiceCommandManager.stopListening()
            }
        }
        .sheet(isPresented: $showingMemories) {
            if let person = photoWatcher.lastResult?.person {
                MemoriesGalleryView(person: person, backendURL: backendURL)
            }
        }
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraMessage = CameraCaptureError.unavailable.localizedDescription
            return
        }
        showingCamera = true
    }

    private var voiceCommandButton: some View {
        Button {
            if voiceCommandManager.isListening {
                voiceCommandManager.stopListening()
            } else {
                voiceCommandManager.startListening(baseURL: backendURL, speechManager: speechManager)
            }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: voiceCommandManager.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 48))
                    .foregroundStyle(voiceCommandManager.isListening ? .red : .secondary)
                Text(voiceCommandManager.isListening ? "Listening..." : "Say a command")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
        }
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
            PersonReferenceImageView(
                personID: person.id,
                backendURL: backendURL,
                size: 210
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(Color(.systemBackground)))
            }

            VStack(spacing: 8) {
                Text(person.name)
                    .font(.system(size: 52, weight: .bold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.65)

                if !person.relationship.isEmpty {
                    Label(person.relationship.capitalized, systemImage: "person.text.rectangle")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }

                if !person.description.isEmpty {
                    ScrollView {
                        Text(person.description)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .frame(minHeight: 170, maxHeight: 320)
                    .scrollIndicators(.visible)
                }
            }

            Button {
                showingMemories = true
            } label: {
                Label("Look Through Memories", systemImage: "photo.stack")
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
                .frame(height: 34)
        }
        .padding(.top, 24)
    }

    private var unknownView: some View {
        VStack(spacing: 28) {
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
}

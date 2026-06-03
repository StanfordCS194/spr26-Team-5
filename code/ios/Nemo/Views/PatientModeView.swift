import SwiftUI
import UIKit

struct PatientModeView: View {
    @ObservedObject var photoWatcher: PhotoWatcher
    let backendURL: String
    let notifications: NotificationManager
    let onRetry: () -> Void
    @State private var showingCamera = false
    @State private var cameraMessage: String?

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
            }
            .padding(32)
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
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraMessage = CameraCaptureError.unavailable.localizedDescription
            return
        }
        showingCamera = true
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
        VStack(spacing: 24) {
            PersonReferenceImageView(
                personID: person.id,
                backendURL: backendURL,
                size: 220
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(Color(.systemBackground)))
            }

            VStack(spacing: 12) {
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
            }

            Button(action: presentCamera) {
                Label("Take Another Photo", systemImage: "camera.fill")
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

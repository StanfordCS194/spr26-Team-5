import SwiftUI

struct PatientModeView: View {
    @ObservedObject var photoWatcher: PhotoWatcher
    let backendURL: String
    @Binding var showingCreatePerson: Bool

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
                voiceCommandButton
                    .padding(.bottom, 24)
            }
            .padding(32)
        }
        .onAppear {
            voiceCommandManager.requestPermissions()
        }
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
        VStack(spacing: 28) {
            Image(systemName: "person.fill.checkmark").font(.system(size: 80)).foregroundStyle(.green)
            Text(person.name).font(.system(size: 52, weight: .bold)).multilineTextAlignment(.center)
            if !person.description.isEmpty {
                Text(person.description).font(.system(size: 28)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var unknownView: some View {
        VStack(spacing: 28) {
            Image(systemName: "questionmark.circle.fill").font(.system(size: 80)).foregroundStyle(.orange)
            Text("Unknown Person").font(.system(size: 48, weight: .bold)).multilineTextAlignment(.center)
            Text("Ask a caregiver for help.").font(.system(size: 26)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var waitingView: some View {
        VStack(spacing: 28) {
            Image(systemName: "camera.viewfinder").font(.system(size: 80)).foregroundStyle(.secondary)
            Text("Ready to Recognize").font(.system(size: 40, weight: .semibold)).multilineTextAlignment(.center)
            Text("Take a photo to see who it is.").font(.system(size: 26)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

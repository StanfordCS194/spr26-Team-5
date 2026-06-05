import Foundation
import Speech
import AVFoundation

@MainActor
final class VoiceCommandManager: ObservableObject {
    @Published var isListening = false
    @Published var lastCommand: VoiceCommandResponse? = nil

    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var wakeWordDetected = false

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    func startListening(baseURL: String, speechManager: SpeechManager) {
        guard !isListening else { return }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { return }
            Task { @MainActor in
                self?.beginRecognition(baseURL: baseURL, speechManager: speechManager)
            }
        }
    }

    func stopListening() {
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        wakeWordDetected = false
    }

    private func beginRecognition(baseURL: String, speechManager: SpeechManager) {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    self.stopListening()
                    return
                }
                guard let result else { return }
                self.handleTranscript(
                    result.bestTranscription.formattedString.lowercased(),
                    baseURL: baseURL,
                    speechManager: speechManager
                )
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        try? audioEngine.start()
        isListening = true
    }

    private func handleTranscript(_ text: String, baseURL: String, speechManager: SpeechManager) {
        let heardWakeWord = text.contains("hey nemo")
        guard heardWakeWord || wakeWordDetected else {
            return
        }

        if text.contains("who is this") {
            stopListening()
            Task {
                await handleCommand(text: "who is this", baseURL: baseURL, speechManager: speechManager)
            }
        } else if heardWakeWord && !wakeWordDetected {
            wakeWordDetected = true
            speechManager.speak("Yes, how can I help?")
        }
    }

    private func handleCommand(text: String, baseURL: String, speechManager: SpeechManager) async {
        if text == "who is this" {
            lastCommand = VoiceCommandResponse(action: "recognize", message: "Opening the camera.")
            speechManager.speak("Opening the camera.")
            NotificationCenter.default.post(name: .triggerRecognition, object: nil)
        } else {
            lastCommand = VoiceCommandResponse(action: "unknown", message: "I did not understand that command.")
            speechManager.speak("I did not understand that command.")
        }
    }
}

extension Notification.Name {
    static let triggerRecognition = Notification.Name("triggerRecognition")
}

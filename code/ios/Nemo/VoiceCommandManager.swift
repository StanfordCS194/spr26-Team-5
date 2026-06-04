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
        AVAudioApplication.requestRecordPermission { _ in }
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
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString.lowercased()
                if text.contains("hey nemo") {
                    if text.contains("who is this") {
                        self.stopListening()
                        Task {
                            await self.handleCommand(text: "who is this", baseURL: baseURL, speechManager: speechManager)
                        }
                    } else if text.contains("call for help") {
                        self.stopListening()
                        Task {
                            await self.handleCommand(text: "call for help", baseURL: baseURL, speechManager: speechManager)
                        }
                    } else if !self.wakeWordDetected {
                        self.wakeWordDetected = true
                        speechManager.speak("Yes, how can I help?")
                    }
                }
            }
        }

        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        try? audioEngine.start()
        isListening = true
    }

    private func handleCommand(text: String, baseURL: String, speechManager: SpeechManager) async {
        let apiClient = APIClient()
        do {
            let response = try await apiClient.voiceCommand(text: text, baseURL: baseURL)
            lastCommand = response
            speechManager.speak(response.message)
            
            if response.action == "recognize" {
                NotificationCenter.default.post(name: .triggerRecognition, object: nil)
            } else if response.action == "call_caregiver" {
                if let url = URL(string: "tel://911") {
                    await UIApplication.shared.open(url)
                }
            }
        } catch {
            speechManager.speak("Sorry, I could not process that command")
        }
    }
}

extension Notification.Name {
    static let triggerRecognition = Notification.Name("triggerRecognition")
}
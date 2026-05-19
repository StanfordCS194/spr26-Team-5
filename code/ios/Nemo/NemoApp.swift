import SwiftUI

@main
struct NemoApp: App {
    @StateObject private var notifications = NotificationManager()
    @StateObject private var speechManager = SpeechManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notifications)
                .environmentObject(speechManager)
                .onAppear {
                    notifications.configure()
                }
        }
    }
}

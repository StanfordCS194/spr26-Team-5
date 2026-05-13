import SwiftUI

@main
struct NemoApp: App {
    @StateObject private var notifications = NotificationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notifications)
                .onAppear {
                    notifications.configure()
                }
        }
    }
}

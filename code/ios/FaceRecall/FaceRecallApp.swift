import SwiftUI

@main
struct FaceRecallApp: App {
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

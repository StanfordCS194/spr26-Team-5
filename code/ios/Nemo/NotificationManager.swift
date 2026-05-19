import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var route: AppRoute?
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        Task {
            await refreshAuthorizationStatus()
        }
    }

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await refreshAuthorizationStatus()
    }

    func notifyRecognized(person: Person) {
        let content = UNMutableNotificationContent()
        content.title = "Recognized \(person.name)"
        if !person.relationship.isEmpty {
            let body = "This is \(person.relationship)." + (person.description.isEmpty ? "" : " \(person.description)")
            content.body = body.trimmingCharacters(in: .whitespaces)
        } else {
            content.body = person.description.isEmpty ? "Tap to view details." : person.description
        }
        content.sound = .default
        content.userInfo = ["route": "person", "personId": person.id]
        schedule(content: content)
    }

    func notifyUnknown() {
        let content = UNMutableNotificationContent()
        content.title = "Unknown person detected"
        content.body = "Tap to create a new profile."
        content.sound = .default
        content.userInfo = ["route": "createPerson"]
        schedule(content: content)
    }

    private func schedule(content: UNNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let nextRoute: AppRoute?
        if userInfo["route"] as? String == "person", let personId = userInfo["personId"] as? String {
            nextRoute = .person(personId)
        } else if userInfo["route"] as? String == "createPerson" {
            nextRoute = .createPerson
        } else {
            nextRoute = nil
        }

        await MainActor.run {
            route = nextRoute
        }
    }
}

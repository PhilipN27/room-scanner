import Combine
import Foundation
@preconcurrency import UserNotifications

@MainActor
final class AppleRoomMeshColoringNotificationAdapter: RoomMeshColoringNotificationAdapting {
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let authorizationAttemptedKey = "meshColoring.notificationAuthorizationAttempted.v1"

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
    }

    func requestAuthorizationIfNeeded() {
        guard !defaults.bool(forKey: authorizationAttemptedKey) else { return }
        defaults.set(true, forKey: authorizationAttemptedKey)
        center.getNotificationSettings { [center] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func schedule(
        _ milestone: RoomMeshColoringNotificationMilestone,
        projectID: String,
        roomName: String,
        generation: UUID,
        phaseTitle: String
    ) {
        let content = UNMutableNotificationContent()
        switch milestone {
        case .halfway:
            content.title = "Room coloring is halfway done"
            content.body = "\(roomName): \(phaseTitle)."
        case .complete:
            content.title = "Colored mesh is ready"
            content.body = "Open \(roomName) to view its colored mesh."
        case .interrupted:
            content.title = "Room coloring was interrupted"
            content.body = "Your original scan of \(roomName) is safe. Reopen RoomScanStudio to retry."
        }
        content.sound = .default
        content.userInfo = ["roomMeshProjectID": projectID]
        let identifier = Self.identifier(milestone: milestone, generation: generation)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func removePending(generation: UUID) {
        let identifiers = [
            RoomMeshColoringNotificationMilestone.halfway,
            .complete,
            .interrupted,
        ].map { Self.identifier(milestone: $0, generation: generation) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private static func identifier(
        milestone: RoomMeshColoringNotificationMilestone,
        generation: UUID
    ) -> String {
        "mesh-coloring.\(generation.uuidString.lowercased()).\(milestone.rawValue)"
    }
}

@MainActor
final class RoomMeshNotificationRouter: NSObject, ObservableObject, @preconcurrency UNUserNotificationCenterDelegate {
    @Published private(set) var requestedProjectID: String?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        requestedProjectID = response.notification.request.content.userInfo["roomMeshProjectID"] as? String
        completionHandler()
    }

    func consumeRequestedProjectID() {
        requestedProjectID = nil
    }
}

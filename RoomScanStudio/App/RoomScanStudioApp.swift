import SwiftUI

@main
struct RoomScanStudioApp: App {
    @StateObject private var environment: AppEnvironment

    init() {
        _environment = StateObject(wrappedValue: AppEnvironment())
    }

    var body: some Scene {
        WindowGroup {
            HomeView(environment: environment)
        }
    }
}

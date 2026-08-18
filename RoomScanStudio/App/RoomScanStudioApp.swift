import SwiftUI

@main
struct RoomScanStudioApp: App {
    @StateObject private var environment: AppEnvironment
    @StateObject private var slice3FixtureModel: RoomAIRedesignScreenFixtureModel
    private let showsSlice3Fixture: Bool
    private let slice3FixtureColorScheme: ColorScheme?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        _environment = StateObject(wrappedValue: AppEnvironment(arguments: arguments))
        _slice3FixtureModel = StateObject(wrappedValue: RoomAIRedesignScreenFixtureModel(
            readinessFailure: arguments.contains("--slice3-ui-fixture-readiness-failure")
        ))
        showsSlice3Fixture = arguments.contains("--slice3-ui-fixture")
        slice3FixtureColorScheme = arguments.contains("--slice3-ui-fixture-dark") ? .dark : nil
    }

    var body: some Scene {
        WindowGroup {
            if showsSlice3Fixture {
                RoomAIRedesignView(model: slice3FixtureModel)
                    .preferredColorScheme(slice3FixtureColorScheme)
            } else {
                HomeView(environment: environment)
            }
        }
    }
}

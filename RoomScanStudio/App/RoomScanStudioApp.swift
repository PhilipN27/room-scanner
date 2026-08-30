import SwiftUI

@main
struct RoomScanStudioApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var environment: AppEnvironment
    @StateObject private var slice3FixtureModel: RoomAIRedesignScreenFixtureModel
    private let showsSlice3Fixture: Bool
    private let showsSlice5ProfessionalFixture: Bool
    private let slice5FixtureArguments: [String]
    private let slice3FixtureColorScheme: ColorScheme?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        _environment = StateObject(wrappedValue: AppEnvironment(arguments: arguments))
        _slice3FixtureModel = StateObject(wrappedValue: RoomAIRedesignScreenFixtureModel(
            readinessFailure: arguments.contains("--slice3-ui-fixture-readiness-failure")
        ))
        showsSlice3Fixture = arguments.contains("--slice3-ui-fixture")
#if DEBUG
#if targetEnvironment(simulator)
        showsSlice5ProfessionalFixture = arguments.contains(
            "--slice5-professional-ui-fixture"
        )
#else
        showsSlice5ProfessionalFixture = false
#endif
#else
        showsSlice5ProfessionalFixture = false
#endif
        slice5FixtureArguments = arguments
        slice3FixtureColorScheme = arguments.contains("--slice3-ui-fixture-dark") ? .dark : nil
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showsSlice5ProfessionalFixture {
                    ProfessionalProjectSyncView(
                        model: .fixture(arguments: slice5FixtureArguments)
                    )
                } else if showsSlice3Fixture {
                    RoomAIRedesignView(model: slice3FixtureModel)
                        .preferredColorScheme(slice3FixtureColorScheme)
                } else {
                    HomeView(environment: environment)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    environment.handleProfessionalLifecycle(.foreground)
                case .inactive:
                    environment.handleProfessionalLifecycle(.inactive)
                case .background:
                    environment.handleProfessionalLifecycle(.background)
                @unknown default:
                    environment.handleProfessionalLifecycle(.inactive)
                }
            }
        }
    }
}

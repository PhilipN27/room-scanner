import SwiftUI

@main
struct RoomScanStudioApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var environment: AppEnvironment
    @StateObject private var slice3FixtureModel: RoomAIRedesignScreenFixtureModel
    private let showsSlice3Fixture: Bool
    private let showsSlice5ProfessionalFixture: Bool
    private let showsSlice6PublicationFixture: Bool
    private let slice5FixtureArguments: [String]
    private let slice6FixtureArguments: [String]
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
#if DEBUG
#if targetEnvironment(simulator)
        showsSlice6PublicationFixture = arguments.contains(
            "--slice6-publication-ui-fixture"
        )
#else
        showsSlice6PublicationFixture = false
#endif
#else
        showsSlice6PublicationFixture = false
#endif
        slice5FixtureArguments = arguments
        slice6FixtureArguments = arguments
        slice3FixtureColorScheme = arguments.contains("--slice3-ui-fixture-dark") ? .dark : nil
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showsSlice6PublicationFixture {
#if DEBUG
                    Slice6PublicationFixtureRoot(
                        mode: argumentsSpecifyPropertyFixture
                            ? .property : .room,
                        arguments: slice6FixtureArguments
                    )
#else
                    EmptyView()
#endif
                } else if showsSlice5ProfessionalFixture {
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
            .environmentObject(environment)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    environment.handleProfessionalLifecycle(.foreground)
                    Task(priority: .utility) {
                        // Awaits local retention, then refreshLibrary through
                        // the unit-tested scene orchestration seam.
                        await environment.purgeExpiredTrashAndRefreshLibrary()
                    }
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

    private var argumentsSpecifyPropertyFixture: Bool {
        slice6FixtureArguments.contains("--slice6-publication-ui-property")
    }
}

#if DEBUG
/// Own the deterministic publication fixture for the lifetime of this root.
/// Constructing an `@ObservedObject` inline in `App.body` lets scene/view
/// recomputation replace it while its asynchronous review is preparing,
/// leaving the replacement indefinitely in `.preparing` during UI tests.
private struct Slice6PublicationFixtureRoot: View {
    @StateObject private var model: RoomPublicationReviewModel

    init(mode: RoomPublicationReviewMode, arguments: [String]) {
        _model = StateObject(wrappedValue: .fixture(
            mode: mode,
            arguments: arguments
        ))
    }

    var body: some View {
        RoomPublicationReviewView(model: model)
    }
}
#endif

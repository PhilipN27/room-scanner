import SwiftUI

struct HomeView: View {
    private enum Route: Hashable {
        case existingRooms
        case newRoomScan
        case liveCapture
        case mockReview
        case roomDetail(String)
    }

    @ObservedObject var environment: AppEnvironment
    @State private var path: [Route] = []
    @State private var showingCloudBackup = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    supportReadout
                    if let bootstrapMessage = environment.bootstrapMessage {
                        bootstrapReadout(bootstrapMessage)
                    }
                    primaryActions
                    footer
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { destination in
                switch destination {
                case .existingRooms:
                    ExistingRoomsView(
                        controller: environment.libraryController,
                        rescanProvider: environment.rescanProvider,
                        exportCoordinator: environment.exportCoordinator,
                        cloudBackupCoordinator: environment.cloudBackupCoordinator,
                        meshColoringCoordinator: environment.meshColoringCoordinator,
                        privacyPolicyURL: environment.privacyPolicyURL
                    )
                case .newRoomScan:
                    NewRoomScanCapabilityView(
                        capabilityProvider: environment.capabilityProvider,
                        onOpenCapture: { path.append(.liveCapture) },
                        onOpenMockReview: { path.append(.mockReview) }
                    )
                case .liveCapture:
                    let coordinator = environment.acquireCaptureCoordinator()
                    RoomCaptureFlowView(
                        coordinator: coordinator,
                        sceneMeshAvailable: environment.capabilityProvider
                            .supportStatus
                            .sceneMeshAvailable,
                        onDiscard: {
                            path.removeAll()
                            environment.releaseCaptureCoordinator(coordinator)
                        },
                        onSaved: {
                            path = [.existingRooms]
                            environment.releaseCaptureCoordinator(coordinator)
                        }
                    )
                case .mockReview:
                    MockRoomReviewView(
                        controller: environment.libraryController,
                        onDiscard: { path.removeAll() },
                        onOpenLibrary: { path = [.existingRooms] }
                    )
                case let .roomDetail(projectID):
                    RoomDetailView(
                        projectID: projectID,
                        controller: environment.libraryController,
                        rescanProvider: environment.rescanProvider,
                        exportCoordinator: environment.exportCoordinator,
                        cloudBackupCoordinator: environment.cloudBackupCoordinator,
                        meshColoringCoordinator: environment.meshColoringCoordinator,
                        privacyPolicyURL: environment.privacyPolicyURL,
                        openColoredMeshOnAppear: true
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCloudBackup = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings and privacy")
                    .accessibilityHint("Opens private backup settings and this build's Privacy Policy status.")
                    .accessibilityIdentifier("home.cloudBackupSettings")
                }
            }
        }
        .tint(AppPalette.blueprint)
        .onChange(of: environment.meshNotificationRouter.requestedProjectID) { _, projectID in
            guard let projectID else { return }
            path = [.roomDetail(projectID)]
            environment.meshNotificationRouter.consumeRequestedProjectID()
        }
        .sheet(isPresented: $showingCloudBackup) {
            RoomCloudBackupSettingsView(
                coordinator: environment.cloudBackupCoordinator,
                privacyPolicyURL: environment.privacyPolicyURL
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ROOM / FIELD")
                .font(AppTypography.measurement)
                .tracking(2)
                .foregroundStyle(AppPalette.blueprint)

            Text("A calm record of the space you can stand inside.")
                .font(AppTypography.editorial)
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Room packages stay local unless you explicitly start private backup.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var supportReadout: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: supportSymbol)
                .font(AppTypography.symbol)
                .foregroundStyle(supportAccent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(environment.capabilityProvider.supportStatus.title)
                    .font(AppTypography.bodyEmphasized)
                    .foregroundStyle(AppPalette.ink)
                Text(environment.capabilityProvider.supportStatus.detail)
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(AppPalette.paperShadow.opacity(0.38), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("home.capabilityStatus")
    }

    private func bootstrapReadout(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(AppTypography.measurement)
            .foregroundStyle(AppPalette.amberOnDark)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.captureBlack, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("home.bootstrapIssue")
    }

    private var primaryActions: some View {
        AdaptiveActionRow(alignment: .leading, spacing: 14) {
            Button {
                path.append(.existingRooms)
            } label: {
                PrimaryActionLabel(
                    kicker: "LIBRARY",
                    title: "Existing Rooms",
                    detail: "Open local room profiles and immutable revisions.",
                    symbol: "square.stack.3d.up.fill",
                    accent: AppPalette.blueprintOnDark,
                    surface: AppPalette.graphite
                )
            }
            .buttonStyle(FieldActionButtonStyle())
            .accessibilityIdentifier("home.existingRooms")

            Button {
                path.append(.newRoomScan)
            } label: {
                PrimaryActionLabel(
                    kicker: "CAPTURE",
                    title: "New Room Scan",
                    detail: "Check capability, then explicitly start a live scan or review the deterministic fixture.",
                    symbol: "viewfinder",
                    accent: AppPalette.amberOnDark,
                    surface: AppPalette.captureBlack
                )
            }
            .buttonStyle(FieldActionButtonStyle())
            .accessibilityIdentifier("home.newRoomScan")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "ruler")
            Text("Measurements are estimates, not survey-grade evidence.")
        }
        .font(AppTypography.measurement)
        .foregroundStyle(AppPalette.mutedInk)
    }

    private var supportSymbol: String {
        switch environment.capabilityProvider.supportStatus {
        case .captureAvailable:
            return "checkmark.seal.fill"
        case .fixtureMode:
            return "cube.transparent"
        }
    }

    private var supportAccent: Color {
        switch environment.capabilityProvider.supportStatus {
        case .captureAvailable:
            return AppPalette.blueprint
        case .fixtureMode:
            return AppPalette.amber
        }
    }
}

private struct PrimaryActionLabel: View {
    let kicker: String
    let title: String
    let detail: String
    let symbol: String
    let accent: Color
    let surface: Color

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(AppTypography.symbol)
                .foregroundStyle(accent)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 5) {
                Text(kicker)
                    .font(AppTypography.measurement)
                    .tracking(1.4)
                    .foregroundStyle(accent)
                Text(title)
                    .font(AppTypography.section)
                    .foregroundStyle(AppPalette.primaryOnDark)
                Text(detail)
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedOnDark)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Image(systemName: "arrow.up.right")
                .font(AppTypography.calloutEmphasized)
                .foregroundStyle(AppPalette.primaryOnDark)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct FieldActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

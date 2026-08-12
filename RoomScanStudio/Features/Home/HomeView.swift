import SwiftUI
import RoomScanCore

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
    @State private var capabilityDetailExpanded = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    titleMasthead
                    if let bootstrapMessage = environment.bootstrapMessage {
                        bootstrapReadout(bootstrapMessage)
                    }
                    primaryActions
                    footer
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
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
        .task {
            // The Rooms surface shows a live count and the most recent
            // room's thumbnail; ExistingRoomsView refreshed on its own
            // appear, but Home must refresh too or the count/thumbnail go
            // stale until the library screen happens to be opened.
            await environment.libraryController.refreshLibrary()
        }
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

    // MARK: - Masthead

    /// Centered app masthead: the app name set large in the serif editorial
    /// voice, framed by hairline rules, with the capability chip beneath it.
    private var titleMasthead: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                Text("ROOM / FIELD")
                    .font(AppTypography.measurement)
                    .tracking(3)
                    .foregroundStyle(AppPalette.blueprint)
                Text("Room Scan Studio")
                    .font(AppTypography.display)
                    .foregroundStyle(AppPalette.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home.appTitle")
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(AppPalette.paperShadow)
                        .frame(height: 1)
                    Image(systemName: "viewfinder")
                        .font(.caption)
                        .foregroundStyle(AppPalette.blueprint)
                    Rectangle()
                        .fill(AppPalette.paperShadow)
                        .frame(height: 1)
                }
                .frame(maxWidth: 260)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)

            capabilityChip

            if capabilityDetailExpanded {
                capabilityDetail
            }
        }
        .padding(.top, 4)
    }

    /// Compact icon + one-word chip. Tapping expands the full capability
    /// detail below the rail — the real-capture vs deterministic-fixture
    /// distinction stays discoverable without occupying permanent space.
    private var capabilityChip: some View {
        Button {
            let toggle = { capabilityDetailExpanded.toggle() }
            if reduceMotion {
                toggle()
            } else {
                withAnimation(.easeOut(duration: 0.18), toggle)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: supportSymbol)
                Text(capabilityChipWord)
            }
            .font(AppTypography.measurement)
            .tracking(0.6)
            .foregroundStyle(supportAccent)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(AppPalette.paperShadow.opacity(0.42), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(environment.capabilityProvider.supportStatus.title)
        .accessibilityHint(capabilityDetailExpanded ? "Collapses capability detail" : "Expands capability detail")
        .accessibilityIdentifier("home.capabilityChip")
    }

    private var capabilityDetail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(environment.capabilityProvider.supportStatus.title)
                .font(AppTypography.bodyEmphasized)
                .foregroundStyle(AppPalette.ink)
            Text(environment.capabilityProvider.supportStatus.detail)
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.paperShadow.opacity(0.38), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("home.capabilityStatus")
        .transition(reduceMotion ? .identity : .opacity)
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

    // MARK: - Primary surfaces

    /// Compact width stacks the two surfaces with content-driven heights.
    /// Regular width composes them asymmetrically, Rooms dominant, per the
    /// design spec's two-column instruction.
    private var primaryActions: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 20) {
                    roomsSurface
                    scanSurface
                        .frame(maxWidth: 340)
                }
            } else {
                VStack(spacing: 14) {
                    roomsSurface
                    scanSurface
                }
            }
        }
    }

    private var roomsSurface: some View {
        Button {
            path.append(.existingRooms)
        } label: {
            RoomsLibrarySurface(
                roomCount: activeRoomCount,
                thumbnailData: mostRecentRoomThumbnailData
            )
        }
        .buttonStyle(FieldActionButtonStyle())
        .accessibilityIdentifier("home.existingRooms")
    }

    private var scanSurface: some View {
        Button {
            path.append(.newRoomScan)
        } label: {
            PrimaryActionLabel(
                kicker: "CAPTURE",
                title: "Scan a room",
                detail: scanCapabilitySummary,
                symbol: "viewfinder",
                accent: AppPalette.amberOnDark,
                surface: AppPalette.captureBlack
            )
        }
        .buttonStyle(FieldActionButtonStyle())
        .accessibilityIdentifier("home.newRoomScan")
    }

    private var scanCapabilitySummary: String {
        environment.capabilityProvider.supportStatus.canStartLiveCapture
            ? "Live RoomPlan capture is available on this device."
            : "Deterministic fixture review only — no live capture on this device."
    }

    /// The user-facing room total. Bundled fixtures (the mock room, the
    /// simulated-capture room) carry a "fixture" tag when saved and are
    /// deliberately excluded: only rooms the user actually captured count.
    private var activeRoomCount: Int {
        environment.libraryController.summaries
            .filter { !$0.archived && !$0.tags.contains("fixture") }
            .count
    }

    private var mostRecentRoomSummary: RoomProjectSummary? {
        environment.libraryController.summaries
            .filter { !$0.archived }
            .max { $0.lastRevisedDate < $1.lastRevisedDate }
    }

    private var mostRecentRoomThumbnailData: Data? {
        guard let projectID = mostRecentRoomSummary?.projectID else { return nil }
        return environment.libraryController.thumbnailData(for: projectID)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Room packages stay local unless you explicitly start private backup.",
                systemImage: "lock.shield"
            )
            Label(
                "Measurements are estimates, not survey-grade evidence.",
                systemImage: "ruler"
            )
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

    private var capabilityChipWord: String {
        switch environment.capabilityProvider.supportStatus {
        case .captureAvailable:
            return "READY"
        case .fixtureMode:
            return "FIXTURE"
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

/// The dominant Rooms surface: an actual cached room image (or floor-plan-
/// derived fallback via `RoomThumbnailView`), a live room count, and a
/// chevron — never the headline paragraph the prior design used.
private struct RoomsLibrarySurface: View {
    let roomCount: Int
    let thumbnailData: Data?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RoomThumbnailView(
                data: thumbnailData,
                fallbackSymbol: "square.stack.3d.up.fill",
                accessibilityIdentifier: "home.existingRooms.thumbnail",
                sideLength: 64,
                emptyBackgroundColor: AppPalette.captureBlack.opacity(0.5)
            )

            VStack(alignment: .leading, spacing: 5) {
                Text("LIBRARY")
                    .font(AppTypography.measurement)
                    .tracking(1.4)
                    .foregroundStyle(AppPalette.blueprintOnDark)
                Text("Rooms")
                    .font(AppTypography.section)
                    .foregroundStyle(AppPalette.primaryOnDark)
                Text(roomCount == 1 ? "1 room" : "\(roomCount) rooms")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedOnDark)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(AppTypography.calloutEmphasized)
                .foregroundStyle(AppPalette.primaryOnDark)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.graphite, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

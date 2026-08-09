import SwiftUI
import RoomScanCore

enum RoomRescanFlowPresentationState: Equatable {
    case loading
    case error
    case unavailable
    case preview
    case accepted
}

/// A tiny presentation seam makes a failed Accept unambiguously visible even
/// while the transient proposal remains in memory for diagnostics/retry.
enum RoomRescanFlowPresentation {
    static func state(
        acceptedRevisionID: String?,
        unavailableReason: RoomRescanUnavailableReason?,
        hasProposal: Bool,
        errorMessage: String?
    ) -> RoomRescanFlowPresentationState {
        if acceptedRevisionID != nil {
            return .accepted
        }
        if errorMessage != nil {
            return .error
        }
        if unavailableReason != nil {
            return .unavailable
        }
        return hasProposal ? .preview : .loading
    }

    static func statusText(for state: RoomRescanFlowPresentationState) -> String {
        switch state {
        case .accepted:
            return "Fixture rescan accepted"
        case .error:
            return "The fixture rescan could not be accepted."
        case .unavailable:
            return "Rescan unavailable"
        case .preview:
            return "Review deterministic proposal"
        case .loading:
            return "Checking registration evidence"
        }
    }
}

/// A fixture-only proposal review. This view never opens a camera, starts AR,
/// or invokes a generic `.rescan` append. Only its explicit Accept calls the
/// store-owned recomputation/transaction path.
struct RoomRescanFlowView: View {
    let projectID: String
    @ObservedObject var controller: RoomLibraryController
    let provider: any RoomRescanProviding
    let onAccepted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var proposal: RoomFixtureRescanProposal?
    @State private var unavailableReason: RoomRescanUnavailableReason?
    @State private var errorMessage: String?
    @State private var acceptedRevisionID: String?
    @State private var isAccepting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("RESCAN / REVIEW")
                        .font(AppTypography.measurement)
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.blueprint)

                    Text(statusText)
                        .font(AppTypography.editorial)
                        .foregroundStyle(AppPalette.ink)
                        .accessibilityIdentifier("rescan.status")

                    switch presentationState {
                    case .accepted:
                        if let acceptedRevisionID {
                            acceptedContent(revisionID: acceptedRevisionID)
                        }
                    case .error:
                        if let errorMessage {
                            errorContent(errorMessage)
                        }
                    case .unavailable:
                        if let unavailableReason {
                            unavailableContent(reason: unavailableReason)
                        }
                    case .preview:
                        if let proposal {
                            previewContent(proposal)
                        }
                    case .loading:
                        ProgressView("Validating deterministic rescan fixture...")
                            .tint(AppPalette.blueprint)
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("Rescan")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await prepare()
            }
        }
    }

    @ViewBuilder
    private func unavailableContent(reason: RoomRescanUnavailableReason) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(reason.message, systemImage: "lock.trianglebadge.exclamationmark")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.amberOnDark)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rescan.unavailable")

            Text("A rescan candidate is valid only if one of these registrations is proven: 1. continuous capture in the original app-owned ARSession, or 2. successful relocalization against a recorded ARWorldMap.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedOnDark)
                .fixedSize(horizontal: false, vertical: true)

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("rescan.undo")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.captureBlack, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func previewContent(_ proposal: RoomFixtureRescanProposal) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DETERMINISTIC FIXTURE PREVIEW")
                .font(AppTypography.section)
                .foregroundStyle(AppPalette.ink)
                .accessibilityIdentifier("rescan.preview")

            Text("This simulated proposal preserves durable element IDs, replaces only matched candidate geometry and provenance, and does not merge vertices or create a live registration claim.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(proposal.preview.changes) { change in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(change.elementID) / \(change.kind.rawValue)")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.blueprint)
                        Text("\(change.oldValue) -> \(change.newValue)")
                            .font(AppTypography.callout)
                            .foregroundStyle(AppPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            if proposal.preview.measurementsRemainUnrevalidated {
                Label(proposal.preview.measurementsNotice, systemImage: "ruler")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AdaptiveActionRow(alignment: .leading, spacing: 12) {
                Button("Undo proposal") {
                    // Preview is transient. Undo intentionally makes no store
                    // call and therefore allocates no revision ID.
                    dismiss()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("rescan.undo")

                Button(isAccepting ? "Accepting..." : "Accept fixture rescan") {
                    Task { await accept(proposal) }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.primaryAction)
                .disabled(isAccepting)
                .accessibilityIdentifier("rescan.accept")
            }
        }
    }

    @ViewBuilder
    private func acceptedContent(revisionID: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Accepted as immutable \(revisionID).", systemImage: "checkmark.seal.fill")
                .font(AppTypography.section)
                .foregroundStyle(AppPalette.blueprint)
                .accessibilityIdentifier("rescan.accepted")
            Text("The original revision remains unchanged. A later revert creates another immutable child; it does not erase this rescan.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("Return to room profile") {
                onAccepted()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.primaryAction)
            .accessibilityIdentifier("rescan.done")
        }
    }

    @ViewBuilder
    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.amber)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("rescan.undo")
        }
    }

    private var statusText: String {
        RoomRescanFlowPresentation.statusText(for: presentationState)
    }

    private var presentationState: RoomRescanFlowPresentationState {
        RoomRescanFlowPresentation.state(
            acceptedRevisionID: acceptedRevisionID,
            unavailableReason: unavailableReason,
            hasProposal: proposal != nil,
            errorMessage: errorMessage
        )
    }

    private func prepare() async {
        do {
            let package = try await controller.loadPackage(projectID: projectID)
            let availability = await provider.availability(for: package)
            switch availability {
            case let .available(nextProposal):
                proposal = nextProposal
                unavailableReason = nil
                errorMessage = nil
            case let .unavailable(reason):
                proposal = nil
                unavailableReason = reason
                errorMessage = nil
            }
        } catch {
            errorMessage = "The local package could not be loaded for a rescan proposal."
        }
    }

    private func accept(_ proposal: RoomFixtureRescanProposal) async {
        isAccepting = true
        defer { isAccepting = false }
        do {
            let manifest = try await controller.acceptFixtureRescan(
                projectID: projectID,
                expectedHeadRevisionID: proposal.expectedHeadRevisionID,
                proposal: proposal
            )
            acceptedRevisionID = manifest.revisionID
            errorMessage = nil
        } catch {
            errorMessage = "The fixture rescan could not be accepted. The original immutable revision remains current."
        }
    }
}

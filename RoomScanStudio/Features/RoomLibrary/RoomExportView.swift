import SwiftUI
import UIKit
import RoomScanCore

/// Explicit head-revision export presentation. It does not imply a project
/// backup: prior revisions and package metadata/history are excluded.
struct RoomExportView: View {
    let projectID: String
    let expectedHeadRevisionID: String
    @ObservedObject var coordinator: RoomExportCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var presentingShare = false
    @State private var shareCompletionHandled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("HEAD REVISION EXPORT")
                        .font(AppTypography.section)
                        .foregroundStyle(AppPalette.ink)
                    Text("Creates an inspectable handoff of the current immutable head revision only. It is not a backup and never changes the local room package.")
                        .font(AppTypography.body)
                        .foregroundStyle(AppPalette.mutedInk)

                    Label("Includes normalized JSON, referenced photos, thumbnail, declared native USDZ when present, a bounded semantic floor plan PNG, a one-page PDF summary, and a manifest.", systemImage: "archivebox")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.ink)

                    Label("GLB, OBJ, and PLY are skipped: no verified converter is included.", systemImage: "info.circle")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedInk)

                    controls
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task { await closeExport() }
                    }
                        .disabled(coordinator.state == .preparing)
                }
            }
        }
        .onDisappear {
            // Navigation/system dismissal can bypass the toolbar. Do not clean
            // while the UIKit share sheet owns the active finalized URL.
            guard !presentingShare, coordinator.state == .ready else { return }
            Task { _ = await coordinator.discardPreparedExport() }
        }
        .interactiveDismissDisabled(
            coordinator.state == .preparing
                || coordinator.state == .ready
                || coordinator.state == .cleanupFailed
        )
        .sheet(isPresented: $presentingShare, onDismiss: {
            guard !shareCompletionHandled else { return }
            shareCompletionHandled = true
            Task { await coordinator.completeShare(completed: false) }
        }) {
            if let result = coordinator.readyResult {
                RoomExportShareSheet(archiveURL: result.archiveURL) { completed in
                    shareCompletionHandled = true
                    presentingShare = false
                    Task { await coordinator.completeShare(completed: completed) }
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch coordinator.state {
        case .idle:
            Button("Prepare head export") {
                Task {
                    await coordinator.prepare(
                        projectID: projectID,
                        expectedHeadRevisionID: expectedHeadRevisionID
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.primaryAction)
            .accessibilityIdentifier("export.prepare")
        case .preparing:
            ProgressView("Freezing head revision and building export...")
                .tint(AppPalette.blueprint)
                .accessibilityIdentifier("export.preparing")
        case .ready:
            VStack(alignment: .leading, spacing: 10) {
                Label("Head export is ready. The temporary archive remains available until sharing is finished or cancelled.", systemImage: "checkmark.seal")
                    .foregroundStyle(AppPalette.blueprint)
                    .font(AppTypography.measurement)
                AdaptiveActionRow(alignment: .leading, spacing: 10) {
                    Button("Share head export") {
                        shareCompletionHandled = false
                        presentingShare = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.primaryAction)
                    .accessibilityIdentifier("export.share")
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Label(coordinator.errorMessage ?? "Export preparation failed.", systemImage: "exclamationmark.triangle")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("export.error")
                Button("Try again") {
                    coordinator.resetFailure()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("export.retry")
            }
        case .cleanupFailed:
            VStack(alignment: .leading, spacing: 10) {
                Label(coordinator.errorMessage ?? "Temporary export cleanup failed.", systemImage: "exclamationmark.triangle")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("export.error")
                Button("Retry cleanup") {
                    Task { await coordinator.retryCleanup() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("export.retryCleanup")
            }
        }
    }

    private func closeExport() async {
        switch coordinator.state {
        case .ready, .cleanupFailed:
            guard await coordinator.discardPreparedExport() else { return }
            dismiss()
        case .idle, .failed:
            dismiss()
        case .preparing:
            return
        }
    }
}

/// UIKit is used for the native Files/share handoff so the finalized URL and
/// owned lease survive until its completion callback. `ShareLink` intentionally
/// is not used because it does not offer this scoped lifetime control.
struct RoomExportShareSheet: UIViewControllerRepresentable {
    let archiveURL: URL
    let onCompletion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [archiveURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onCompletion(completed)
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = controller.view.bounds
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

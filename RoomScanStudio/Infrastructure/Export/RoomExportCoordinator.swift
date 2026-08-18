import Combine
import Foundation
import RoomScanCore

struct RoomExportResult: Equatable {
    let archiveURL: URL
    let workspaceURL: URL
    let receipt: RoomExportReceipt
}

/// A provider may fail while it still owns a scoped lease. The coordinator
/// keeps that exact URL only for retrying the same narrow cleanup operation;
/// it never broad-cleans the export root.
struct RoomExportLeaseCleanupError: Error {
    let workspaceURL: URL
    let message: String
}

@MainActor
protocol RoomExportProviding {
    func exportHead(
        projectID: String,
        expectedHeadRevisionID: String
    ) async throws -> RoomExportResult
}

@MainActor
protocol RoomExportWorkspaceCleaning {
    func cleanup(workspaceURL: URL) throws
}

enum RoomExportCoordinatorState: Equatable {
    case idle
    case preparing
    case ready
    case failed
    case cleanupFailed
}

/// The only durable result needed from a system Share Sheet. UIKit's optional
/// activity type and returned items are intentionally not retained, and an
/// actual callback error takes precedence over the completion flag.
enum SystemShareSheetOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed

    init(completed: Bool, error: Error?) {
        if error != nil {
            self = .failed
        } else {
            self = completed ? .completed : .cancelled
        }
    }
}

/// Owns the finalized archive lifetime through the system share completion.
/// Cancelling the share sheet still cleans the lease; a cleanup failure remains
/// actionable rather than silently retaining an unbounded scratch directory.
@MainActor
final class RoomExportCoordinator: ObservableObject {
    @Published private(set) var state: RoomExportCoordinatorState = .idle
    @Published private(set) var readyResult: RoomExportResult?
    @Published private(set) var errorMessage: String?

    private let provider: any RoomExportProviding
    private let cleaner: any RoomExportWorkspaceCleaning
    private var cleanupWorkspaceURL: URL?
    private var pendingShareOutcome: SystemShareSheetOutcome?

    init(
        provider: any RoomExportProviding,
        cleaner: any RoomExportWorkspaceCleaning
    ) {
        self.provider = provider
        self.cleaner = cleaner
    }

    func prepare(projectID: String, expectedHeadRevisionID: String) async {
        guard state == .idle || state == .failed else { return }
        state = .preparing
        readyResult = nil
        cleanupWorkspaceURL = nil
        pendingShareOutcome = nil
        errorMessage = nil
        do {
            readyResult = try await provider.exportHead(
                projectID: projectID,
                expectedHeadRevisionID: expectedHeadRevisionID
            )
            state = .ready
        } catch let error as RoomExportError {
            errorMessage = message(for: error)
            state = .failed
        } catch let error as RoomExportLeaseCleanupError {
            cleanupWorkspaceURL = error.workspaceURL
            errorMessage = error.message
            state = .cleanupFailed
        } catch {
            errorMessage = "The head revision could not be prepared for export. The room package was not changed."
            state = .failed
        }
    }

    func completeShare(outcome: SystemShareSheetOutcome) async {
        // UIKit may deliver both its terminal callback and a presentation
        // dismissal. Only the first terminal outcome owns this exact lease;
        // cleanup retries remain an explicit user action after a failure.
        guard state == .ready, let result = readyResult else { return }
        pendingShareOutcome = outcome
        do {
            try cleaner.cleanup(workspaceURL: result.workspaceURL)
            finishCleanup(shareOutcome: outcome)
        } catch {
            errorMessage = "The Share Sheet closed, but its temporary handoff workspace could not be removed. Retry cleanup."
            state = .cleanupFailed
        }
    }

    /// Compatibility entry point for legacy callers that only observed the
    /// completion flag. Cancellation remains terminal and still cleans.
    func completeShare(completed: Bool) async {
        await completeShare(outcome: completed ? .completed : .cancelled)
    }

    func retryCleanup() async {
        guard state == .cleanupFailed,
              let workspaceURL = readyResult?.workspaceURL ?? cleanupWorkspaceURL
        else { return }
        do {
            try cleaner.cleanup(workspaceURL: workspaceURL)
            finishCleanup(shareOutcome: pendingShareOutcome)
        } catch {
            errorMessage = "Temporary export cleanup still needs attention. The room package remains unchanged."
        }
    }

    /// Closes an unshared ready archive only after its exact lease has been
    /// cleaned. A failed cleanup leaves the view open with a retry action.
    func discardPreparedExport() async -> Bool {
        guard state == .ready || state == .cleanupFailed else {
            return state == .idle
        }
        if state == .cleanupFailed {
            await retryCleanup()
            return state == .idle
        }
        guard let result = readyResult else { return false }
        do {
            try cleaner.cleanup(workspaceURL: result.workspaceURL)
            readyResult = nil
            cleanupWorkspaceURL = nil
            pendingShareOutcome = nil
            errorMessage = nil
            state = .idle
            return true
        } catch {
            errorMessage = "The temporary export workspace could not be removed. Retry cleanup before closing."
            state = .cleanupFailed
            return false
        }
    }

    func resetFailure() {
        guard state == .failed else { return }
        state = .idle
        pendingShareOutcome = nil
        errorMessage = nil
    }

    private func finishCleanup(shareOutcome: SystemShareSheetOutcome?) {
        readyResult = nil
        cleanupWorkspaceURL = nil
        pendingShareOutcome = nil
        switch shareOutcome {
        case .failed:
            errorMessage = "The Share Sheet could not complete the export handoff. Its temporary workspace was removed. Prepare the export and try again."
            state = .failed
        case .completed, .cancelled, nil:
            errorMessage = nil
            state = .idle
        }
    }

    private func message(for error: RoomExportError) -> String {
        switch error {
        case .staleHead:
            return "This room changed before export. Refresh the profile and prepare the current head again."
        case .legacyPlanlessEvidence:
            return "This historical revision has plan-less evidence and cannot be presented as a complete head export."
        case .missingRequiredArtifact:
            return "A required export artifact could not be prepared. The room package was not changed."
        case .sourceChangedAfterPreflight:
            return "The frozen export workspace changed while it was being checked. Try again."
        case .cleanupFailed:
            return "The temporary export workspace could not be removed. Retry cleanup."
        default:
            return "The head revision could not be prepared for export. The room package was not changed."
        }
    }
}

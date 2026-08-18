import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The production-only shell around the reusable redesign screen. It owns
/// UIKit-backed system presentations and returns their typed results to the
/// model; it never reads or transforms selected media itself.
@MainActor
struct RoomAIRedesignHostView: View {
    @ObservedObject var model: RoomAIRedesignProductionModel
    @Environment(\.dismiss) private var dismiss

    @State private var importSession: ImportSession?
    @State private var shareRequest: RoomAISharePresentationRequest?
    @State private var hostError: String?

    var body: some View {
        RoomAIRedesignView(model: model)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                        .accessibilityIdentifier("ai.close")
                        .disabled(model.sharePresentationRequest != nil || model.reviewState == .approved)
                }
            }
            .fileImporter(
                isPresented: importPresentation,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: false,
                onCompletion: finishFileImport
            )
            .sheet(item: $shareRequest, onDismiss: shareSheetDismissed) { request in
                SystemShareSheet(activityItems: [request.archiveURL]) { outcome in
                    finishShare(requestID: request.id, outcome: outcome)
                }
                .accessibilityIdentifier("ai.systemShareSheet")
            }
            .alert("Couldn’t open that file", isPresented: hostErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(hostError ?? "Choose another local file and try again.")
            }
            .overlay(alignment: .bottom) {
                if let message = model.reviewMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial)
                        .accessibilityLabel("AI Room Package status: \(message)")
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .onReceive(model.$fileImportRequest) { request in
                guard let request else { return }
                // A request is captured once, so repeated SwiftUI presentation
                // transitions cannot cause duplicate model callbacks.
                guard importSession == nil else { return }
                importSession = .init(request: request)
            }
            .onReceive(model.$sharePresentationRequest) { request in
                shareRequest = request
            }
            .interactiveDismissDisabled(shouldPreventInteractiveDismissal)
    }

    private var importPresentation: Binding<Bool> {
        Binding(
            get: { importSession != nil },
            set: { isPresented in
                guard !isPresented else { return }
                cancelFileImportIfNeeded()
            }
        )
    }

    private var allowedContentTypes: [UTType] {
        switch importSession?.request {
        case .conceptPackage:
            [.zip]
        case .looseConcept, .replacementImage:
            [.jpeg, .png]
        case nil:
            // SwiftUI evaluates this before the request arrives. Keep the
            // default conservative; it is replaced before presentation.
            [.jpeg, .png]
        }
    }

    private var hostErrorPresented: Binding<Bool> {
        Binding(
            get: { hostError != nil },
            set: { if !$0 { hostError = nil } }
        )
    }

    private var shouldPreventInteractiveDismissal: Bool {
        Self.preventsInteractiveDismissal(
            reviewState: model.reviewState,
            reviewInputsLocked: model.reviewInputsLocked
        )
    }

    static func preventsInteractiveDismissal(
        reviewState: RoomAIReviewState,
        reviewInputsLocked: Bool
    ) -> Bool {
        switch reviewState {
        case .drafting, .stale:
            reviewInputsLocked
        case .readyForReview, .approved, .archiveReady, .cleanupFailed:
            true
        }
    }

    private func finishFileImport(_ result: Result<[URL], Error>) {
        guard importSession != nil else { return }
        importSession = nil
        switch result {
        case let .success(urls):
            guard let url = urls.first, urls.count == 1 else {
                model.cancelFileImport()
                hostError = "Choose exactly one local file."
                return
            }
            model.completeFileImport(url: url)
        case let .failure(error):
            model.cancelFileImport()
            guard !isUserCancellation(error) else { return }
            hostError = error.localizedDescription
        }
    }

    private func cancelFileImportIfNeeded() {
        guard importSession != nil else { return }
        importSession = nil
        model.cancelFileImport()
    }

    private func finishShare(requestID: UUID, outcome: SystemShareSheetOutcome) {
        guard shareRequest?.id == requestID,
              model.sharePresentationRequest?.id == requestID else { return }
        shareRequest = nil
        model.completeSystemShare(outcome: outcome)
    }

    private func shareSheetDismissed() {
        // UIKit's completion handler is the terminal, typed outcome. This
        // fallback only handles a system dismissal path that did not invoke it.
        guard let request = model.sharePresentationRequest else { return }
        finishShare(requestID: request.id, outcome: .cancelled)
    }

    private func close() {
        Task {
            guard await model.discardPreparedArchive() else { return }
            dismiss()
        }
    }

    private func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}

private struct ImportSession: Identifiable, Equatable {
    let id = UUID()
    let request: RoomAIConceptFileImportRequest
}

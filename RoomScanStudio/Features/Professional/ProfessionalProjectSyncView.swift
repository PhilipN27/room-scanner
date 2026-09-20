import Combine
import Foundation
import RoomScanCore
import SwiftUI

@MainActor
final class ProfessionalProjectSyncViewModel: ObservableObject, Identifiable {
    struct ProjectChoice: Identifiable, Equatable {
        let id: String
        let name: String
        let headRevisionID: String
    }

    struct PreviewFacts: Equatable {
        struct Category: Identifiable, Equatable {
            let id: String
            let label: String
            let itemCount: Int
            let byteCount: UInt64
        }

        let roomName: String
        let localHeadRevisionID: String
        let archiveSHA256: String
        let archiveByteCount: UInt64
        let categories: [Category]
        let excludedRawClasses: [String]
    }

    struct ConflictFacts: Equatable {
        let hostedProjectID: String
        let canonicalRevisionID: String
        let staleRevisionID: String
    }

    struct ComparisonFacts: Equatable {
        let canonicalHeadRevisionID: String
        let staleHeadRevisionID: String
        let canonicalRevisionCount: Int
        let staleRevisionCount: Int
        let canonicalSemanticSHA256: String
        let staleSemanticSHA256: String
        let differs: Bool
    }

    struct RawReviewFacts: Equatable {
        struct Category: Identifiable, Equatable {
            let id: String
            let label: String
            let itemCount: Int
            let byteCount: UInt64
        }

        let sourceRevisionID: String
        let totalByteCount: UInt64
        let selectionSHA256: String
        let categories: [Category]
    }

    enum Surface: Equatable {
        case idle
        case localDraft
        case preview
        case canonical
        case conflict
        case awaitingUserEdit
        case rejected
        case recoveryReady
        case rawReview
    }

    let id = UUID()
    @Published private(set) var projects: [ProjectChoice] = []
    @Published var selectedProjectID: String?
    @Published private(set) var surface: Surface = .idle
    @Published private(set) var previewFacts: PreviewFacts?
    @Published private(set) var conflictFacts: ConflictFacts?
    @Published private(set) var comparisonFacts: ComparisonFacts?
    @Published private(set) var rawReviewFacts: RawReviewFacts?
    @Published private(set) var isWorking = false
    @Published private(set) var progressMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var outcomeMessage: String?
    @Published private(set) var canRetryUpload = false
    @Published private(set) var leaseExpiresAt: Date?

    private let live: ProfessionalProjectSyncWorkspaceDependencies?
    private var retainedPreview: ProfessionalProjectSyncPreview?
    private var retainedConflict: ProfessionalProjectSyncConflict?
    private var retainedRawReview: ProfessionalProjectRawReview?
    private var hasLoaded = false

    init(dependencies: ProfessionalProjectSyncWorkspaceDependencies) {
        live = dependencies
    }

    private init(fixture arguments: [String]) {
        live = nil
        projects = [ProjectChoice(
            id: "project-field-studio",
            name: "Field studio — north room",
            headRevisionID: "revision-local-0042"
        )]
        selectedProjectID = projects.first?.id
        if arguments.contains("--slice5-professional-ui-conflict") {
            surface = .conflict
            conflictFacts = ConflictFacts(
                hostedProjectID: "prj_01J8FIELDSTUDIO42",
                canonicalRevisionID: "rev_01J8CANONICAL0043",
                staleRevisionID: "rev_01J8OFFLINE00042"
            )
            outcomeMessage = "Both immutable revisions are retained. Choose how to continue."
        } else if arguments.contains("--slice5-professional-ui-raw") {
            surface = .rawReview
            rawReviewFacts = RawReviewFacts(
                sourceRevisionID: "revision-local-0042",
                totalByteCount: 1_842_438_912,
                selectionSHA256: String(repeating: "7", count: 64),
                categories: [
                    .init(id: "rgb", label: "RGB frames", itemCount: 184, byteCount: 1_296_121_344),
                    .init(id: "depth", label: "Depth", itemCount: 184, byteCount: 482_344_960),
                    .init(id: "confidence", label: "Confidence", itemCount: 184, byteCount: 61_341_696),
                    .init(id: "diagnostics", label: "Diagnostics", itemCount: 3, byteCount: 2_630_912),
                ]
            )
        } else {
            surface = .preview
            previewFacts = PreviewFacts(
                roomName: "Field studio — north room",
                localHeadRevisionID: "revision-local-0042",
                archiveSHA256: String(repeating: "a", count: 64),
                archiveByteCount: 18_874_368,
                categories: [
                    .init(id: "package", label: "Room package", itemCount: 1, byteCount: 17_991_680),
                    .init(id: "redesign", label: "Redesign state", itemCount: 1, byteCount: 48_128),
                    .init(id: "concepts", label: "Concept Sets", itemCount: 7, byteCount: 834_560),
                ],
                excludedRawClasses: ["RGB", "Depth", "Confidence", "Diagnostics"]
            )
            if arguments.contains("--slice5-professional-ui-retry") {
                canRetryUpload = true
                errorMessage = "Upload paused before acknowledgement. The immutable preview is still available for an exact retry."
            }
        }
        hasLoaded = true
    }

    static func fixture(arguments: [String]) -> ProfessionalProjectSyncViewModel {
        ProfessionalProjectSyncViewModel(fixture: arguments)
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let live else { return }
        await live.libraryController.refreshLibrary()
        projects = live.libraryController.summaries
            .filter { !$0.archived }
            .map { ProjectChoice(
                id: $0.projectID,
                name: $0.customName,
                headRevisionID: $0.headRevisionID
            ) }
        if selectedProjectID == nil {
            selectedProjectID = projects.first?.id
        }
        await refreshSelectedProject()
    }

    func selectProject(_ projectID: String) async {
        guard projectID != selectedProjectID else { return }
        discardPreview()
        selectedProjectID = projectID
        resetTransientState()
        await refreshSelectedProject()
    }

    func refreshSelectedProject() async {
        guard let live, let projectID = selectedProjectID else { return }
        await perform("Checking the local immutable head…") {
            let state = try await live.service.refresh(projectID: projectID)
            self.apply(state)
        }
    }

    func preparePreview() async {
        guard let live, let projectID = selectedProjectID else { return }
        discardPreview()
        await perform("Staging and validating the recoverable working set…") {
            let preview = try await live.service.previewMigration(projectID: projectID)
            self.retainedPreview = preview
            self.previewFacts = Self.previewFacts(preview)
            self.surface = .preview
            self.canRetryUpload = false
            self.outcomeMessage = nil
        }
    }

    func approvePreview() async {
        await uploadPreview(isRetry: false)
    }

    func retryPreview() async {
        await uploadPreview(isRetry: true)
    }

    func compareBranches() {
        guard let live, let conflict = retainedConflict else {
            if live == nil {
                comparisonFacts = ComparisonFacts(
                    canonicalHeadRevisionID: "revision-canonical-0043",
                    staleHeadRevisionID: "revision-local-0042",
                    canonicalRevisionCount: 43,
                    staleRevisionCount: 42,
                    canonicalSemanticSHA256: String(repeating: "c", count: 64),
                    staleSemanticSHA256: String(repeating: "d", count: 64),
                    differs: true
                )
            }
            return
        }
        Task {
            await perform("Validating both immutable branch packages…") {
                self.comparisonFacts = Self.comparisonFacts(
                    try await live.service.compare(conflict)
                )
            }
        }
    }

    func rebaseFromCanonical() async {
        guard let live, let conflict = retainedConflict else {
            if live == nil {
                surface = .awaitingUserEdit
                outcomeMessage = "Canonical head recovered as a separate local copy. Save an edit before appending."
            }
            return
        }
        await perform("Recovering the canonical head through package validation…") {
            let result = try await live.service.startRebaseFromHostedHead(conflict)
            await live.libraryController.refreshLibrary()
            self.surface = .awaitingUserEdit
            self.outcomeMessage = "Recovered \(result.projectSummary.customName) as a separate local copy. Save a child revision before uploading."
        }
    }

    func duplicateStaleBranch() async {
        guard let live, let conflict = retainedConflict else {
            if live == nil {
                surface = .awaitingUserEdit
                outcomeMessage = "Stale branch duplicated locally. No hosted project was created."
            }
            return
        }
        await perform("Recovering the stale branch as a local duplicate…") {
            let result = try await live.service.recoverBranchAsDuplicate(conflict)
            await live.libraryController.refreshLibrary()
            self.surface = .awaitingUserEdit
            self.outcomeMessage = "Duplicated \(result.projectSummary.customName) locally. It remains offline until a separate migration is approved."
        }
    }

    func beginRawReview() async {
        guard let live, let projectID = selectedProjectID else {
            if live == nil { surface = .rawReview }
            return
        }
        await perform("Building the exact local raw disclosure ledger…") {
            let review = try await live.service.reviewRawArchive(
                localProjectID: projectID
            )
            self.retainedRawReview = review
            self.rawReviewFacts = Self.rawReviewFacts(review)
            self.surface = .rawReview
        }
    }

    func acceptAndUploadRawReview() async {
        guard let live, let review = retainedRawReview else {
            if live == nil {
                surface = .canonical
                outcomeMessage = "Reviewed raw archive attached without changing the hosted project head."
            }
            return
        }
        await perform("Revalidating and uploading the reviewed raw archive…") {
            let status = try await live.service.acceptAndUploadRawArchive(
                review,
                sessionUnlocked: live.isSessionUnlocked(),
                quotaPolicyVersion: live.actionContext.quotaPolicyVersion,
                hostedGlobalVersion: live.actionContext.hostedGlobalVersion,
                hostedWorkspaceVersion: live.actionContext.hostedWorkspaceVersion
            )
            guard status == .attached else {
                throw ProfessionalProjectSyncError.invalidResponse
            }
            self.retainedRawReview = nil
            self.surface = .canonical
            self.outcomeMessage = "Reviewed raw archive attached separately. The hosted working head did not change."
        }
    }

    func acquireLease() async {
        guard let live, let projectID = selectedProjectID else { return }
        await perform("Requesting a bounded advisory edit lease…") {
            let lease = try await live.service.acquireLeaseForLocalProject(
                localProjectID: projectID,
                deviceID: live.actionContext.deviceID,
                hostedGlobalVersion: live.actionContext.hostedGlobalVersion,
                hostedWorkspaceVersion: live.actionContext.hostedWorkspaceVersion
            )
            self.leaseExpiresAt = lease.expiresAt
            self.outcomeMessage = "Advisory edit lease acquired. Expected-head checks still protect every append."
        }
    }

    func renewLease() async {
        guard let live, let projectID = selectedProjectID else { return }
        await perform("Renewing the bounded advisory edit lease…") {
            let lease = try await live.service.renewLeaseForLocalProject(
                localProjectID: projectID,
                hostedGlobalVersion: live.actionContext.hostedGlobalVersion,
                hostedWorkspaceVersion: live.actionContext.hostedWorkspaceVersion
            )
            self.leaseExpiresAt = lease.expiresAt
        }
    }

    func releaseLease() async {
        guard let live, let projectID = selectedProjectID else { return }
        await perform("Releasing the advisory edit lease…") {
            try await live.service.releaseLeaseForLocalProject(
                localProjectID: projectID,
                hostedGlobalVersion: live.actionContext.hostedGlobalVersion,
                hostedWorkspaceVersion: live.actionContext.hostedWorkspaceVersion
            )
            self.leaseExpiresAt = nil
            self.outcomeMessage = "Advisory edit lease released."
        }
    }

    /// Publication is a separate, read-only review route from working-set
    /// sync. The model exposes no project, concept, membership, or feedback
    /// mutation capability through this entry point.
    func makePublicationReviewModel() async throws -> RoomPublicationReviewModel {
        guard let projectID = selectedProjectID else {
            throw RoomPublicationTransportError.unavailable
        }
        if let live {
            return try await live.makePublicationReviewModel(projectID)
        }
#if DEBUG
        return .fixture(arguments: ProcessInfo.processInfo.arguments)
#else
        throw RoomPublicationTransportError.unavailable
#endif
    }

    func resumeRecovery() async {
        guard let live, let projectID = selectedProjectID else { return }
        await perform("Resuming the durable package-first recovery…") {
            let result = try await live.service.resumeRecovery(
                localProjectID: projectID
            )
            await live.libraryController.refreshLibrary()
            self.outcomeMessage = "Recovered \(result.projectSummary.customName) through the validated package boundary."
            self.apply(try await live.service.refresh(projectID: projectID))
        }
    }

    func discardPreview() {
        guard let preview = retainedPreview else { return }
        try? live?.service.discardMigrationPreview(preview)
        retainedPreview = nil
        previewFacts = nil
    }

    private func uploadPreview(isRetry: Bool) async {
        guard let live, let preview = retainedPreview else {
            if live == nil {
                surface = .canonical
                outcomeMessage = "Hosted head acknowledged. The local project remains unchanged."
            }
            return
        }
        await perform(isRetry
            ? "Retrying the exact immutable upload…"
            : "Uploading, validating, and advancing the expected head…"
        ) {
            let state: ProfessionalProjectSyncPresentationState
            if isRetry {
                state = try await live.service.retryMigration(
                    preview,
                    sessionUnlocked: live.isSessionUnlocked(),
                    quotaPolicyVersion: live.actionContext.quotaPolicyVersion,
                    hostedGlobalVersion: live.actionContext.hostedGlobalVersion,
                    hostedWorkspaceVersion: live.actionContext.hostedWorkspaceVersion
                )
            } else {
                state = try await live.service.approveMigration(
                    preview,
                    sessionUnlocked: live.isSessionUnlocked(),
                    quotaPolicyVersion: live.actionContext.quotaPolicyVersion,
                    hostedGlobalVersion: live.actionContext.hostedGlobalVersion,
                    hostedWorkspaceVersion: live.actionContext.hostedWorkspaceVersion
                )
            }
            self.apply(state)
            switch state {
            case .canonical, .conflict, .rejected:
                self.retainedPreview = nil
            default:
                break
            }
            self.canRetryUpload = false
        } onFailure: {
            self.surface = .preview
            self.canRetryUpload = true
        }
    }

    private func apply(_ state: ProfessionalProjectSyncPresentationState) {
        switch state {
        case .idle: surface = .idle
        case .localDraft: surface = .localDraft
        case .previewReady: surface = .preview
        case .uploading, .awaitingValidation: break
        case .canonical:
            surface = .canonical
            outcomeMessage = "Hosted working head acknowledged. The local project was not removed."
        case let .conflict(conflict):
            retainedConflict = conflict
            conflictFacts = Self.conflictFacts(conflict)
            comparisonFacts = nil
            surface = .conflict
            outcomeMessage = "The expected hosted head changed. Both immutable branches are retained."
        case .awaitingUserEdit: surface = .awaitingUserEdit
        case .rejected: surface = .rejected
        case .recoveryReady: surface = .recoveryReady
        }
    }

    private func perform(
        _ message: String,
        operation: () async throws -> Void,
        onFailure: () -> Void = {}
    ) async {
        guard !isWorking else { return }
        isWorking = true
        progressMessage = message
        errorMessage = nil
        defer {
            isWorking = false
            progressMessage = nil
        }
        do {
            try await operation()
        } catch {
            onFailure()
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "The professional operation could not be completed. Local project data was not removed."
        }
    }

    private func resetTransientState() {
        surface = .idle
        previewFacts = nil
        conflictFacts = nil
        comparisonFacts = nil
        rawReviewFacts = nil
        retainedConflict = nil
        retainedRawReview = nil
        errorMessage = nil
        outcomeMessage = nil
        canRetryUpload = false
        leaseExpiresAt = nil
    }

    private static func previewFacts(
        _ preview: ProfessionalProjectSyncPreview
    ) -> PreviewFacts {
        PreviewFacts(
            roomName: preview.localRoomDisplayName,
            localHeadRevisionID: preview.localHeadRevisionID,
            archiveSHA256: preview.archiveSHA256,
            archiveByteCount: preview.archiveByteCount,
            categories: preview.workingCategories.map {
                PreviewFacts.Category(
                    id: $0.category.rawValue,
                    label: workingCategoryLabel($0.category),
                    itemCount: $0.itemCount,
                    byteCount: $0.byteCount
                )
            },
            excludedRawClasses: preview.rawExcludedClasses.map(rawClassLabel)
        )
    }

    private static func conflictFacts(
        _ conflict: ProfessionalProjectSyncConflict
    ) -> ConflictFacts {
        .init(
            hostedProjectID: conflict.hostedProjectID,
            canonicalRevisionID: conflict.canonicalRevisionID,
            staleRevisionID: conflict.staleRevisionID
        )
    }

    private static func comparisonFacts(
        _ comparison: ProfessionalProjectSyncComparison
    ) -> ComparisonFacts {
        .init(
            canonicalHeadRevisionID: comparison.canonicalHeadRevisionID,
            staleHeadRevisionID: comparison.staleHeadRevisionID,
            canonicalRevisionCount: comparison.canonicalRevisionCount,
            staleRevisionCount: comparison.staleRevisionCount,
            canonicalSemanticSHA256: comparison.canonicalSourceSemanticSHA256,
            staleSemanticSHA256: comparison.staleSourceSemanticSHA256,
            differs: comparison.differs
        )
    }

    private static func rawReviewFacts(
        _ review: ProfessionalProjectRawReview
    ) -> RawReviewFacts {
        let categories: [RawReviewFacts.Category] = RoomProfessionalRawAssetClass
            .allCases.compactMap { rawClass in
            let count = review.countByClass[rawClass, default: 0]
            guard count > 0 else { return nil }
            return RawReviewFacts.Category(
                id: rawClass.rawValue,
                label: rawClassLabel(rawClass),
                itemCount: count,
                byteCount: review.byteCountByClass[rawClass, default: 0]
            )
        }
        return .init(
            sourceRevisionID: review.sourceRevision.revisionID,
            totalByteCount: categories.reduce(0) { $0 + $1.byteCount },
            selectionSHA256: review.selectionSHA256,
            categories: categories
        )
    }

    private static func workingCategoryLabel(
        _ category: ProfessionalProjectWorkingCategory
    ) -> String {
        switch category {
        case .packageBackup: "Room package"
        case .redesignCompanion: "Redesign state"
        case .conceptSetManifest: "Concept Set manifests"
        case .conceptSetAttachment: "Concept Set attachments"
        case .conceptSourcePackageProvenance: "AI package provenance"
        }
    }

    private static func rawClassLabel(
        _ rawClass: RoomProfessionalRawAssetClass
    ) -> String {
        switch rawClass {
        case .rgb: "RGB"
        case .depth: "Depth"
        case .confidence: "Confidence"
        case .worldMap: "World map"
        case .diagnostics: "Diagnostics"
        }
    }
}

struct ProfessionalProjectSyncView: View {
    @StateObject private var model: ProfessionalProjectSyncViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var publicationModel: RoomPublicationReviewModel?
    @State private var showingPublicationReview = false
    @State private var publicationEntryMessage: String?

    init(model: @autoclosure @escaping () -> ProfessionalProjectSyncViewModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    masthead
                    projectPicker
                    storageTiers
                    notices
                    stateContent
                    publicationEntry
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("professional.sync.scroll")
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("Project recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("professional.sync.close")
                }
            }
        }
        .tint(AppPalette.blueprint)
        .task { await model.load() }
        .onDisappear { model.discardPreview() }
        .sheet(isPresented: $showingPublicationReview, onDismiss: {
            publicationModel = nil
        }) {
            if let publicationModel {
                RoomPublicationReviewView(model: publicationModel)
            }
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECOVERABLE / WORKING SET")
                .font(AppTypography.measurement)
                .tracking(2.2)
                .foregroundStyle(AppPalette.blueprint)
            Text("Professional project sync")
                .font(AppTypography.editorial)
                .foregroundStyle(AppPalette.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Append immutable revisions across devices while keeping every offline branch recoverable.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var projectPicker: some View {
        if model.projects.isEmpty {
            ruledSection("LOCAL PROJECT") {
                Text("No active local rooms are available. Guest capture and local saves remain offline and account-free.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppPalette.mutedInk)
            }
        } else {
            ruledSection("LOCAL PROJECT") {
                Picker("Project", selection: Binding(
                    get: { model.selectedProjectID ?? model.projects[0].id },
                    set: { selected in Task { await model.selectProject(selected) } }
                )) {
                    ForEach(model.projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("professional.sync.project")
                if let project = model.projects.first(where: {
                    $0.id == model.selectedProjectID
                }) {
                    StatusRail(items: [
                        StatusRailItem("LOCAL"),
                        StatusRailItem(project.headRevisionID, accent: true),
                    ])
                }
            }
        }
    }

    private var storageTiers: some View {
        ruledSection("WHAT LIVES WHERE") {
            storageTier(
                icon: "arrow.triangle.2.circlepath",
                title: "Professional working set",
                detail: "Room package, redesign state, Concept Sets, and provenance sync by default.",
                accent: AppPalette.blueprint
            )
            storageTier(
                icon: "internaldrive",
                title: "Full capture bundle",
                detail: "RGB, depth, confidence, and diagnostics stay local unless you separately review and enable a raw archive.",
                accent: AppPalette.amber
            )
            storageTier(
                icon: "icloud",
                title: "Private CloudKit backup",
                detail: "Personal private backup remains a separate system; it is not professional hosted synchronization.",
                accent: AppPalette.mutedInk
            )
        }
    }

    @ViewBuilder private var notices: some View {
        if model.isWorking, let message = model.progressMessage {
            HStack(spacing: 12) {
                ProgressView()
                Text(message)
                    .font(AppTypography.bodyEmphasized)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("professional.sync.progress")
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(AppTypography.bodyEmphasized)
                .foregroundStyle(AppPalette.amber)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("professional.sync.error")
        }
        if let outcome = model.outcomeMessage {
            Text(outcome)
                .font(AppTypography.calloutEmphasized)
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("professional.sync.outcome")
        }
    }

    @ViewBuilder private var stateContent: some View {
        switch model.surface {
        case .idle:
            startSection(
                title: "Create a hosted recovery copy",
                detail: "Preview the exact working set before any network allocation. The source room stays on this device."
            )
        case .localDraft:
            startSection(
                title: "Offline draft preserved",
                detail: "This local head differs from the acknowledged hosted head. Preview it to append with that exact expected head."
            )
        case .preview:
            previewSection
        case .canonical:
            canonicalSection
        case .conflict:
            conflictSection
        case .awaitingUserEdit:
            ruledSection("LOCAL COPY READY") {
                Text("The recovered copy has no hosted binding. Make and save an explicit child revision, then preview a separate migration or append.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppPalette.mutedInk)
                Button("Refresh local state") {
                    Task { await model.refreshSelectedProject() }
                }
                .buttonStyle(InstrumentButtonStyle(role: .secondary))
            }
        case .rejected:
            startSection(
                title: "Hosted validation rejected this archive",
                detail: "The local project and revision remain untouched. Build a new preview after reviewing the rejection."
            )
        case .recoveryReady:
            ruledSection("RECOVERY PAUSED SAFELY") {
                Text("A durable package-first recovery transaction is ready to resume. No live project is mutated from downloaded bytes directly.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Resume validated recovery") {
                    Task { await model.resumeRecovery() }
                }
                .buttonStyle(InstrumentButtonStyle(role: .primary))
                .disabled(model.isWorking)
                .accessibilityIdentifier("professional.sync.recovery.resume")
            }
        case .rawReview:
            rawReviewSection
        }
    }

    private var publicationEntry: some View {
        ruledSection("CLIENT PORTAL") {
            Text("Review a privacy-minimized immutable room or curated property snapshot. Publication never edits this project, the working head, or feedback records.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("Review client portal publication") {
                Task { await openPublicationReview() }
            }
            .buttonStyle(InstrumentButtonStyle(role: .secondary))
            .disabled(model.selectedProjectID == nil || model.isWorking)
            .accessibilityIdentifier("professional.publicationReview")
            .accessibilityHint("Opens a separate public-only review; publishing requires another sensitive action confirmation.")
            if let publicationEntryMessage {
                Label(publicationEntryMessage, systemImage: "exclamationmark.triangle")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("professional.publicationError")
            }
        }
    }

    private func openPublicationReview() async {
        do {
            publicationModel = try await model.makePublicationReviewModel()
            publicationEntryMessage = nil
            showingPublicationReview = true
        } catch {
            publicationModel = nil
            publicationEntryMessage = "Professional publication is unavailable until the configured workspace is signed in and unlocked."
        }
    }

    private func startSection(title: String, detail: String) -> some View {
        ruledSection("MIGRATION") {
            Text(title)
                .font(AppTypography.section)
                .foregroundStyle(AppPalette.ink)
            Text(detail)
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("Preview recoverable working set") {
                Task { await model.preparePreview() }
            }
            .buttonStyle(InstrumentButtonStyle(role: .primary))
            .disabled(model.isWorking || model.projects.isEmpty)
            .accessibilityIdentifier("professional.sync.preview")
        }
    }

    @ViewBuilder private var previewSection: some View {
        if let preview = model.previewFacts {
            ruledSection("REVIEW BEFORE UPLOAD") {
                Text(preview.roomName)
                    .font(AppTypography.section)
                    .foregroundStyle(AppPalette.ink)
                factRow("Local immutable head", preview.localHeadRevisionID)
                factRow("Working archive", Self.byteString(preview.archiveByteCount))
                digestRow("Archive SHA-256", preview.archiveSHA256)

                ForEach(preview.categories) { category in
                    HStack(alignment: .firstTextBaseline) {
                        Text(category.label)
                        Spacer(minLength: 12)
                        Text("\(category.itemCount) · \(Self.byteString(category.byteCount))")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.mutedInk)
                    }
                    .font(AppTypography.callout)
                }

                Text("Stays local by default: \(preview.excludedRawClasses.joined(separator: ", ")).")
                    .font(AppTypography.calloutEmphasized)
                    .foregroundStyle(AppPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Approval uploads a copy. It never deletes, archives, or edits the local project.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                adaptiveActions {
                    Button("Approve immutable upload") {
                        Task { await model.approvePreview() }
                    }
                    .buttonStyle(InstrumentButtonStyle(role: .primary))
                    .accessibilityIdentifier("professional.sync.approve")

                    Button("Retry exact upload") {
                        Task { await model.retryPreview() }
                    }
                    .buttonStyle(InstrumentButtonStyle(role: .secondary))
                    .disabled(!model.canRetryUpload)
                    .accessibilityIdentifier("professional.sync.retry")
                }
            }
        }
    }

    private var canonicalSection: some View {
        ruledSection("HOSTED HEAD ACKNOWLEDGED") {
            Label("Recoverable working set is canonical", systemImage: "checkmark.seal")
                .font(AppTypography.section)
                .foregroundStyle(AppPalette.blueprint)
            Text("Offline edits remain immutable local drafts until you explicitly preview another expected-head append.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            if let expiry = model.leaseExpiresAt {
                Text("Advisory edit lease expires \(expiry.formatted(date: .omitted, time: .shortened)).")
                    .font(AppTypography.measurement)
                adaptiveActions {
                    Button("Renew lease") { Task { await model.renewLease() } }
                        .buttonStyle(InstrumentButtonStyle(role: .secondary))
                    Button("Release lease") { Task { await model.releaseLease() } }
                        .buttonStyle(InstrumentButtonStyle(role: .quiet))
                }
            } else {
                Button("Request 15-minute edit lease") {
                    Task { await model.acquireLease() }
                }
                .buttonStyle(InstrumentButtonStyle(role: .secondary))
            }

            Button("Review local raw archive…") {
                Task { await model.beginRawReview() }
            }
            .buttonStyle(InstrumentButtonStyle(role: .secondary))
            .accessibilityIdentifier("professional.sync.rawReview")
        }
    }

    @ViewBuilder private var conflictSection: some View {
        if let conflict = model.conflictFacts {
            ProfessionalProjectConflictView(
                conflict: conflict,
                comparison: model.comparisonFacts,
                isWorking: model.isWorking,
                compare: { model.compareBranches() },
                rebase: { Task { await model.rebaseFromCanonical() } },
                duplicate: { Task { await model.duplicateStaleBranch() } }
            )
        }
    }

    @ViewBuilder private var rawReviewSection: some View {
        if let review = model.rawReviewFacts {
            ruledSection("RAW ARCHIVE — SEPARATE OPT-IN") {
                Label("Size and privacy review required", systemImage: "externaldrive.badge.exclamationmark")
                    .font(AppTypography.section)
                    .foregroundStyle(AppPalette.amber)
                factRow("Bound source revision", review.sourceRevisionID)
                factRow("Total selected bytes", Self.byteString(review.totalByteCount))
                digestRow("Selection SHA-256", review.selectionSHA256)
                ForEach(review.categories) { category in
                    HStack(alignment: .firstTextBaseline) {
                        Text(category.label)
                        Spacer(minLength: 12)
                        Text("\(category.itemCount) · \(Self.byteString(category.byteCount))")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.mutedInk)
                    }
                    .font(AppTypography.callout)
                }
                Text("Precise GPS is excluded. Approval attaches a separate raw object and never advances the hosted working head.")
                    .font(AppTypography.bodyEmphasized)
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Accept review and upload raw archive") {
                    Task { await model.acceptAndUploadRawReview() }
                }
                .buttonStyle(InstrumentButtonStyle(role: .primary))
                .accessibilityIdentifier("professional.sync.rawApprove")
            }
        }
    }

    private func storageTier(
        icon: String,
        title: String,
        detail: String,
        accent: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(AppTypography.symbol)
                .foregroundStyle(accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppTypography.bodyEmphasized)
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(AppPalette.mutedInk)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(AppTypography.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func digestRow(_ label: String, _ digest: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.mutedInk)
            Text(digest)
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ruledSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(AppPalette.paperShadow)
                .frame(height: 1)
                .accessibilityHidden(true)
            Text(title)
                .font(AppTypography.measurement)
                .tracking(1.4)
                .foregroundStyle(AppPalette.mutedInk)
            content()
        }
    }

    private func adaptiveActions<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content() }
            VStack(alignment: .leading, spacing: 10) { content() }
        }
    }

    private static func byteString(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

private struct ProfessionalProjectConflictView: View {
    let conflict: ProfessionalProjectSyncViewModel.ConflictFacts
    let comparison: ProfessionalProjectSyncViewModel.ComparisonFacts?
    let isWorking: Bool
    let compare: () -> Void
    let rebase: () -> Void
    let duplicate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle()
                .fill(AppPalette.amber)
                .frame(height: 3)
                .accessibilityHidden(true)
            Text("STALE EXPECTED HEAD")
                .font(AppTypography.measurement)
                .tracking(1.4)
                .foregroundStyle(AppPalette.amber)
            Text("Both branches are preserved")
                .font(AppTypography.section)
                .foregroundStyle(AppPalette.ink)
            Text("Geometry is never inferred or silently combined. Inspect the two validated packages, then choose an explicit recovery path.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            branch("Hosted canonical", conflict.canonicalRevisionID, accent: AppPalette.blueprint)
            branch("Preserved offline branch", conflict.staleRevisionID, accent: AppPalette.amber)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(alignment: .leading, spacing: 10) { actions }
            }

            if let comparison {
                VStack(alignment: .leading, spacing: 10) {
                    Text(comparison.differs ? "Validated packages differ" : "Validated packages match")
                        .font(AppTypography.bodyEmphasized)
                    comparisonRow(
                        label: "Canonical",
                        head: comparison.canonicalHeadRevisionID,
                        revisions: comparison.canonicalRevisionCount,
                        semantic: comparison.canonicalSemanticSHA256
                    )
                    comparisonRow(
                        label: "Offline",
                        head: comparison.staleHeadRevisionID,
                        revisions: comparison.staleRevisionCount,
                        semantic: comparison.staleSemanticSHA256
                    )
                }
                .padding(14)
                .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("professional.sync.conflict.comparison")
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Compare") { compare() }
            .buttonStyle(InstrumentButtonStyle(role: .secondary))
            .disabled(isWorking)
            .accessibilityIdentifier("professional.sync.conflict.compare")
        Button("Rebase as copy") { rebase() }
            .buttonStyle(InstrumentButtonStyle(role: .primary))
            .disabled(isWorking)
            .accessibilityIdentifier("professional.sync.conflict.rebase")
        Button("Duplicate offline") { duplicate() }
            .buttonStyle(InstrumentButtonStyle(role: .secondary))
            .disabled(isWorking)
            .accessibilityIdentifier("professional.sync.conflict.duplicate")
    }

    private func branch(_ label: String, _ revision: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(AppTypography.calloutEmphasized)
                .foregroundStyle(accent)
            Text(revision)
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.ink)
                .textSelection(.enabled)
        }
    }

    private func comparisonRow(
        label: String,
        head: String,
        revisions: Int,
        semantic: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(label) · \(revisions) revisions")
                .font(AppTypography.calloutEmphasized)
            Text(head)
                .font(AppTypography.measurement)
            Text("semantic \(semantic)")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

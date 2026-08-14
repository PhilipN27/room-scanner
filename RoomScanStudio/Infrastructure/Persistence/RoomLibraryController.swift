import Foundation
import Combine
import SwiftData
import RoomScanCore

@MainActor
final class RoomLibraryController: ObservableObject {
    @Published private(set) var summaries: [RoomProjectSummary] = []
    @Published private(set) var thumbnailDataByProjectID: [String: Data] = [:]
    @Published private(set) var listingIssues: [RoomProjectListingIssue] = []
    @Published private(set) var libraryErrorMessage: String?
    @Published private(set) var indexErrorMessage: String?

    private let store: LocalRoomProjectStore
    private let redesignStore: LocalRoomRedesignStore?
    private let propertyStore: LocalRoomPropertyStore?
    private let indexContext: ModelContext?

    init(
        store: LocalRoomProjectStore,
        modelContainer: ModelContainer?,
        redesignStore: LocalRoomRedesignStore? = nil,
        propertyStore: LocalRoomPropertyStore? = nil
    ) {
        self.store = store
        self.redesignStore = redesignStore
        self.propertyStore = propertyStore
        indexContext = modelContainer.map(ModelContext.init)
    }

    /// Known risk, accepted 2026-08-11: concurrent calls are not coordinated.
    /// Authoritative package data is safe (the store is an actor), but an
    /// older refresh finishing after a newer one can leave derived summaries,
    /// thumbnails, or the index temporarily stale until the next refresh.
    func refreshLibrary() async {
        do {
            let listing = try await store.listProjectListing(includeArchived: true)
            summaries = listing.summaries
            listingIssues = listing.issues
            libraryErrorMessage = nil
            let thumbnails = await loadThumbnails(for: listing.summaries)
            thumbnailDataByProjectID = thumbnails.dataByProjectID
            if thumbnails.hadFailure {
                libraryErrorMessage = "Room packages loaded, but one or more thumbnails could not be read."
            }

            if let indexContext {
                do {
                    try RoomProjectIndexRebuilder.rebuild(
                        listing: listing,
                        in: indexContext
                    )
                    indexErrorMessage = nil
                } catch {
                    indexErrorMessage = "Local search index could not refresh. Package data remains available."
                }
            }
        } catch {
            // Retain the prior visible package data rather than replacing it with
            // an empty library after a root-level enumeration failure.
            libraryErrorMessage = "Room packages could not be enumerated. Try again; existing package data has not been removed."
        }
    }

    func loadPackage(projectID: String) async throws -> RoomProjectPackage {
        try await store.load(projectID: projectID)
    }

    func redesignSourceBinding(
        projectID: String,
        revisionID: String
    ) async throws -> RoomRedesignSourceRevision {
        try await store.redesignSourceRevisionBinding(
            projectID: projectID,
            revisionID: revisionID
        )
    }

    func redesignState(
        sourceRevision: RoomRedesignSourceRevision
    ) async throws -> RoomLocalRedesignExtensionV2? {
        guard let redesignStore else { return nil }
        return try await redesignStore.load(sourceRevision: sourceRevision)
    }

    func saveRedesignState(
        _ document: RoomLocalRedesignExtensionV2,
        expectedSourceRevision: RoomRedesignSourceRevision
    ) async throws {
        guard let redesignStore else {
            throw RoomProjectStoreError.storageFailure("Local redesign companion storage is unavailable.")
        }
        try await redesignStore.save(document, expectedSourceRevision: expectedSourceRevision)
    }

    /// A capture suggestion is additive companion state. It is allowed to be
    /// saved before review, but the provider-neutral eligibility guard will
    /// reject it until the user explicitly confirms or replaces it.
    func saveOrientationSuggestion(
        _ suggestion: RoomOrientationSuggestion,
        projectID: String,
        revisionID: String,
        snapshot: RoomSemanticSnapshot
    ) async throws {
        guard let redesignStore else { return }
        let binding = try await redesignSourceBinding(projectID: projectID, revisionID: revisionID)
        guard suggestion.coordinateSpaceEpochID == binding.coordinateSpaceEpochID else {
            throw RoomProjectStoreError.invalidPackage("Capture orientation suggestion uses another coordinate-space epoch.")
        }
        let bounds = try RoomSpatialNormalization.bounds(of: snapshot)
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: binding,
            input: .init(
                source: .suggested,
                confidence: suggestion.confidence,
                entryPositionMeters: suggestion.entryPositionMeters,
                inwardDirection: suggestion.inwardDirection,
                roomBounds: bounds,
                entryFeatureID: suggestion.evidence.featureID,
                referenceWallFeatureID: nil,
                suggestionEvidence: suggestion.evidence
            )
        )
        let document = RoomLocalRedesignExtensionV2(
            sourceRevision: binding,
            orientation: orientation,
            redesignIntent: nil,
            propertyMembership: nil,
            conceptMetadata: []
        )
        try await redesignStore.save(document, expectedSourceRevision: binding)
    }

    func properties() async throws -> [RoomPropertyContainerV1] {
        guard let propertyStore else { return [] }
        return try await propertyStore.list()
    }

    func property(containing projectID: String) async throws -> RoomPropertyContainerV1? {
        guard let propertyStore else { return nil }
        return try await propertyStore.property(containing: projectID)
    }

    func saveProperty(_ property: RoomPropertyContainerV1) async throws {
        guard let propertyStore else {
            throw RoomProjectStoreError.storageFailure("Local property storage is unavailable.")
        }
        try await propertyStore.save(property)
    }

    func removeProperty(propertyID: String) async throws {
        guard let propertyStore else { return }
        try await propertyStore.remove(propertyID: propertyID)
    }

    func saveMockDraft(
        _ draft: RoomDraft,
        assets: [RoomAssetInput] = []
    ) async throws -> RoomProjectSummary? {
        let result = try await store.saveDraft(
            draft,
            decision: .save,
            assets: assets
        )
        await refreshLibrary()
        return result
    }

    /// The capture coordinator calls this only after the Core reducer accepts
    /// an explicit Save from review. A discard is delegated to the store's
    /// no-mutation decision path and never refreshes a fabricated profile.
    func commitInitialCapture(
        _ commit: RoomInitialCaptureCommit,
        decision: RoomDraftDecision
    ) async throws -> RoomProjectSummary? {
        let result = try await store.commitInitialCapture(
            commit,
            decision: decision
        )
        if result != nil {
            await refreshLibrary()
        }
        return result
    }

    func updateMetadata(
        projectID: String,
        metadata: RoomMetadata
    ) async throws -> RoomProjectSummary {
        let result = try await store.updateMetadata(projectID: projectID, metadata: metadata)
        await refreshLibrary()
        return result
    }

    func duplicate(projectID: String) async throws -> RoomProjectSummary {
        let result = try await store.duplicate(projectID: projectID)
        await refreshLibrary()
        return result
    }

    func archive(projectID: String) async throws {
        try await store.archive(projectID: projectID)
        await refreshLibrary()
    }

    func unarchive(projectID: String) async throws {
        try await store.unarchive(projectID: projectID)
        await refreshLibrary()
    }

    func delete(projectID: String) async throws {
        try await store.delete(projectID: projectID)
        await refreshLibrary()
    }

    func restore(
        projectID: String,
        sourceRevisionID: String
    ) async throws -> RoomRevisionManifest {
        let result = try await store.restoreAsNewRevision(
            projectID: projectID,
            sourceRevisionID: sourceRevisionID
        )
        await refreshLibrary()
        return result
    }

    /// The editor commits only through the store-owned optimistic transaction:
    /// a stale visible head cannot overwrite package truth, and parent assets
    /// plus evidence compatibility are carried internally by the store.
    func commitEditRevision(
        projectID: String,
        expectedHeadRevisionID: String,
        payload: RoomRevisionPayload,
        newRevisionID: String? = nil
    ) async throws -> RoomRevisionManifest {
        let result = try await store.commitEditRevision(
            projectID: projectID,
            expectedHeadRevisionID: expectedHeadRevisionID,
            payload: payload,
            newRevisionID: newRevisionID
        )
        await refreshLibrary()
        return result
    }

    /// Export receives only a frozen external head-revision workspace. The UI
    /// never observes authoritative package URLs or writes into a room package.
    func materializeHeadForExport(
        projectID: String,
        expectedHeadRevisionID: String,
        into workspaceURL: URL
    ) async throws -> RoomHeadExportMaterialization {
        try await store.materializeHeadForExport(
            projectID: projectID,
            expectedHeadRevisionID: expectedHeadRevisionID,
            into: workspaceURL
        )
    }

    /// A Phase-6 backup is intentionally separate from the head-only export:
    /// it materializes all immutable revisions into an external workspace and
    /// never exposes an authoritative package URL to the application layer.
    func materializeBackupSnapshot(
        projectID: String,
        expectedHeadRevisionID: String,
        into workspaceURL: URL
    ) async throws -> RoomBackupMaterialization {
        try await store.materializeBackupSnapshot(
            projectID: projectID,
            expectedHeadRevisionID: expectedHeadRevisionID,
            into: workspaceURL
        )
    }

    func prepareBackupRecovery(
        archiveURL: URL,
        expectedCloudDescriptor: RoomCloudBackupDescriptor,
        into workspaceURL: URL
    ) async throws -> RoomBackupRecoveryPreparation {
        try await store.prepareRecovery(
            archiveURL: archiveURL,
            expectedCloudDescriptor: expectedCloudDescriptor,
            into: workspaceURL
        )
    }

    func commitPreparedBackupRecovery(
        _ preparation: RoomBackupRecoveryPreparation,
        conflictPolicy: RoomBackupRecoveryConflictPolicy
    ) async throws -> RoomBackupRecoveryResult {
        let result = try await store.commitPreparedRecovery(
            preparation,
            conflictPolicy: conflictPolicy
        )
        // The index is derived local cache only. Rebuild it only after the
        // Core store has atomically promoted a successful recovery.
        switch result {
        case .restored, .recoveredCopy:
            await refreshLibrary()
        case .noOp:
            break
        }
        return result
    }

    func discardPreparedBackupRecovery(
        _ preparation: RoomBackupRecoveryPreparation
    ) async throws {
        try await store.discardPreparedRecovery(preparation)
    }

    /// Rescan acceptance is deliberately store-owned: the Core store reloads
    /// and recomputes the transient fixture proposal while holding its root
    /// lock before appending an immutable `.rescan` child.
    func acceptFixtureRescan(
        projectID: String,
        expectedHeadRevisionID: String,
        proposal: RoomFixtureRescanProposal
    ) async throws -> RoomRevisionManifest {
        let result = try await store.acceptFixtureRescan(
            projectID: projectID,
            expectedHeadRevisionID: expectedHeadRevisionID,
            proposal: proposal
        )
        await refreshLibrary()
        return result
    }

    func thumbnailData(for projectID: String) -> Data? {
        thumbnailDataByProjectID[projectID]
    }

    // Store-owned derived hero cache passthroughs: the UI receives bytes,
    // never package URLs.
    func heroCache(projectID: String) async throws -> RoomMeshHeroCachePayload? {
        try await store.heroCache(projectID: projectID)
    }

    func publishHeroCache(
        projectID: String,
        manifest: RoomMeshHeroCacheManifest,
        imageData: Data
    ) async throws {
        try await store.publishHeroCache(
            projectID: projectID, manifest: manifest, imageData: imageData
        )
    }

    func invalidateHeroCache(projectID: String) async throws {
        try await store.invalidateHeroCache(projectID: projectID)
    }

    private func loadThumbnails(
        for summaries: [RoomProjectSummary]
    ) async -> (dataByProjectID: [String: Data], hadFailure: Bool) {
        var dataByProjectID: [String: Data] = [:]
        var hadFailure = false
        for summary in summaries where summary.thumbnailRelativePath != nil {
            do {
                let data = try await store.thumbnailData(projectID: summary.projectID)
                dataByProjectID[summary.projectID] = data
            } catch {
                hadFailure = true
            }
        }
        return (dataByProjectID, hadFailure)
    }
}

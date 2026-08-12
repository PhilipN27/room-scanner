import Foundation
import SwiftUI
import UIKit
import RoomScanCore

/// The renderers a room profile can open, in the priority order used to pick
/// the default "Open room" action: photoreal splat beats colored mesh beats
/// the always-available semantic boxes.
enum RoomOpenTarget: Equatable, Hashable {
    case splat
    case coloredMesh
    case semantic
}

/// Pure choice of the best available renderer for the primary "Open room"
/// action. Kept free of view state so it is independently reasoned about
/// (and unit-testable if a dedicated RoomDetailView test file is added).
func preferredRoomOpenTarget(hasSplat: Bool, hasMesh: Bool) -> RoomOpenTarget {
    if hasSplat { return .splat }
    if hasMesh { return .coloredMesh }
    return .semantic
}

struct RoomDetailView: View {
    let projectID: String
    @ObservedObject var controller: RoomLibraryController
    let rescanProvider: any RoomRescanProviding
    @ObservedObject var exportCoordinator: RoomExportCoordinator
    @ObservedObject var cloudBackupCoordinator: RoomCloudBackupCoordinator
    @ObservedObject var meshColoringCoordinator: RoomMeshColoringJobCoordinator
    let privacyPolicyURL: URL?
    var openColoredMeshOnAppear = false

    @State private var package: RoomProjectPackage?
    @State private var errorMessage: String?
    @State private var showingMetadataEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var showingRescan = false
    @State private var showingViewer = false
    @State private var showingRoomEditor = false
    @State private var showingExport = false
    @State private var showingCloudBackup = false
    @State private var showingSplatViewer = false
    @State private var showingSplatImporter = false
    @State private var splatURL: URL?
    @State private var splatImportErrorMessage: String?
    @State private var showingMeshViewer = false
    @State private var hasBundleMesh = false
    @State private var hasCaptureBundle = false
    @State private var buildingBundleExport = false
    @State private var bundleExportURL: URL?
    @State private var bundleExportErrorMessage: String?
    @State private var didAutoOpenColoredMesh = false
    @State private var heroMedia: RoomHeroMediaState = .loading
    @State private var heroLoadTask: Task<Void, Never>?
    @State private var heroLoadGeneration = 0
    @State private var showingInfoPanel = false
    @State private var pendingInfoAction: RoomInfoPanelAction?
    @State private var showingOpenRoomChoices = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let package {
                    detailContent(package)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.amber)
                        .accessibilityIdentifier("detail.error")
                } else {
                    ProgressView("Loading local room package...")
                        .tint(AppPalette.blueprint)
                }
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("detail.scroll")
        .onDisappear {
            heroLoadTask?.cancel()
        }
        .background(AppPalette.paper.ignoresSafeArea())
        .navigationTitle("Room profile")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: projectID) {
            splatURL = RoomSplatLibrary.splatURL(forProject: projectID)
            hasBundleMesh = RoomMeshBundleLoader.hasRenderableMesh(forProject: projectID)
            hasCaptureBundle = RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID) != nil
            await reload()
            if openColoredMeshOnAppear, hasBundleMesh, package != nil, !didAutoOpenColoredMesh {
                didAutoOpenColoredMesh = true
                showingMeshViewer = true
            }
        }
        .onChange(of: controller.summaries) {
            Task { await reload() }
        }
        .sheet(isPresented: $showingInfoPanel, onDismiss: {
            runPendingInfoAction()
        }) {
            if let package {
                RoomInfoPanel(
                    metadata: package.metadata,
                    effectiveLastRevisedDate: package.effectiveLastRevisedDate,
                    hasCaptureBundle: hasCaptureBundle,
                    hasSplat: splatURL != nil,
                    onAction: { action in
                        pendingInfoAction = action
                        showingInfoPanel = false
                    }
                )
            }
        }
        .sheet(isPresented: $showingMetadataEditor, onDismiss: {
            Task { await reload() }
        }) {
            if let package {
                RoomMetadataEditorView(
                    projectID: projectID,
                    metadata: package.metadata,
                    controller: controller
                )
            }
        }
        .sheet(isPresented: $showingRescan, onDismiss: {
            Task { await reload() }
        }) {
            RoomRescanFlowView(
                projectID: projectID,
                controller: controller,
                provider: rescanProvider,
                onAccepted: {
                    Task { await reload() }
                }
            )
        }
        .fullScreenCover(isPresented: $showingViewer) {
            if let head = package?.revisions.last {
                RoomViewerView(
                    roomName: package?.metadata.customName ?? "Saved room",
                    payload: head.payload
                )
            }
        }
        .sheet(isPresented: $showingSplatViewer) {
            if let splatURL {
                NavigationStack {
                    RoomSplatViewerScreen(projectID: projectID, splatURL: splatURL)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Close") {
                                    showingSplatViewer = false
                                }
                            }
                        }
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { bundleExportURL != nil },
                set: { isPresented in
                    if !isPresented {
                        cleanUpBundleExport()
                    }
                }
            )
        ) {
            if let bundleExportURL {
                RoomExportShareSheet(archiveURL: bundleExportURL) { _ in
                    cleanUpBundleExport()
                }
            }
        }
        .sheet(isPresented: $showingMeshViewer) {
            NavigationStack {
                RoomMeshViewerScreen(
                    projectID: projectID,
                    roomName: package?.metadata.customName ?? "Room",
                    coordinator: meshColoringCoordinator
                )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Close") {
                                showingMeshViewer = false
                            }
                        }
                    }
            }
        }
        .fileImporter(
            isPresented: $showingSplatImporter,
            allowedContentTypes: RoomSplatLibrary.importContentTypes
        ) { result in
            switch result {
            case let .success(url):
                do {
                    splatURL = try RoomSplatLibrary.importSplat(from: url, forProject: projectID)
                    splatImportErrorMessage = nil
                    showingSplatViewer = true
                } catch {
                    splatImportErrorMessage = "The splat file could not be imported: \(error.localizedDescription)"
                }
            case let .failure(error):
                splatImportErrorMessage = "The splat file could not be imported: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showingRoomEditor, onDismiss: {
            Task { await reload() }
        }) {
            if let package, let head = package.revisions.last {
                RoomEditorView(
                    projectID: projectID,
                    expectedHeadRevisionID: package.manifest.headRevisionID,
                    payload: head.payload,
                    captureEvidence: head.manifest.captureEvidence,
                    controller: controller,
                    onSaved: {
                        Task { await reload() }
                    }
                )
            }
        }
        .sheet(isPresented: $showingExport) {
            if let package {
                RoomExportView(
                    projectID: projectID,
                    expectedHeadRevisionID: package.manifest.headRevisionID,
                    coordinator: exportCoordinator
                )
            }
        }
        .sheet(isPresented: $showingCloudBackup) {
            if let package {
                RoomCloudBackupSettingsView(
                    coordinator: cloudBackupCoordinator,
                    projectID: projectID,
                    expectedHeadRevisionID: package.manifest.headRevisionID,
                    privacyPolicyURL: privacyPolicyURL
                )
            }
        }
        .confirmationDialog(
            "Permanently delete this room package?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                Task { await deletePackage() }
            }
            .accessibilityIdentifier("delete.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local package and its immutable revision history from this device.")
        }
    }

    @ViewBuilder
    private func detailContent(_ package: RoomProjectPackage) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            RoomHeroMedia(
                state: heroState,
                accessibilityDescription: "\(package.metadata.customName) preview"
            )

            StatusRail(items: statusRailItems(package))

            nameSection(package)

            openRoomSection(package)

            if let activeProjectID = meshColoringCoordinator.conflictProjectID {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Another room is already coloring. Open its status from the library or cancel it before starting this room.",
                        systemImage: "hourglass"
                    )
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amber)
                    Button("Cancel active coloring", role: .destructive) {
                        meshColoringCoordinator.cancel()
                    }
                    .buttonStyle(InstrumentButtonStyle(role: .secondary))
                    .accessibilityHint("Cancels coloring for project \(activeProjectID).")
                }
                .accessibilityIdentifier("detail.meshColoringConflict")
            }

            if meshColoringCoordinator.projectID == projectID,
               let state = meshColoringCoordinator.state {
                meshColoringStatus(state)
            }

            revisionTimelineSection(package)

            Label(
                package.revisions.last?.payload.semanticSnapshot.accuracyDisclaimer
                    ?? "Measurements are estimates, not survey-grade evidence.",
                systemImage: "ruler"
            )
            .font(AppTypography.measurement)
            .foregroundStyle(AppPalette.mutedInk)

            technicalDetails(package)

            if buildingBundleExport {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing capture bundle...")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedInk)
                }
                .accessibilityIdentifier("detail.exportBundleProgress")
            }

            if let bundleExportErrorMessage {
                Label(bundleExportErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("detail.exportBundleError")
            }

            Rectangle()
                .fill(AppPalette.paperShadow)
                .frame(height: 1)
                .accessibilityHidden(true)

            Button("Delete permanently", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .buttonStyle(InstrumentButtonStyle(role: .destructive))
            .accessibilityIdentifier("detail.delete")
        }
    }

    // MARK: - Hero

    private var heroState: RoomHeroMediaState {
        heroMedia
    }

    // MARK: - Status rail

    private func statusRailItems(_ package: RoomProjectPackage) -> [StatusRailItem] {
        let target = preferredRoomOpenTarget(hasSplat: splatURL != nil, hasMesh: hasBundleMesh)
        let revisionCount = package.revisions.count
        return [
            StatusRailItem(rendererLabel(for: target), accent: true),
            StatusRailItem("\(revisionCount) revision\(revisionCount == 1 ? "" : "s")"),
            StatusRailItem(package.metadata.captureDate.formatted(date: .abbreviated, time: .omitted))
        ]
    }

    private func rendererLabel(for target: RoomOpenTarget) -> String {
        switch target {
        case .splat: return "Photoreal"
        case .coloredMesh: return "Colored mesh"
        case .semantic: return "Semantic"
        }
    }

    // MARK: - Name + info

    @ViewBuilder
    private func nameSection(_ package: RoomProjectPackage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(package.metadata.customName)
                    .font(AppTypography.editorial)
                    .foregroundStyle(AppPalette.ink)
                    .accessibilityIdentifier("detail.roomName")
                if !package.metadata.manualLocation.isEmpty {
                    Text(package.metadata.manualLocation)
                        .font(AppTypography.callout)
                        .foregroundStyle(AppPalette.mutedInk)
                }
            }
            Spacer(minLength: 0)
            Button {
                showingInfoPanel = true
            } label: {
                Image(systemName: "info.circle")
                    .font(AppTypography.symbol)
                    .foregroundStyle(AppPalette.blueprint)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Room details")
            .accessibilityHint("Shows room metadata and management actions.")
            .accessibilityIdentifier("detail.infoToggle")
        }
    }

    /// Routes the info panel's chosen action after its sheet has fully
    /// dismissed — presenting the follow-up sheet (metadata editor, export,
    /// backup, file importer) while the panel is still up would fail.
    private func runPendingInfoAction() {
        guard let action = pendingInfoAction else { return }
        pendingInfoAction = nil
        switch action {
        case .editMetadata:
            showingMetadataEditor = true
        case .archive:
            Task { await changeArchiveState(archived: true) }
        case .unarchive:
            Task { await changeArchiveState(archived: false) }
        case .exportHeadRevision:
            showingExport = true
        case .backUpProject:
            showingCloudBackup = true
        case .importSplat:
            showingSplatImporter = true
        case .exportCaptureBundle:
            Task { await buildBundleExport() }
        }
    }

    // MARK: - Open room

    @ViewBuilder
    private func openRoomSection(_ package: RoomProjectPackage) -> some View {
        let hasSplat = splatURL != nil
        let target = preferredRoomOpenTarget(hasSplat: hasSplat, hasMesh: hasBundleMesh)
        let targets = availableTargets(package, hasSplat: hasSplat)

        VStack(alignment: .leading, spacing: 10) {
            // Open room leads; Edit room, Rescan, and Duplicate sit to its
            // right, wrapping to a second line only when width demands it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    openRoomButton(target: target, targets: targets, package: package)
                    editRoomButton
                    rescanButton
                    duplicateButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    openRoomButton(target: target, targets: targets, package: package)
                        .frame(maxWidth: .infinity)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            editRoomButton
                            rescanButton
                            duplicateButton
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            editRoomButton.frame(maxWidth: .infinity, alignment: .leading)
                            rescanButton.frame(maxWidth: .infinity, alignment: .leading)
                            duplicateButton.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .confirmationDialog(
                "How do you want to view this room?",
                isPresented: $showingOpenRoomChoices,
                titleVisibility: .visible
            ) {
                ForEach(targets, id: \.self) { choice in
                    Button(rendererLabel(for: choice)) {
                        openRenderer(choice, package: package)
                    }
                    .accessibilityIdentifier(accessibilityIdentifier(for: choice))
                }
                Button("Cancel", role: .cancel) {}
            }

            if let splatImportErrorMessage {
                Label(splatImportErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("detail.splatImportError")
            }
        }
    }

    /// When more than one renderer exists, Open room asks which to use; with
    /// a single renderer it opens directly and keeps that renderer's
    /// accessibility identifier so existing automation still finds it.
    private func openRoomButton(
        target: RoomOpenTarget,
        targets: [RoomOpenTarget],
        package: RoomProjectPackage
    ) -> some View {
        Button("Open room") {
            if targets.count > 1 {
                showingOpenRoomChoices = true
            } else {
                openRenderer(target, package: package)
            }
        }
        .buttonStyle(InstrumentButtonStyle(role: .primary))
        .accessibilityIdentifier(
            targets.count > 1 ? "detail.openRoom" : accessibilityIdentifier(for: target)
        )
    }

    private var editRoomButton: some View {
        Button("Edit room") {
            showingRoomEditor = true
        }
        .buttonStyle(InstrumentButtonStyle(role: .secondary))
        .accessibilityIdentifier("detail.editRoom")
    }

    private var rescanButton: some View {
        Button("Rescan") {
            showingRescan = true
        }
        .buttonStyle(InstrumentButtonStyle(role: .secondary))
        .accessibilityIdentifier("detail.rescan")
    }

    private var duplicateButton: some View {
        Button("Duplicate") {
            Task { await duplicatePackage() }
        }
        .buttonStyle(InstrumentButtonStyle(role: .secondary))
        .accessibilityIdentifier("detail.duplicate")
    }

    private func availableTargets(_ package: RoomProjectPackage, hasSplat: Bool) -> [RoomOpenTarget] {
        var targets: [RoomOpenTarget] = []
        if hasSplat { targets.append(.splat) }
        if hasBundleMesh { targets.append(.coloredMesh) }
        if package.revisions.last != nil { targets.append(.semantic) }
        return targets
    }

    private func accessibilityIdentifier(for target: RoomOpenTarget) -> String {
        switch target {
        case .splat: return "detail.photoreal"
        case .coloredMesh: return "detail.coloredMesh"
        case .semantic: return "detail.view"
        }
    }

    private func openRenderer(_ target: RoomOpenTarget, package: RoomProjectPackage) {
        switch target {
        case .splat:
            showingSplatViewer = true
        case .coloredMesh:
            openColoredMesh(package)
        case .semantic:
            guard package.revisions.last != nil else { return }
            showingViewer = true
        }
    }

    private func openColoredMesh(_ package: RoomProjectPackage) {
        let outcome = meshColoringCoordinator.start(
            projectID: projectID,
            roomName: package.metadata.customName
        )
        if case .conflict = outcome { return }
        showingMeshViewer = true
    }

    // MARK: - Revision timeline

    private func revisionTimelineSection(_ package: RoomProjectPackage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(AppPalette.paperShadow)
                .frame(height: 1)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text("IMMUTABLE REVISION HISTORY")
                    .font(AppTypography.section)
                    .foregroundStyle(AppPalette.ink)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("HEAD")
                        .font(AppTypography.measurement)
                        .textCase(.uppercase)
                        .kerning(1.2)
                        .foregroundStyle(AppPalette.mutedInk)
                    Text(package.manifest.headRevisionID)
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.blueprint)
                        .accessibilityIdentifier("detail.headRevision")
                }
            }
            RevisionHistoryView(
                projectID: projectID,
                revisions: package.revisions,
                headRevisionID: package.manifest.headRevisionID,
                controller: controller
            )
        }
    }

    // MARK: - Technical details

    @ViewBuilder
    private func technicalDetails(_ package: RoomProjectPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TECHNICAL DETAILS")
                .font(AppTypography.measurement)
                .textCase(.uppercase)
                .kerning(1.2)
                .foregroundStyle(AppPalette.mutedInk)

            let thumbnailPath = package.metadata.thumbnailRelativePath?.value ?? "No thumbnail asset"
            HStack(alignment: .top, spacing: 8) {
                DetailPair("Thumbnail path", value: thumbnailPath)
                Spacer(minLength: 0)
                if package.metadata.thumbnailRelativePath != nil {
                    Button {
                        UIPasteboard.general.string = thumbnailPath
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Copy thumbnail path")
                }
            }

            HStack(alignment: .top, spacing: 8) {
                DetailPair(
                    "Head revision",
                    value: package.manifest.headRevisionID,
                    accessibilityIdentifier: "detail.technicalDetails.headRevision"
                )
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = package.manifest.headRevisionID
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Copy head revision id")
            }

            RoomThumbnailView(
                data: controller.thumbnailData(for: projectID),
                fallbackSymbol: "photo",
                accessibilityIdentifier: "detail.thumbnail",
                sideLength: 120
            )
        }
        .padding(14)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Mesh coloring status

    @ViewBuilder
    private func meshColoringStatus(_ state: RoomMeshColoringJobState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state == .cacheReady ? "Colored mesh is ready" : "Coloring this room")
                    .font(AppTypography.bodyEmphasized)
                Spacer()
                Text("\(state == .cacheReady ? 100 : meshColoringCoordinator.progress.percent)%")
                    .font(AppTypography.measurement.monospacedDigit())
            }
            ProgressView(value: state == .cacheReady ? 1 : meshColoringCoordinator.progress.fraction)
                .tint(AppPalette.blueprint)
            Text(meshColoringCoordinator.executionMessage)
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
            if state == .interrupted || state == .failed {
                Button("Retry coloring") {
                    meshColoringCoordinator.retry()
                }
                .buttonStyle(InstrumentButtonStyle(role: .primary))
            } else if meshColoringCoordinator.isActiveJob {
                Button("Cancel coloring", role: .destructive) {
                    meshColoringCoordinator.cancel()
                }
                .buttonStyle(InstrumentButtonStyle(role: .secondary))
            }
        }
        .padding(14)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("detail.meshColoringStatus")
    }

    // MARK: - Actions

    private func buildBundleExport() async {
        guard !buildingBundleExport else { return }
        buildingBundleExport = true
        bundleExportErrorMessage = nil
        let projectID = projectID
        do {
            let built = try await Task.detached(priority: .userInitiated) {
                try await RoomCaptureBundleTrainingExport.buildExportZip(forProject: projectID)
            }.value
            bundleExportURL = built.url
        } catch {
            bundleExportErrorMessage = "The capture bundle could not be exported: \(error.localizedDescription)"
        }
        buildingBundleExport = false
    }

    private func cleanUpBundleExport() {
        if let bundleExportURL {
            try? FileManager.default.removeItem(at: bundleExportURL)
        }
        bundleExportURL = nil
    }

    private func reload() async {
        do {
            package = try await controller.loadPackage(projectID: projectID)
            errorMessage = nil
            // Load the hero snapshot outside reload(): it must return as soon
            // as `package` is set so SwiftUI paints the profile content
            // before any hero-cache IO happens. Each reload supersedes prior
            // hero work: the generation guard stops a slow older load from
            // overwriting a newer hero, and cancellation stops work whose
            // view is gone.
            if let package {
                heroLoadGeneration &+= 1
                let generation = heroLoadGeneration
                let projectID = projectID
                heroLoadTask?.cancel()
                heroLoadTask = Task { [controller] in
                    let hero = await RoomMeshHeroPipeline.fastHeroState(
                        projectID: projectID, package: package, controller: controller
                    )
                    guard !Task.isCancelled, generation == heroLoadGeneration else { return }
                    heroMedia = hero
                }
            }
        } catch {
            // The old package must not keep rendering as if current — a
            // deleted or unreadable package shows the error, not stale state.
            package = nil
            heroLoadTask?.cancel()
            errorMessage = "This local room package could not be opened."
        }
    }

    private func duplicatePackage() async {
        do {
            _ = try await controller.duplicate(projectID: projectID)
            await reload()
        } catch {
            errorMessage = "The room package could not be duplicated."
        }
    }

    private func changeArchiveState(archived: Bool) async {
        do {
            if archived {
                try await controller.archive(projectID: projectID)
            } else {
                try await controller.unarchive(projectID: projectID)
            }
            await reload()
        } catch {
            errorMessage = "The archive state could not be updated."
        }
    }

    private func deletePackage() async {
        do {
            try await controller.delete(projectID: projectID)
            dismiss()
        } catch {
            errorMessage = "The room package could not be deleted."
        }
    }
}

/// Actions the info panel can request. The panel only reports the choice;
/// `RoomDetailView` performs it after the panel sheet dismisses.
enum RoomInfoPanelAction {
    case editMetadata
    case archive
    case unarchive
    case exportHeadRevision
    case backUpProject
    case importSplat
    case exportCaptureBundle
}

/// The "i" panel: room metadata plus the management actions that used to
/// occupy their own full-width sections on the profile page.
private struct RoomInfoPanel: View {
    let metadata: RoomMetadata
    let effectiveLastRevisedDate: Date
    let hasCaptureBundle: Bool
    let hasSplat: Bool
    let onAction: (RoomInfoPanelAction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    metadataSection
                    Rectangle()
                        .fill(AppPalette.paperShadow)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                    manageSection
                }
                .padding(24)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .accessibilityIdentifier("detail.infoPanel.scroll")
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("Room details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("detail.infoPanel.close")
                }
            }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("METADATA")
                    .font(AppTypography.measurement)
                    .textCase(.uppercase)
                    .kerning(1.2)
                    .foregroundStyle(AppPalette.mutedInk)
                Spacer(minLength: 0)
                Button("Edit metadata") {
                    onAction(.editMetadata)
                }
                .buttonStyle(InstrumentButtonStyle(role: .quiet))
                .accessibilityIdentifier("detail.editMetadata")
            }

            DetailPair("Captured", value: metadata.captureDate.formatted(date: .abbreviated, time: .shortened))
            DetailPair("Last revised", value: effectiveLastRevisedDate.formatted(date: .abbreviated, time: .shortened))
            DetailPair("Manual location", value: metadata.manualLocation.isEmpty ? "Not recorded" : metadata.manualLocation)
            DetailPair(
                "GPS",
                value: metadata.optionalGPS.map {
                    "\($0.latitude), \($0.longitude) +/- \($0.horizontalAccuracyMeters)m"
                } ?? "Not recorded"
            )
            DetailPair("Notes", value: metadata.notes.isEmpty ? "No notes" : metadata.notes)
            DetailPair("Tags", value: metadata.tags.isEmpty ? "No tags" : metadata.tags.joined(separator: ", "))
        }
    }

    private var manageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MANAGE")
                .font(AppTypography.measurement)
                .textCase(.uppercase)
                .kerning(1.2)
                .foregroundStyle(AppPalette.mutedInk)

            VStack(alignment: .leading, spacing: 10) {
                if metadata.archived {
                    manageButton("Unarchive", action: .unarchive, identifier: "detail.unarchive")
                } else {
                    manageButton("Archive", action: .archive, identifier: "detail.archive")
                }
                manageButton("Export head revision", action: .exportHeadRevision, identifier: "detail.export")
                manageButton("Back up full project", action: .backUpProject, identifier: "detail.backup")
                manageButton(
                    hasSplat ? "Replace photoreal splat" : "Import photoreal splat",
                    action: .importSplat,
                    identifier: "detail.importSplat"
                )
                if hasCaptureBundle {
                    manageButton("Export capture bundle", action: .exportCaptureBundle, identifier: "detail.exportBundle")
                }
            }
        }
    }

    private func manageButton(
        _ title: String,
        action: RoomInfoPanelAction,
        identifier: String
    ) -> some View {
        Button(title) {
            onAction(action)
        }
        .buttonStyle(InstrumentButtonStyle(role: .secondary))
        .accessibilityIdentifier(identifier)
    }
}

private struct DetailPair: View {
    let label: String
    let value: String
    let accessibilityIdentifier: String?

    init(
        _ label: String,
        value: String,
        accessibilityIdentifier: String? = nil
    ) {
        self.label = label
        self.value = value
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.blueprint)
            Text(value)
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(accessibilityIdentifier ?? "")
        }
    }
}

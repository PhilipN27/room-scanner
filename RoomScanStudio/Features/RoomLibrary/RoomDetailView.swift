import Foundation
import SwiftUI
import RoomScanCore

struct RoomDetailView: View {
    let projectID: String
    @ObservedObject var controller: RoomLibraryController
    let rescanProvider: any RoomRescanProviding
    @ObservedObject var exportCoordinator: RoomExportCoordinator
    @ObservedObject var cloudBackupCoordinator: RoomCloudBackupCoordinator
    let privacyPolicyURL: URL?

    @State private var package: RoomProjectPackage?
    @State private var errorMessage: String?
    @State private var showingMetadataEditor = false
    @State private var showingDeleteConfirmation = false
    @State private var showingRescan = false
    @State private var showingViewer = false
    @State private var showingRoomEditor = false
    @State private var showingExport = false
    @State private var showingCloudBackup = false
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
        .background(AppPalette.paper.ignoresSafeArea())
        .navigationTitle("Room profile")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: projectID) {
            await reload()
        }
        .onChange(of: controller.summaries) { _ in
            Task { await reload() }
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
        .sheet(isPresented: $showingViewer) {
            if let head = package?.revisions.last {
                RoomViewerView(
                    roomName: package?.metadata.customName ?? "Saved room",
                    payload: head.payload
                )
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
            Text("ROOM PROFILE")
                .font(AppTypography.measurement)
                .tracking(1.8)
                .foregroundStyle(AppPalette.blueprint)

            Text(package.metadata.customName)
                .font(AppTypography.editorial)
                .foregroundStyle(AppPalette.ink)
                .accessibilityIdentifier("detail.roomName")

            metadataReadout(
                package.metadata,
                manifest: package.manifest,
                effectiveLastRevisedDate: package.effectiveLastRevisedDate,
                thumbnailData: controller.thumbnailData(for: projectID)
            )
            actionBar(package)

            Text("IMMUTABLE REVISION HISTORY")
                .font(AppTypography.section)
                .foregroundStyle(AppPalette.ink)

            RevisionHistoryView(
                projectID: projectID,
                revisions: package.revisions,
                headRevisionID: package.manifest.headRevisionID,
                controller: controller
            )

            Label(
                package.revisions.last?.payload.semanticSnapshot.accuracyDisclaimer
                    ?? "Measurements are estimates, not survey-grade evidence.",
                systemImage: "ruler"
            )
            .font(AppTypography.measurement)
            .foregroundStyle(AppPalette.mutedInk)
        }
    }

    private func metadataReadout(
        _ metadata: RoomMetadata,
        manifest: RoomProjectManifest,
        effectiveLastRevisedDate: Date,
        thumbnailData: Data?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
            DetailPair(
                "Thumbnail",
                value: metadata.thumbnailRelativePath?.value ?? "No thumbnail asset"
            )
            RoomThumbnailView(
                data: thumbnailData,
                fallbackSymbol: "photo",
                accessibilityIdentifier: "detail.thumbnail",
                sideLength: 160
            )
            DetailPair(
                "Head",
                value: manifest.headRevisionID,
                accessibilityIdentifier: "detail.headRevision"
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func actionBar(_ package: RoomProjectPackage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                Button("View saved room") {
                    showingViewer = true
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.primaryAction)
                .accessibilityIdentifier("detail.view")

                Button("Edit room") {
                    showingRoomEditor = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("detail.editRoom")
            }

            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                Button("Edit metadata") {
                    showingMetadataEditor = true
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.primaryAction)
                .accessibilityIdentifier("detail.editMetadata")

                Button("Duplicate") {
                    Task { await duplicatePackage() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("detail.duplicate")

                Button("Rescan") {
                    showingRescan = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("detail.rescan")
            }

            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                if package.metadata.archived {
                    Button("Unarchive") {
                        Task { await changeArchiveState(archived: false) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("detail.unarchive")
                } else {
                    Button("Archive") {
                        Task { await changeArchiveState(archived: true) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("detail.archive")
                }

                Button("Delete permanently", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("detail.delete")
            }

            Button("Export head revision") {
                showingExport = true
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("detail.export")

            Button("Back up full project") {
                showingCloudBackup = true
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("detail.backup")
        }
    }

    private func reload() async {
        do {
            package = try await controller.loadPackage(projectID: projectID)
            errorMessage = nil
        } catch {
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

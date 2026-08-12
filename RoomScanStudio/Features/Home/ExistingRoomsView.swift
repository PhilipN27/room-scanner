import Foundation
import SwiftUI
import UIKit
import RoomScanCore

struct ExistingRoomsView: View {
    private enum LibraryFilter: String, CaseIterable, Identifiable {
        case active = "Active"
        case archived = "Archived"

        var id: String { rawValue }
    }

    @ObservedObject var controller: RoomLibraryController
    let rescanProvider: any RoomRescanProviding
    @ObservedObject var exportCoordinator: RoomExportCoordinator
    @ObservedObject var cloudBackupCoordinator: RoomCloudBackupCoordinator
    @ObservedObject var meshColoringCoordinator: RoomMeshColoringJobCoordinator
    let privacyPolicyURL: URL?
    @State private var filter: LibraryFilter = .active

    private var filteredSummaries: [RoomProjectSummary] {
        controller.summaries.filter { summary in
            switch filter {
            case .active:
                return !summary.archived
            case .archived:
                return summary.archived
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("EXISTING ROOMS")
                    .font(AppTypography.measurement)
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.blueprint)

                Text("Existing room package library")
                    .font(AppTypography.editorial)
                    .foregroundStyle(AppPalette.ink)
                    .accessibilityIdentifier("existingRooms.title")

                filterControl
                issueMessages
                libraryContent
            }
            .padding(24)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppPalette.paper.ignoresSafeArea())
        .navigationTitle("Existing Rooms")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await controller.refreshLibrary()
        }
    }

    private var filterControl: some View {
        AdaptiveActionRow(alignment: .leading, spacing: 10) {
            ForEach(LibraryFilter.allCases) { option in
                Button(option.rawValue) {
                    filter = option
                }
                .buttonStyle(.borderedProminent)
                .tint(option == filter ? AppPalette.primaryAction : AppPalette.paperShadow)
                .accessibilityIdentifier(
                    option == .active ? "library.showActive" : "library.showArchived"
                )
            }
            Spacer()
            Button {
                Task { await controller.refreshLibrary() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh library")
            .accessibilityIdentifier("library.refresh")
        }
    }

    @ViewBuilder
    private var issueMessages: some View {
        if !controller.listingIssues.isEmpty {
            Label(
                "\(controller.listingIssues.count) package issue\(controller.listingIssues.count == 1 ? "" : "s") isolated. Valid room packages remain available.",
                systemImage: "exclamationmark.triangle"
            )
            .font(AppTypography.measurement)
            .foregroundStyle(AppPalette.amber)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.captureBlack, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("library.issues")
        }

        if let error = controller.libraryErrorMessage {
            Label(error, systemImage: "arrow.clockwise.circle")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.amber)
                .accessibilityIdentifier("library.error")
        }

        if let error = controller.indexErrorMessage {
            Label(error, systemImage: "magnifyingglass")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
                .accessibilityIdentifier("library.indexIssue")
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if filteredSummaries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "archivebox")
                    .font(AppTypography.symbol)
                    .foregroundStyle(AppPalette.blueprint)
                Text(filter == .active ? "No active room profiles yet." : "No archived room profiles.")
                    .font(AppTypography.section)
                    .foregroundStyle(AppPalette.ink)
                    .accessibilityIdentifier("library.empty")
                Text("A mock fixture becomes a profile only after its review explicitly saves it.")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.paperShadow.opacity(0.38), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            LazyVStack(spacing: 12) {
                ForEach(filteredSummaries) { summary in
                    NavigationLink {
                        RoomDetailView(
                            projectID: summary.projectID,
                            controller: controller,
                            rescanProvider: rescanProvider,
                            exportCoordinator: exportCoordinator,
                            cloudBackupCoordinator: cloudBackupCoordinator,
                            meshColoringCoordinator: meshColoringCoordinator,
                            privacyPolicyURL: privacyPolicyURL
                        )
                    } label: {
                        RoomLibraryRow(
                            summary: summary,
                            thumbnailData: controller.thumbnailData(for: summary.projectID)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.project.\(summary.projectID)")
                }
            }
        }
    }
}

private struct RoomLibraryRow: View {
    let summary: RoomProjectSummary
    let thumbnailData: Data?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoomThumbnailView(
                data: thumbnailData,
                fallbackSymbol: summary.archived ? "archivebox.fill" : "square.stack.3d.up.fill",
                accessibilityIdentifier: "library.thumbnail.\(summary.projectID)",
                sideLength: 56
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(summary.customName)
                    .font(AppTypography.section)
                    .foregroundStyle(AppPalette.ink)
                Text(summary.manualLocation.isEmpty ? "No manual location" : summary.manualLocation)
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
                Text("HEAD / \(summary.headRevisionID)")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.blueprint)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text(summary.lastRevisedDate, format: .dateTime.year().month().day())
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
                if summary.archived {
                    Text("ARCHIVED")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.amber)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct RoomThumbnailView: View {
    let data: Data?
    let fallbackSymbol: String
    let accessibilityIdentifier: String
    let sideLength: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSymbol)
                    .font(AppTypography.symbol)
                    .foregroundStyle(AppPalette.blueprint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppPalette.paperShadow.opacity(0.42))
            }
        }
        .frame(width: sideLength, height: sideLength)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel(data == nil ? "No room thumbnail" : "Room thumbnail")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

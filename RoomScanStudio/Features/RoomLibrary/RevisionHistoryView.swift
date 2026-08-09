import SwiftUI
import RoomScanCore

struct RevisionHistoryView: View {
    let projectID: String
    let revisions: [RoomRevisionPackage]
    let headRevisionID: String
    @ObservedObject var controller: RoomLibraryController

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(revisions.reversed(), id: \.manifest.revisionID) { revision in
                NavigationLink {
                    RevisionInspectView(
                        projectID: projectID,
                        revision: revision,
                        controller: controller
                    )
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: revision.manifest.revisionID == headRevisionID ? "point.3.connected.trianglepath.dotted" : "clock.arrow.circlepath")
                            .foregroundStyle(
                                revision.manifest.revisionID == headRevisionID
                                    ? AppPalette.blueprint
                                    : AppPalette.mutedInk
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(revision.manifest.revisionID)
                                .font(AppTypography.section)
                                .foregroundStyle(AppPalette.ink)
                            Text("\(revision.manifest.reason.rawValue.uppercased()) / immutable")
                                .font(AppTypography.measurement)
                                .foregroundStyle(AppPalette.mutedInk)
                            Text(revision.manifest.createdAt, format: .dateTime.year().month().day().hour().minute())
                                .font(AppTypography.measurement)
                                .foregroundStyle(AppPalette.mutedInk)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(AppPalette.mutedInk)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("revision.\(revision.manifest.revisionID)")
            }
        }
    }
}

struct RevisionInspectView: View {
    let projectID: String
    let revision: RoomRevisionPackage
    @ObservedObject var controller: RoomLibraryController

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("REVISION INSPECTION")
                    .font(AppTypography.measurement)
                    .tracking(1.6)
                    .foregroundStyle(AppPalette.blueprint)
                Text(revision.manifest.revisionID)
                    .font(AppTypography.editorial)
                    .foregroundStyle(AppPalette.ink)
                    .accessibilityIdentifier("revision.inspect.\(revision.manifest.revisionID)")
                DetailRow(label: "Reason", value: revision.manifest.reason.rawValue)
                DetailRow(label: "Parent", value: revision.manifest.parentRevisionID ?? "None")
                DetailRow(label: "Restored from", value: revision.manifest.restoredFromRevisionID ?? "Not a revert")
                DetailRow(label: "Elements", value: "\(revision.payload.semanticSnapshot.structuralElements.count) structural / \(revision.payload.semanticSnapshot.objectElements.count) objects")
                DetailRow(label: "Annotations", value: "\(revision.payload.annotations.count)")
                DetailRow(label: "Measurements", value: "\(revision.payload.measurements.count)")
                DetailRow(label: "Photos", value: "\(revision.payload.photos.count)")

                Text(revision.payload.semanticSnapshot.accuracyDisclaimer)
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)

                if let errorMessage {
                    Text(errorMessage)
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.amber)
                }

                Button("Restore as new revision") {
                    Task { await restore() }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.primaryAction)
                .accessibilityIdentifier("revision.restore.\(revision.manifest.revisionID)")
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppPalette.paper.ignoresSafeArea())
        .navigationTitle("Revision")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func restore() async {
        do {
            _ = try await controller.restore(
                projectID: projectID,
                sourceRevisionID: revision.manifest.revisionID
            )
            dismiss()
        } catch {
            errorMessage = "A new revert revision could not be created."
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.blueprint)
            Text(value)
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.ink)
        }
    }
}

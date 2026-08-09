import SwiftUI
import RoomScanCore

struct MockRoomReviewView: View {
    @ObservedObject var controller: RoomLibraryController
    let onDiscard: () -> Void
    let onOpenLibrary: () -> Void

    @State private var fixture: MockRoomFixture?
    @State private var roomName = ""
    @State private var manualLocation = ""
    @State private var savedSummary: RoomProjectSummary?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("MOCK ROOM REVIEW")
                    .font(AppTypography.measurement)
                    .tracking(1.8)
                    .foregroundStyle(AppPalette.blueprint)

                Text(savedSummary == nil ? "Review before saving" : "Mock profile saved")
                    .font(AppTypography.editorial)
                    .foregroundStyle(AppPalette.ink)
                    .accessibilityIdentifier("mockReview.title")

                if let fixture {
                    reviewFields(fixture)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.amber)
                } else {
                    ProgressView("Loading MockRoom-v1...")
                        .tint(AppPalette.blueprint)
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(AppPalette.paper.ignoresSafeArea())
        .navigationTitle("Mock review")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadFixtureIfNeeded()
        }
    }

    @ViewBuilder
    private func reviewFields(_ fixture: MockRoomFixture) -> some View {
        if savedSummary == nil {
            Text("This deterministic fixture has no camera, AR session, or capture claim. Nothing is written until Save is chosen.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedInk)

            TextField("Room name", text: $roomName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mockReview.roomName")
            TextField("Manual location", text: $manualLocation)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mockReview.manualLocation")

            Label(
                fixture.draft.revision.semanticSnapshot.accuracyDisclaimer,
                systemImage: "ruler"
            )
            .font(AppTypography.measurement)
            .foregroundStyle(AppPalette.mutedInk)

            if let errorMessage {
                Text(errorMessage)
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("mockReview.error")
            }

            AdaptiveActionRow(alignment: .leading, spacing: 12) {
                Button("Discard", role: .cancel, action: onDiscard)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("mockReview.discard")
                Button("Save") {
                    Task { await save(fixture) }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.primaryAction)
                .accessibilityIdentifier("mockReview.save")
            }
        } else {
            Text("One local room profile was created from the reviewed fixture. Its package remains the source of truth.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedInk)
            Button("Open library", action: onOpenLibrary)
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.blueprint)
                .accessibilityIdentifier("mockReview.openLibrary")
        }
    }

    private func loadFixtureIfNeeded() {
        guard fixture == nil else {
            return
        }
        do {
            let loaded = try MockRoomFixtureLoader.load()
            fixture = loaded
            roomName = loaded.draft.metadata.customName
            manualLocation = loaded.draft.metadata.manualLocation
            errorMessage = nil
        } catch {
            errorMessage = "MockRoom-v1 could not be loaded from bundled resources."
        }
    }

    private func save(_ fixture: MockRoomFixture) async {
        let trimmedName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Room name is required before saving."
            return
        }
        var draft = fixture.draft
        draft.metadata.customName = trimmedName
        draft.metadata.manualLocation = manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            savedSummary = try await controller.saveMockDraft(
                draft,
                assets: fixture.assets
            )
            errorMessage = nil
        } catch {
            errorMessage = "The mock profile could not be saved locally."
        }
    }
}

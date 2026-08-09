import SwiftUI
import RoomScanCore

struct RoomMetadataEditorView: View {
    let projectID: String
    let originalMetadata: RoomMetadata
    @ObservedObject var controller: RoomLibraryController

    @Environment(\.dismiss) private var dismiss
    @State private var customName: String
    @State private var manualLocation: String
    @State private var notes: String
    @State private var tagsText: String
    @State private var errorMessage: String?

    init(
        projectID: String,
        metadata: RoomMetadata,
        controller: RoomLibraryController
    ) {
        self.projectID = projectID
        originalMetadata = metadata
        self.controller = controller
        _customName = State(initialValue: metadata.customName)
        _manualLocation = State(initialValue: metadata.manualLocation)
        _notes = State(initialValue: metadata.notes)
        _tagsText = State(initialValue: metadata.tags.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("EDIT METADATA")
                        .font(AppTypography.measurement)
                        .tracking(1.6)
                        .foregroundStyle(AppPalette.blueprint)

                    TextField("Room name", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("metadata.roomName")
                    TextField("Manual location", text: $manualLocation)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("metadata.manualLocation")
                    TextField("Tags, comma separated", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("metadata.tags")
                    TextEditor(text: $notes)
                        .frame(minHeight: 130)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppPalette.paperShadow.opacity(0.7))
                        )
                        .accessibilityIdentifier("metadata.notes")

                    if let errorMessage {
                        Text(errorMessage)
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.amber)
                            .accessibilityIdentifier("metadata.error")
                    }

                    Button("Save metadata") {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.primaryAction)
                    .accessibilityIdentifier("metadata.save")
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("Metadata")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() async {
        let trimmedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Room name is required."
            return
        }

        var metadata = originalMetadata
        metadata.customName = trimmedName
        metadata.manualLocation = manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            _ = try await controller.updateMetadata(
                projectID: projectID,
                metadata: metadata
            )
            dismiss()
        } catch {
            errorMessage = "Metadata could not be saved locally."
        }
    }
}

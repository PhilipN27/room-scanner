import Foundation
import SwiftUI
import RoomScanCore

/// An in-memory semantic draft. Save delegates to the store-owned optimistic
/// edit transaction; Cancel simply dismisses and cannot mutate a package.
@MainActor
struct RoomEditorView: View {
    let projectID: String
    let expectedHeadRevisionID: String
    let captureEvidence: RoomRevisionEvidencePlan?
    @ObservedObject var controller: RoomLibraryController
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editor: RoomRevisionEditor?
    @State private var selectedElementID = ""
    @State private var label = ""
    @State private var category = ""
    @State private var width = ""
    @State private var height = ""
    @State private var depth = ""
    @State private var translationX = "0"
    @State private var translationY = "0"
    @State private var translationZ = "0"
    @State private var yawRadians = "0"
    @State private var noteText = ""
    @State private var measurementLabel = "Reference span"
    @State private var measurementStart = "0, 0, 0"
    @State private var measurementEnd = "1, 0, 0"
    @State private var photoCaption = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(
        projectID: String,
        expectedHeadRevisionID: String,
        payload: RoomRevisionPayload,
        captureEvidence: RoomRevisionEvidencePlan?,
        controller: RoomLibraryController,
        onSaved: @escaping () -> Void
    ) {
        self.projectID = projectID
        self.expectedHeadRevisionID = expectedHeadRevisionID
        self.captureEvidence = captureEvidence
        self.controller = controller
        self.onSaved = onSaved
        _editor = State(initialValue: try? RoomRevisionEditor(
            payload: payload,
            captureEvidence: captureEvidence
        ))
    }

    private var elements: [RoomSemanticElement] {
        guard let editor else { return [] }
        return editor.payload.semanticSnapshot.structuralElements
            + editor.payload.semanticSnapshot.objectElements
    }

    private var selectedElement: RoomSemanticElement? {
        elements.first(where: { $0.id == selectedElementID })
    }

    private var selectedPhoto: RoomPhoto? {
        editor?.payload.photos.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("SEMANTIC EDITOR / DRAFT")
                        .font(AppTypography.measurement)
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.blueprint)
                    Text("Edit is copy-on-write. Save advances the project head to a new immutable edit; it never mutates the prior revision.")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("editor.title")

                    if editor != nil {
                        elementEditor
                        additionsEditor
                        photoEditor
                        actionBar
                    } else {
                        Label(
                            "The room revision could not be prepared for editing.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.amber)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("editor.error")
                    }
                }
                .padding(24)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("Edit room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("editor.cancel")
                }
            }
            .onAppear(perform: selectInitialElement)
            .onChange(of: selectedElementID) { _ in populateFields() }
        }
    }

    private var elementEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SEMANTIC ELEMENT")
                .font(AppTypography.section)
                .foregroundStyle(AppPalette.ink)
            Picker("Element", selection: $selectedElementID) {
                ForEach(elements) { element in
                    Text("\(element.label) / \(element.id)").tag(element.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("editor.element")

            TextField("Label", text: $label)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("editor.label")
            TextField("Category", text: $category)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("editor.category")

            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                numericField("Width", text: $width, identifier: "editor.width")
                numericField("Height", text: $height, identifier: "editor.height")
                numericField("Depth", text: $depth, identifier: "editor.depth")
            }
            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                numericField("X", text: $translationX, identifier: "editor.translationX")
                numericField("Y", text: $translationY, identifier: "editor.translationY")
                numericField("Z", text: $translationZ, identifier: "editor.translationZ")
                numericField("Yaw", text: $yawRadians, identifier: "editor.yaw")
            }
            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                Button("Apply element") { applyElementChanges() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.primaryAction)
                    .accessibilityIdentifier("editor.applyElement")
                Button("Delete element", role: .destructive) { deleteSelectedElement() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("editor.delete")
            }
        }
        .padding(16)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var additionsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ADD SPATIAL SEMANTICS")
                .font(AppTypography.section)
                .foregroundStyle(AppPalette.ink)
            Text("Manual objects are explicitly manual provenance. Notes and measurements are positioned only in this draft until Save.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            Button("Add manual object") { addManualObject() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("editor.addObject")

            TextField("Positioned note", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("editor.note")
            Button("Add positioned note") { addNote() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("editor.addNote")

            TextField("Measurement label", text: $measurementLabel)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("editor.measurementLabel")
            TextField("Start x, y, z", text: $measurementStart)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("editor.measurementStart")
            TextField("End x, y, z", text: $measurementEnd)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("editor.measurementEnd")
            Button("Add point-to-point measurement") { addMeasurement() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("editor.addMeasurement")
        }
        .padding(16)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var photoEditor: some View {
        if let selectedPhoto {
            VStack(alignment: .leading, spacing: 10) {
                Text("PHOTO CAPTION")
                    .font(AppTypography.section)
                    .foregroundStyle(AppPalette.ink)
                TextField("Caption", text: $photoCaption)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("editor.photoCaption")
                Button("Apply caption") { updatePhotoCaption(selectedPhoto) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("editor.applyPhotoCaption")
            }
            .padding(16)
            .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var actionBar: some View {
        AdaptiveActionRow(alignment: .leading, spacing: 12) {
            Button(isSaving ? "Saving..." : "Save immutable edit") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.primaryAction)
            .disabled(isSaving)
            .accessibilityIdentifier("editor.save")

            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .disabled(isSaving)
                .accessibilityIdentifier("editor.cancel.inline")
        }
    }

    private func numericField(
        _ title: String,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        TextField(title, text: text)
            .keyboardType(.numbersAndPunctuation)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier(identifier)
    }

    private func selectInitialElement() {
        guard selectedElementID.isEmpty, let first = elements.first else { return }
        selectedElementID = first.id
        populateFields()
        photoCaption = selectedPhoto?.caption ?? ""
    }

    private func populateFields() {
        guard let element = selectedElement else { return }
        label = element.label
        category = element.kind
        width = string(element.dimensionsMeters.width)
        height = string(element.dimensionsMeters.height)
        depth = string(element.dimensionsMeters.depth)
        let values = element.transform?.columnMajorValues
        translationX = string(values?[12] ?? 0)
        translationY = string(values?[13] ?? 0)
        translationZ = string(values?[14] ?? 0)
        yawRadians = "0"
    }

    private enum ElementFormApplication: Equatable {
        case applied
        case unchanged
        case invalid
    }

    /// Applies the current form before an explicit Save. This makes it
    /// impossible for Save to silently omit a typed label/category/dimension
    /// or pose change. Pose is deliberately untouched for non-pose edits so
    /// captured pitch/roll/scale data survives an ordinary rename.
    @discardableResult
    private func applyElementChanges() -> ElementFormApplication {
        guard var workingEditor = editor else { return .invalid }
        guard let current = selectedElement else { return .unchanged }

        let labelChanged = label != current.label
        let categoryChanged = category != current.kind
        let dimensionsChanged = width != string(current.dimensionsMeters.width)
            || height != string(current.dimensionsMeters.height)
            || depth != string(current.dimensionsMeters.depth)
        let values = current.transform?.columnMajorValues
        let poseChanged = translationX != string(values?[12] ?? 0)
            || translationY != string(values?[13] ?? 0)
            || translationZ != string(values?[14] ?? 0)
            || yawRadians != "0"
        guard labelChanged || categoryChanged || dimensionsChanged || poseChanged else {
            return .unchanged
        }

        do {
            if labelChanged {
                try workingEditor.renameElement(id: selectedElementID, label: label)
            }
            if categoryChanged {
                try workingEditor.updateCategory(id: selectedElementID, kind: category)
            }
            if dimensionsChanged {
                guard
                    let parsedWidth = Double(width),
                    let parsedHeight = Double(height),
                    let parsedDepth = Double(depth)
                else {
                    errorMessage = "Enter finite numeric dimensions before saving the draft."
                    return .invalid
                }
                try workingEditor.updateDimensions(
                    id: selectedElementID,
                    dimensions: RoomDimensions(
                        width: parsedWidth,
                        height: parsedHeight,
                        depth: parsedDepth
                    )
                )
            }
            if poseChanged {
                guard
                    let parsedX = Double(translationX),
                    let parsedY = Double(translationY),
                    let parsedZ = Double(translationZ),
                    let parsedYaw = Double(yawRadians)
                else {
                    errorMessage = "Enter finite translation and yaw adjustment values before saving the draft."
                    return .invalid
                }
                try workingEditor.adjustPose(
                    id: selectedElementID,
                    translation: RoomPoint3D(x: parsedX, y: parsedY, z: parsedZ),
                    yawDeltaRadians: parsedYaw
                )
            }
            editor = workingEditor
            populateFields()
            errorMessage = nil
            return .applied
        } catch {
            errorMessage = "This edit would violate semantic layer, spatial, or provenance rules."
            return .invalid
        }
    }

    private func deleteSelectedElement() {
        guard var workingEditor = editor else { return }
        do {
            try workingEditor.deleteElement(id: selectedElementID)
            editor = workingEditor
            selectedElementID = elements.first?.id ?? ""
            populateFields()
            errorMessage = nil
        } catch {
            errorMessage = "The selected semantic element could not be deleted."
        }
    }

    private func addManualObject() {
        guard var workingEditor = editor else { return }
        do {
            let identifier = "manual-object-\(UUID().uuidString.lowercased())"
            try workingEditor.addManualObject(
                id: identifier,
                kind: "cabinet",
                label: "Manual cabinet",
                dimensions: RoomDimensions(width: 0.8, height: 1.0, depth: 0.45),
                transform: poseTransform(
                    translation: RoomPoint3D(x: 0, y: 0.5, z: 0),
                    yaw: 0
                )
            )
            editor = workingEditor
            selectedElementID = identifier
            populateFields()
            errorMessage = nil
        } catch {
            errorMessage = "The manual object could not be added to this semantic draft."
        }
    }

    private func addNote() {
        guard var workingEditor = editor else { return }
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter note text before adding a positioned note."
            return
        }
        let point = selectedElement.flatMap { element -> RoomPoint3D? in
            guard let values = element.transform?.columnMajorValues, values.count == 16 else { return nil }
            return RoomPoint3D(x: values[12], y: values[13], z: values[14])
        } ?? RoomPoint3D(x: 0, y: 0.1, z: 0)
        do {
            try workingEditor.addSpatialAnnotation(
                id: "annotation-\(UUID().uuidString.lowercased())",
                text: trimmed,
                createdAt: Date(),
                point: point,
                attachedElementID: selectedElementID.isEmpty ? nil : selectedElementID
            )
            editor = workingEditor
            noteText = ""
            errorMessage = nil
        } catch {
            errorMessage = "The positioned note could not be added."
        }
    }

    private func addMeasurement() {
        guard var workingEditor = editor,
              let start = point(from: measurementStart),
              let end = point(from: measurementEnd) else {
            errorMessage = "Enter start and end points as finite x, y, z values."
            return
        }
        do {
            try workingEditor.addPointToPointMeasurement(
                id: "measurement-\(UUID().uuidString.lowercased())",
                label: measurementLabel,
                startPoint: start,
                endPoint: end
            )
            editor = workingEditor
            errorMessage = nil
        } catch {
            errorMessage = "The point-to-point measurement could not be added."
        }
    }

    private func updatePhotoCaption(_ photo: RoomPhoto) {
        guard var workingEditor = editor else { return }
        do {
            try workingEditor.updatePhotoCaption(id: photo.id, caption: photoCaption)
            editor = workingEditor
            errorMessage = nil
        } catch {
            errorMessage = "The photo caption could not be updated."
        }
    }

    private func save() async {
        guard applyElementChanges() != .invalid, let currentEditor = editor else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await controller.commitEditRevision(
                projectID: projectID,
                expectedHeadRevisionID: expectedHeadRevisionID,
                payload: currentEditor.payload
            )
            onSaved()
            dismiss()
        } catch {
            // The current draft remains available. In particular a stale head
            // never overwrites package truth or silently discards local edits.
            errorMessage = "Save conflict or package error. The immutable head was not overwritten; review or cancel this draft."
        }
    }

    private func poseTransform(
        translation: RoomPoint3D,
        yaw: Double
    ) -> RoomTransform4x4 {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        return RoomTransform4x4(columnMajorValues: [
            cosine, 0, -sine, 0,
            0, 1, 0, 0,
            sine, 0, cosine, 0,
            translation.x, translation.y, translation.z, 1,
        ])
    }

    private func point(from text: String) -> RoomPoint3D? {
        let values = text
            .split(separator: ",")
            .map { Double(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == 3, let x = values[0], let y = values[1], let z = values[2] else {
            return nil
        }
        let point = RoomPoint3D(x: x, y: y, z: z)
        return point.isFinite ? point : nil
    }

    private func string(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

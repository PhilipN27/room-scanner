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

// MARK: - Slice 1 additive spatial review

struct RoomOrientationReviewFeatureOption: Identifiable, Equatable {
    let featureID: String
    let title: String
    let role: RoomSemanticRole
    let positionMeters: RoomRedesignVector3

    var id: String { featureID }
}

struct RoomOrientationEntryReference: Equatable {
    let positionMeters: RoomRedesignVector3
    let inwardDirection: RoomRedesignVector3
}

enum RoomOrientationReviewPresentationError: Error, Equatable {
    case entryFeatureNotFound(String)
    case degenerateEntryDirection(String)
}

/// A deterministic, coordinate-local presentation model. Numbered labels and
/// the top-down projection let a person distinguish adjacent RoomPlan doors
/// without exposing opaque SDK identifiers or claiming cross-room alignment.
struct RoomOrientationReviewPresentation: Equatable {
    let projection: RoomFloorPlanProjection
    let roomBounds: RoomNormalizedBounds
    let entryOptions: [RoomOrientationReviewFeatureOption]
    let wallOptions: [RoomOrientationReviewFeatureOption]

    init(snapshot: RoomSemanticSnapshot) throws {
        projection = try RoomFloorPlanProjection.make(from: snapshot)
        roomBounds = try RoomSpatialNormalization.bounds(of: snapshot)

        let positioned = try snapshot.structuralElements.map { element in
            (element, try RoomSpatialNormalization.position(of: element))
        }
        let orderedEntries = positioned
            .filter {
                let role = RoomSemanticPresentation.role(for: $0.0)
                return role == .door || role == .opening
            }
            .sorted(by: Self.spatialOrder)
        entryOptions = orderedEntries.enumerated().map { index, value in
            let role = RoomSemanticPresentation.role(for: value.0)
            return RoomOrientationReviewFeatureOption(
                featureID: value.0.id,
                title: "\(RoomSemanticPresentation.token(for: role).displayName) \(index + 1) of \(orderedEntries.count)",
                role: role,
                positionMeters: value.1
            )
        }

        let orderedWalls = positioned
            .filter { RoomSemanticPresentation.role(for: $0.0) == .wall }
            .sorted(by: Self.spatialOrder)
        wallOptions = orderedWalls.enumerated().map { index, value in
            RoomOrientationReviewFeatureOption(
                featureID: value.0.id,
                title: "Wall \(index + 1) of \(orderedWalls.count)",
                role: .wall,
                positionMeters: value.1
            )
        }
    }

    func title(forEntryFeatureID featureID: String) -> String {
        entryOptions.first(where: { $0.featureID == featureID })?.title ?? "Detected entrance"
    }

    func title(forWallFeatureID featureID: String) -> String {
        wallOptions.first(where: { $0.featureID == featureID })?.title ?? "Reference wall"
    }

    func entryReference(featureID: String) throws -> RoomOrientationEntryReference {
        guard let option = entryOptions.first(where: { $0.featureID == featureID }) else {
            throw RoomOrientationReviewPresentationError.entryFeatureNotFound(featureID)
        }
        let floorPosition = RoomRedesignVector3(
            x: option.positionMeters.x,
            y: roomBounds.minimum.y,
            z: option.positionMeters.z
        )
        let towardCenter = RoomRedesignVector3(
            x: roomBounds.center.x - floorPosition.x,
            y: 0,
            z: roomBounds.center.z - floorPosition.z
        )
        let length = hypot(towardCenter.x, towardCenter.z)
        guard length.isFinite, length > 0.001 else {
            throw RoomOrientationReviewPresentationError.degenerateEntryDirection(featureID)
        }
        return RoomOrientationEntryReference(
            positionMeters: floorPosition,
            inwardDirection: .init(
                x: towardCenter.x / length,
                y: 0,
                z: towardCenter.z / length
            )
        )
    }

    private static func spatialOrder(
        _ lhs: (RoomSemanticElement, RoomRedesignVector3),
        _ rhs: (RoomSemanticElement, RoomRedesignVector3)
    ) -> Bool {
        if abs(lhs.1.x - rhs.1.x) > 0.000_001 { return lhs.1.x < rhs.1.x }
        if abs(lhs.1.z - rhs.1.z) > 0.000_001 { return lhs.1.z > rhs.1.z }
        return lhs.0.id < rhs.0.id
    }
}

/// Pure, display-only transform shared by the plan renderer and its tests.
/// Base coordinates intentionally use +X right and +Z down, matching the
/// semantic viewer's top camera. Captured RoomPlan coordinates are never
/// modified; rotation and mirroring exist only in this derived presentation.
struct RoomOrientationPlanDisplayTransform: Equatable {
    let presentation: RoomTopDownPresentationTransform
    let center: RoomFloorPlanPoint
    let bounds: RoomFloorPlanBounds

    init(
        projection: RoomFloorPlanProjection,
        presentation: RoomTopDownPresentationTransform
    ) {
        self.presentation = presentation
        let computedCenter = RoomFloorPlanPoint(
            x: (projection.bounds.minimum.x + projection.bounds.maximum.x) / 2,
            y: (projection.bounds.minimum.y + projection.bounds.maximum.y) / 2
        )
        center = computedCenter
        let sourceCorners = [
            projection.bounds.minimum,
            .init(x: projection.bounds.maximum.x, y: projection.bounds.minimum.y),
            projection.bounds.maximum,
            .init(x: projection.bounds.minimum.x, y: projection.bounds.maximum.y),
        ]
        let transformed = sourceCorners.map {
            Self.transform($0, around: computedCenter, presentation: presentation)
        }
        bounds = .init(
            minimum: .init(
                x: transformed.map(\.x).min() ?? projection.bounds.minimum.x,
                y: transformed.map(\.y).min() ?? projection.bounds.minimum.y
            ),
            maximum: .init(
                x: transformed.map(\.x).max() ?? projection.bounds.maximum.x,
                y: transformed.map(\.y).max() ?? projection.bounds.maximum.y
            )
        )
    }

    func point(_ value: RoomFloorPlanPoint) -> RoomFloorPlanPoint {
        Self.transform(value, around: center, presentation: presentation)
    }

    /// Converts a screen-relative direction such as "up on plan" back into
    /// the unchanged room-coordinate vector used by manual orientation.
    func worldDirection(fromDisplayed value: RoomFloorPlanPoint) -> RoomRedesignVector3 {
        var x = value.x
        var z = value.y
        if presentation.isMirroredHorizontally { x = -x }
        for _ in 0..<presentation.quarterTurnsClockwise {
            (x, z) = (z, -x)
        }
        return .init(x: x, y: 0, z: z)
    }

    private static func transform(
        _ value: RoomFloorPlanPoint,
        around center: RoomFloorPlanPoint,
        presentation: RoomTopDownPresentationTransform
    ) -> RoomFloorPlanPoint {
        var x = value.x - center.x
        var y = value.y - center.y
        for _ in 0..<presentation.quarterTurnsClockwise {
            (x, y) = (-y, x)
        }
        if presentation.isMirroredHorizontally { x = -x }
        return .init(x: center.x + x, y: center.y + y)
    }
}

private struct RoomOrientationPlanPreview: View {
    let presentation: RoomOrientationReviewPresentation
    let presentationTransform: RoomTopDownPresentationTransform
    let selectedFeatureID: String
    let direction: RoomRedesignVector3?
    let selectionLabel: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                drawProjection(context: &context, size: size)
            }
            Text(presentationStatus)
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedOnDark)
                .padding(12)
        }
        .frame(minHeight: 210, idealHeight: 230)
        .background(AppPalette.captureBlack)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppPalette.blueprintOnDark.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Top-down room reference. \(selectionLabel). The amber arrow points inward.")
        .accessibilityIdentifier("orientation.planPreview")
    }

    private func drawProjection(context: inout GraphicsContext, size: CGSize) {
        let display = RoomOrientationPlanDisplayTransform(
            projection: presentation.projection,
            presentation: presentationTransform
        )
        let bounds = display.bounds
        let inset: CGFloat = 26
        let worldWidth = max(bounds.width, 0.01)
        let worldHeight = max(bounds.height, 0.01)
        let width = CGFloat(worldWidth)
        let height = CGFloat(worldHeight)
        let scale = min(
            max(1, size.width - inset * 2) / width,
            max(1, size.height - inset * 2) / height
        )
        let drawnWidth = width * scale
        let drawnHeight = height * scale
        let originX = (size.width - drawnWidth) / 2
        let originY = (size.height - drawnHeight) / 2

        func point(_ value: RoomFloorPlanPoint) -> CGPoint {
            let transformed = display.point(value)
            return CGPoint(
                x: originX + CGFloat(transformed.x - bounds.minimum.x) * scale,
                y: originY + CGFloat(transformed.y - bounds.minimum.y) * scale
            )
        }

        func polygon(for item: RoomFloorPlanItem) -> Path {
            var path = Path()
            guard let first = item.corners.first else { return path }
            path.move(to: point(first))
            for corner in item.corners.dropFirst() { path.addLine(to: point(corner)) }
            path.closeSubpath()
            return path
        }

        for item in presentation.projection.items {
            let role = role(for: item.kind)
            let path = polygon(for: item)
            switch role {
            case .floor:
                context.fill(path, with: .color(AppPalette.blueprintOnDark.opacity(0.10)))
            case .wall:
                context.stroke(
                    path,
                    with: .color(item.id == selectedFeatureID ? AppPalette.amberOnDark : AppPalette.blueprintOnDark.opacity(0.62)),
                    lineWidth: item.id == selectedFeatureID ? 5 : 2
                )
            case .window:
                context.stroke(path, with: .color(Color(uiColor: RoomSemanticVisualStyle.color(for: .window))), lineWidth: 3)
            case .door, .opening:
                let selected = item.id == selectedFeatureID
                context.stroke(
                    path,
                    with: .color(selected ? AppPalette.amberOnDark : AppPalette.blueprintOnDark),
                    lineWidth: selected ? 6 : 3
                )
            default:
                if !item.isStructural {
                    context.fill(path, with: .color(AppPalette.mutedOnDark.opacity(0.16)))
                }
            }
        }

        for (index, option) in presentation.entryOptions.enumerated() {
            let center = point(.init(x: option.positionMeters.x, y: option.positionMeters.z))
            let selected = option.featureID == selectedFeatureID
            let marker = CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)
            context.fill(
                Path(ellipseIn: marker),
                with: .color(selected ? AppPalette.amberOnDark : AppPalette.blueprintOnDark)
            )
            context.draw(
                Text("\(index + 1)")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.captureBlack),
                at: center
            )
        }

        guard let selectedItem = presentation.projection.items.first(where: { $0.id == selectedFeatureID }),
              let direction
        else { return }
        let startWorld = selectedItem.center
        let arrowLength = max(0.65, min(worldWidth, worldHeight) * 0.22)
        let endWorld = RoomFloorPlanPoint(
            x: startWorld.x + direction.x * arrowLength,
            y: startWorld.y + direction.z * arrowLength
        )
        let start = point(startWorld)
        let end = point(endWorld)
        var arrow = Path()
        arrow.move(to: start)
        arrow.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head: CGFloat = 10
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(
            x: end.x - head * cos(angle - .pi / 6),
            y: end.y - head * sin(angle - .pi / 6)
        ))
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(
            x: end.x - head * cos(angle + .pi / 6),
            y: end.y - head * sin(angle + .pi / 6)
        ))
        context.stroke(arrow, with: .color(AppPalette.amberOnDark), lineWidth: 3)
    }

    private var presentationStatus: String {
        var parts = ["TOP-DOWN"]
        if presentationTransform == .viewerAligned {
            parts.append("VIEW-ALIGNED")
        }
        if presentationTransform.quarterTurnsClockwise > 0 {
            parts.append("ROTATED \(presentationTransform.quarterTurnsClockwise * 90)°")
        }
        if presentationTransform.isMirroredHorizontally { parts.append("MIRRORED") }
        return parts.joined(separator: "  /  ")
    }

    private func role(for kind: String) -> RoomSemanticRole {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "wall": .wall
        case "door": .door
        case "window": .window
        case "opening": .opening
        case "floor": .floor
        case "ceiling": .ceiling
        default: .unknownObject
        }
    }
}

private struct RoomSpatialReviewView: View {
    private enum ReviewMode: String, CaseIterable, Identifiable {
        case suggestion = "Confirm suggestion"
        case manual = "Manual reference"
        var id: String { rawValue }
    }

    private enum FacingChoice: String, CaseIterable, Identifiable {
        case screenRight = "Right on plan"
        case screenLeft = "Left on plan"
        case screenUp = "Up on plan"
        case screenDown = "Down on plan"
        var id: String { rawValue }
        var displayedVector: RoomFloorPlanPoint {
            switch self {
            case .screenRight: return .init(x: 1, y: 0)
            case .screenLeft: return .init(x: -1, y: 0)
            case .screenUp: return .init(x: 0, y: -1)
            case .screenDown: return .init(x: 0, y: 1)
            }
        }
    }

    let projectID: String
    let revisionID: String
    let snapshot: RoomSemanticSnapshot
    let controller: RoomLibraryController

    @Environment(\.dismiss) private var dismiss
    @State private var binding: RoomRedesignSourceRevision?
    @State private var existingDocument: RoomLocalRedesignExtensionV2?
    @State private var mode: ReviewMode = .manual
    @State private var topDownPresentation = RoomTopDownPresentationTransform.viewerAligned
    @State private var selectedEntryID = ""
    @State private var selectedWallID = ""
    @State private var facing: FacingChoice = .screenUp
    @State private var request = ""
    @State private var scope = RoomRedesignScope.stage.rawValue
    @State private var purpose = ""
    @State private var style = ""
    @State private var budget = ""
    @State private var accessibilityNeeds = ""
    @State private var circulation = ""
    @State private var materials = ""
    @State private var colors = ""
    @State private var desiredObjects = ""
    @State private var permissionByFeatureID: [String: String] = [:]
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var elements: [RoomSemanticElement] {
        snapshot.structuralElements + snapshot.objectElements
    }

    private var walls: [RoomSemanticElement] {
        snapshot.structuralElements.filter { RoomSemanticPresentation.role(for: $0) == .wall }
    }

    private var reviewPresentation: RoomOrientationReviewPresentation? {
        try? RoomOrientationReviewPresentation(snapshot: snapshot)
    }

    private var hasSuggestion: Bool {
        existingDocument?.orientation.source == .suggested
            || existingDocument?.orientation.suggestionEvidence != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading revision-bound orientation…")
                } else {
                    Form {
                        orientationSection
                        redesignBriefSection
                        permissionsSection
                        eligibilitySection
                        if let errorMessage {
                            Section {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(AppPalette.amber)
                                    .accessibilityIdentifier("orientation.error")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Spatial reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || isLoading || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("orientation.save")
                }
            }
            .task { await load() }
        }
    }

    private var orientationSection: some View {
        Section("Entrance and facing") {
            if hasSuggestion {
                Picker("Review method", selection: $mode) {
                    ForEach(ReviewMode.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("orientation.reviewMode")
            } else {
                Label(
                    "No clear app-owned entrance suggestion is available. Select a reference wall and facing direction.",
                    systemImage: "hand.point.up.left"
                )
                .font(AppTypography.callout)
            }

            if mode == .suggestion, let orientation = existingDocument?.orientation {
                if let presentation = reviewPresentation,
                   !presentation.entryOptions.isEmpty,
                   let reference = try? presentation.entryReference(featureID: selectedEntryID) {
                    let title = presentation.title(forEntryFeatureID: selectedEntryID)
                    RoomOrientationPlanPreview(
                        presentation: presentation,
                        presentationTransform: topDownPresentation,
                        selectedFeatureID: selectedEntryID,
                        direction: reference.inwardDirection,
                        selectionLabel: "\(title) is selected as the entrance"
                    )
                    presentationControls
                    Picker("Entrance", selection: $selectedEntryID) {
                        ForEach(presentation.entryOptions) { option in
                            Label(option.title, systemImage: RoomSemanticPresentation.token(for: option.role).symbolName)
                                .tag(option.featureID)
                        }
                    }
                    .accessibilityIdentifier("orientation.entryFeature")

                    let suggestedID = orientation.suggestionEvidence?.featureID
                    if selectedEntryID == suggestedID {
                        Label(
                            "App suggestion: \(title) · \(Int((orientation.confidence * 100).rounded()))% confidence",
                            systemImage: "sparkle.magnifyingglass"
                        )
                        .accessibilityIdentifier("orientation.suggestionSummary")
                    } else {
                        Label("Your correction: \(title)", systemImage: "hand.point.up.left.fill")
                            .foregroundStyle(AppPalette.amber)
                            .accessibilityIdentifier("orientation.correctionSummary")
                    }
                    Text("The numbered marker identifies the door or opening. The amber arrow shows the inward-facing direction. Confidence is an app heuristic, not measurement accuracy.")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedInk)
                } else {
                    Label("The detected entrance cannot be presented safely. Use Manual reference.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppPalette.amber)
                }
                Text("This suggestion is not eligible for AI export or publication until you save this confirmation.")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
                    .accessibilityIdentifier("orientation.suggestionDisclosure")
            } else {
                if walls.isEmpty {
                    Label("No wall is available for a manual reference.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppPalette.amber)
                } else {
                    if let presentation = reviewPresentation,
                       let wall = presentation.wallOptions.first(where: { $0.featureID == selectedWallID }) {
                        RoomOrientationPlanPreview(
                            presentation: presentation,
                            presentationTransform: topDownPresentation,
                            selectedFeatureID: wall.featureID,
                            direction: manualFacingVector,
                            selectionLabel: "\(wall.title) is the manual reference"
                        )
                        presentationControls
                    }
                    Picker("Reference wall", selection: $selectedWallID) {
                        ForEach(reviewPresentation?.wallOptions ?? []) { wall in
                            Label(wall.title, systemImage: RoomSemanticPresentation.token(for: wall.role).symbolName)
                                .tag(wall.featureID)
                        }
                    }
                    .accessibilityIdentifier("orientation.referenceWall")
                    Picker("Facing direction", selection: $facing) {
                        ForEach(FacingChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .accessibilityIdentifier("orientation.facingDirection")
                    Text("Axes describe this room revision only. They do not align rooms or reconstruct a property.")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedInk)
                }
            }
        }
    }

    private var presentationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    rotatePlanButton
                    mirrorPlanButton
                    resetPlanButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    rotatePlanButton
                    mirrorPlanButton
                    resetPlanButton
                }
            }
            Text("These controls change only this top-down presentation. Captured geometry, measurements, orientation axes, and canonical cameras remain unchanged.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
                .accessibilityIdentifier("orientation.presentationDisclosure")
        }
    }

    private var rotatePlanButton: some View {
        Button {
            topDownPresentation = topDownPresentation.rotatedClockwise()
        } label: {
            Label("Rotate 90°", systemImage: "rotate.right")
        }
        .buttonStyle(InstrumentButtonStyle(role: .secondary))
        .accessibilityLabel("Rotate plan 90 degrees clockwise")
        .accessibilityValue("\(topDownPresentation.quarterTurnsClockwise * 90) degrees")
        .accessibilityIdentifier("orientation.rotatePlan")
    }

    private var mirrorPlanButton: some View {
        Button {
            topDownPresentation = topDownPresentation.togglingHorizontalMirror()
        } label: {
            Label(
                topDownPresentation.isMirroredHorizontally ? "Unmirror" : "Mirror",
                systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right"
            )
        }
        .buttonStyle(InstrumentButtonStyle(role: .secondary))
        .accessibilityLabel("Mirror plan horizontally")
        .accessibilityValue(topDownPresentation.isMirroredHorizontally ? "On" : "Off")
        .accessibilityIdentifier("orientation.mirrorPlan")
    }

    private var resetPlanButton: some View {
        Button {
            topDownPresentation = .viewerAligned
        } label: {
            Label("Reset view", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(InstrumentButtonStyle(role: .secondary))
        .disabled(topDownPresentation == .viewerAligned)
        .accessibilityIdentifier("orientation.resetPlan")
    }

    private var manualFacingVector: RoomRedesignVector3 {
        guard let projection = reviewPresentation?.projection else {
            return .init(x: 0, y: 0, z: -1)
        }
        return RoomOrientationPlanDisplayTransform(
            projection: projection,
            presentation: topDownPresentation
        ).worldDirection(fromDisplayed: facing.displayedVector)
    }

    private var redesignBriefSection: some View {
        Section("Redesign brief") {
            TextField("What should change?", text: $request, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityIdentifier("orientation.request")
            Picker("Scope", selection: $scope) {
                Text("Stage").tag(RoomRedesignScope.stage.rawValue)
                Text("Renovate").tag(RoomRedesignScope.renovate.rawValue)
                Text("Reimagine").tag(RoomRedesignScope.reimagine.rawValue)
            }
            .accessibilityIdentifier("orientation.scope")
            DisclosureGroup("Optional constraints") {
                TextField("Purpose", text: $purpose)
                TextField("Style", text: $style)
                TextField("Budget", text: $budget)
                TextField("Accessibility needs", text: $accessibilityNeeds)
                TextField("Circulation", text: $circulation)
                TextField("Materials", text: $materials)
                TextField("Colors", text: $colors)
                TextField("Desired objects", text: $desiredObjects)
                Text("Separate multiple values with commas. These preferences remain separate from captured geometry and measurements.")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
            }
        }
    }

    private var permissionsSection: some View {
        Section("Per-feature permissions") {
            ForEach(elements) { element in
                let token = RoomSemanticPresentation.token(for: element)
                Picker(selection: permissionBinding(for: element)) {
                    Text("Preserve").tag(RoomFeatureRedesignPermission.preserve.rawValue)
                    Text("May change").tag(RoomFeatureRedesignPermission.mayChange.rawValue)
                    Text("Requested change").tag(RoomFeatureRedesignPermission.requestedChange.rawValue)
                } label: {
                    Label(element.label, systemImage: token.symbolName)
                }
                .accessibilityHint(token.accessibilityDescription(for: element))
                .accessibilityIdentifier("orientation.permission.\(element.id)")
            }
            Text("Permissions are request metadata only. They cannot overwrite captured geometry, evidence, measurements, or revision lineage.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
        }
    }

    private var eligibilitySection: some View {
        Section("Readiness") {
            Label(
                mode == .suggestion ? "Saving confirms the suggestion" : "Saving records a manual reference",
                systemImage: mode == .suggestion ? "checkmark.seal" : "hand.raised"
            )
            Text("No upload, account, hosted service, or AI archive is created here.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
        }
    }

    private func permissionBinding(for element: RoomSemanticElement) -> Binding<String> {
        Binding(
            get: {
                permissionByFeatureID[element.id]
                    ?? (element.mobility == .structural
                        ? RoomFeatureRedesignPermission.preserve.rawValue
                        : RoomFeatureRedesignPermission.mayChange.rawValue)
            },
            set: { permissionByFeatureID[element.id] = $0 }
        )
    }

    private func load() async {
        do {
            let binding = try await controller.redesignSourceBinding(
                projectID: projectID,
                revisionID: revisionID
            )
            let document = try await controller.redesignState(sourceRevision: binding)
            self.binding = binding
            existingDocument = document
            if document?.orientation.source == .suggested
                || document?.orientation.suggestionEvidence != nil {
                mode = .suggestion
            } else {
                mode = .manual
            }
            selectedWallID = document?.orientation.referenceWallFeatureID
                ?? walls.first?.id
                ?? ""
            selectedEntryID = document?.orientation.entryFeatureID
                ?? document?.orientation.suggestionEvidence?.featureID
                ?? reviewPresentation?.entryOptions.first?.featureID
                ?? ""
            topDownPresentation = document?.orientation.topDownOrientation.presentationTransform
                ?? .viewerAligned
            if let intent = document?.redesignIntent {
                request = intent.request
                scope = intent.scope.rawValue
                purpose = intent.constraints?.purpose.joined(separator: ", ") ?? ""
                style = intent.constraints?.style.joined(separator: ", ") ?? ""
                budget = intent.constraints?.budget ?? ""
                accessibilityNeeds = intent.constraints?.accessibility.joined(separator: ", ") ?? ""
                circulation = intent.constraints?.circulation.joined(separator: ", ") ?? ""
                materials = intent.constraints?.materials.joined(separator: ", ") ?? ""
                colors = intent.constraints?.colors.joined(separator: ", ") ?? ""
                desiredObjects = intent.constraints?.desiredObjects.joined(separator: ", ") ?? ""
                permissionByFeatureID = Dictionary(uniqueKeysWithValues: intent.permissions.map {
                    ($0.featureID, $0.permission.rawValue)
                })
            }
            errorMessage = nil
        } catch {
            errorMessage = "The revision-bound orientation could not load: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func save() async {
        guard let binding else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let orientation: RoomOrientationContractV2
            let bounds = try RoomSpatialNormalization.bounds(of: snapshot)
            if mode == .suggestion, let prior = existingDocument?.orientation, hasSuggestion {
                guard let presentation = reviewPresentation else {
                    throw RoomProjectStoreError.invalidPackage("The detected entrance cannot be projected safely.")
                }
                let selectedReference = try presentation.entryReference(featureID: selectedEntryID)
                let suggestedID = prior.suggestionEvidence?.featureID ?? prior.entryFeatureID
                let confirmsOriginalSuggestion = selectedEntryID == suggestedID
                orientation = try RoomCanonicalCameraGenerator.makeOrientation(
                    sourceRevision: binding,
                    input: .init(
                        source: .confirmed,
                        confidence: 1,
                        entryPositionMeters: confirmsOriginalSuggestion
                            ? prior.entryPositionMeters : selectedReference.positionMeters,
                        inwardDirection: confirmsOriginalSuggestion
                            ? prior.inwardDirection : selectedReference.inwardDirection,
                        roomBounds: bounds,
                        topDownPresentation: topDownPresentation == .viewerAligned
                            ? nil : topDownPresentation,
                        entryFeatureID: selectedEntryID,
                        referenceWallFeatureID: nil,
                        suggestionEvidence: prior.suggestionEvidence
                    )
                )
            } else {
                guard let wall = walls.first(where: { $0.id == selectedWallID }) else {
                    throw RoomProjectStoreError.invalidPackage("Select a reference wall before saving manual orientation.")
                }
                let wallCenter = try RoomSpatialNormalization.position(of: wall)
                orientation = try RoomCanonicalCameraGenerator.makeOrientation(
                    sourceRevision: binding,
                    input: .init(
                        source: .manual,
                        confidence: 1,
                        entryPositionMeters: .init(
                            x: wallCenter.x,
                            y: bounds.minimum.y,
                            z: wallCenter.z
                        ),
                        inwardDirection: manualFacingVector,
                        roomBounds: bounds,
                        topDownPresentation: topDownPresentation == .viewerAligned
                            ? nil : topDownPresentation,
                        referenceWallFeatureID: wall.id
                    )
                )
            }
            guard let selectedScope = RoomRedesignScope(rawValue: scope) else {
                throw RoomProjectStoreError.invalidPackage("Select a valid redesign scope.")
            }
            let constraints = structuredConstraints()
            let permissions = try elements.map { element -> RoomFeaturePermissionContract in
                let raw = permissionBinding(for: element).wrappedValue
                guard let permission = RoomFeatureRedesignPermission(rawValue: raw) else {
                    throw RoomProjectStoreError.invalidPackage("Select a valid feature permission.")
                }
                return .init(featureID: element.id, permission: permission)
            }
            let intent = RoomRedesignIntentV2(
                request: request.trimmingCharacters(in: .whitespacesAndNewlines),
                scope: selectedScope,
                constraints: constraints,
                permissions: permissions
            )
            try intent.validate()
            let property = try await controller.property(containing: projectID)
            let document = RoomLocalRedesignExtensionV2(
                sourceRevision: binding,
                orientation: orientation,
                redesignIntent: intent,
                propertyMembership: property.map {
                    RoomPropertyMembershipContract(propertyID: $0.propertyID, roomProjectIDs: $0.roomProjectIDs)
                },
                conceptMetadata: existingDocument?.conceptMetadata ?? []
            )
            try RoomOrientationReadiness.requireEligible(
                document,
                expectedSourceRevision: binding,
                operation: .aiExport
            )
            try await controller.saveRedesignState(document, expectedSourceRevision: binding)
            dismiss()
        } catch {
            errorMessage = "Spatial reference was not saved: \(error.localizedDescription)"
        }
    }

    private func structuredConstraints() -> RoomRedesignStructuredConstraints? {
        let value = RoomRedesignStructuredConstraints(
            purpose: commaValues(purpose),
            style: commaValues(style),
            budget: budget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : budget.trimmingCharacters(in: .whitespacesAndNewlines),
            householdNeeds: [],
            accessibility: commaValues(accessibilityNeeds),
            circulation: commaValues(circulation),
            materials: commaValues(materials),
            colors: commaValues(colors),
            referenceImageIDs: [],
            desiredObjects: commaValues(desiredObjects)
        )
        let isEmpty = value.purpose.isEmpty && value.style.isEmpty && value.budget == nil
            && value.accessibility.isEmpty && value.circulation.isEmpty
            && value.materials.isEmpty && value.colors.isEmpty && value.desiredObjects.isEmpty
        return isEmpty ? nil : value
    }

    private func commaValues(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.split(separator: ",").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

private struct RoomPropertyGroupingView: View {
    let projectID: String
    let controller: RoomLibraryController

    @Environment(\.dismiss) private var dismiss
    @State private var properties: [RoomPropertyContainerV1] = []
    @State private var membership: RoomPropertyContainerV1?
    @State private var newName = ""
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Current group") {
                    if let membership {
                        Label(membership.displayName, systemImage: "house.and.flag")
                        Text("\(membership.roomProjectIDs.count) independent room project\(membership.roomProjectIDs.count == 1 ? "" : "s")")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.mutedInk)
                        Button("Remove this room", role: .destructive) {
                            Task { await removeFromCurrent() }
                        }
                        .accessibilityIdentifier("property.removeRoom")
                    } else {
                        Text("This room is not in a property group.")
                    }
                }

                Section("Assign existing") {
                    ForEach(properties.filter { $0.propertyID != membership?.propertyID }, id: \.propertyID) { property in
                        Button {
                            Task { await assign(to: property) }
                        } label: {
                            Label(property.displayName, systemImage: "folder.badge.plus")
                        }
                        .accessibilityIdentifier("property.assign.\(property.propertyID)")
                    }
                }

                Section("Create property group") {
                    TextField("Property name", text: $newName)
                        .accessibilityIdentifier("property.name")
                    Button("Create and assign") {
                        Task { await create() }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("property.create")
                }

                Section("Boundary") {
                    Label("Independent room projects only", systemImage: "square.stack.3d.down.right")
                    Text("Property groups contain no cross-room transforms, alignment, doorway connectivity, topology, or whole-property reconstruction.")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedInk)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppPalette.amber)
                    }
                }
            }
            .overlay { if isLoading { ProgressView() } }
            .navigationTitle("Property group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        do {
            properties = try await controller.properties()
            membership = try await controller.property(containing: projectID)
            errorMessage = nil
        } catch {
            errorMessage = "Property groups could not load: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let now = Date()
        await detachCurrentIfNeeded()
        do {
            try await controller.saveProperty(
                RoomPropertyContainerV1(
                    propertyID: "property-\(UUID().uuidString.lowercased())",
                    displayName: name,
                    roomProjectIDs: [projectID],
                    createdAt: now,
                    updatedAt: now
                )
            )
            newName = ""
            await reload()
        } catch {
            errorMessage = "Property group was not created: \(error.localizedDescription)"
        }
    }

    private func assign(to property: RoomPropertyContainerV1) async {
        await detachCurrentIfNeeded()
        var updated = property
        if !updated.roomProjectIDs.contains(projectID) {
            updated.roomProjectIDs.append(projectID)
            updated.roomProjectIDs.sort()
        }
        updated.updatedAt = Date()
        do {
            try await controller.saveProperty(updated)
            await reload()
        } catch {
            errorMessage = "Room was not assigned: \(error.localizedDescription)"
        }
    }

    private func removeFromCurrent() async {
        await detachCurrentIfNeeded()
        await reload()
    }

    private func detachCurrentIfNeeded() async {
        guard var current = membership else { return }
        current.roomProjectIDs.removeAll { $0 == projectID }
        do {
            if current.roomProjectIDs.isEmpty {
                try await controller.removeProperty(propertyID: current.propertyID)
            } else {
                current.updatedAt = Date()
                try await controller.saveProperty(current)
            }
            membership = nil
        } catch {
            errorMessage = "Existing property membership could not change: \(error.localizedDescription)"
        }
    }
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
    let aiRedesignModelFactory: RoomAIRedesignModelFactory
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
    @State private var showingSpatialReview = false
    @State private var showingPropertyGrouping = false
    @State private var aiRedesignModel: RoomAIRedesignProductionModel?
    @State private var showingAIRedesign = false
    @State private var preparingAIRedesign = false
    @State private var aiRedesignErrorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
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
        .sheet(isPresented: $showingSpatialReview, onDismiss: {
            Task { await reload() }
        }) {
            if let package, let head = package.revisions.last {
                RoomSpatialReviewView(
                    projectID: projectID,
                    revisionID: head.manifest.revisionID,
                    snapshot: head.payload.semanticSnapshot,
                    controller: controller
                )
            }
        }
        .sheet(isPresented: $showingPropertyGrouping) {
            RoomPropertyGroupingView(
                projectID: projectID,
                controller: controller
            )
        }
        .sheet(isPresented: $showingAIRedesign, onDismiss: {
            aiRedesignModel = nil
        }) {
            if let aiRedesignModel {
                RoomAIRedesignHostView(model: aiRedesignModel)
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

            spatialTruthSection

            aiRedesignSection

            // Capture quality remains bound to the immutable revision that
            // produced it. Later edits do not rebind or copy that report, so
            // the detail view deliberately finds the newest owning revision.
            if let qualityReport = package.revisions.reversed().compactMap(\.manifest.qualityReport).first {
                persistedQualitySection(qualityReport)
            }

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

    private func persistedQualitySection(_ report: RoomQualityReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RoomQualitySummaryView(
                records: report.records.map(RoomQualitySummaryRecord.init),
                acknowledged: report.saveAcknowledgement != nil,
                darkSurface: false,
                markerIdentifier: "detail.quality.summary"
            )
            ForEach(report.records.flatMap(\.findings), id: \.findingID) { finding in
                Label(
                    RoomQualityPresentation.guidance(for: finding),
                    systemImage: RoomQualityPresentation.symbol(for: finding.dimension)
                )
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.ink)
                .accessibilityLabel(RoomQualityPresentation.accessibilityDescription(for: finding))
            }
            Text("Bound to \(report.revisionID) · coordinate epoch \(report.coordinateSpaceEpochID)")
                .font(.caption)
                .foregroundStyle(AppPalette.mutedInk)
        }
    }

    // MARK: - Hero

    private var spatialTruthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SPATIAL REFERENCE")
                .font(AppTypography.measurement)
                .tracking(1.2)
                .foregroundStyle(AppPalette.blueprint)
            Text("Confirm the room entrance and facing direction before any future AI export or publication.")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.mutedInk)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    spatialReviewButton
                    propertyGroupingButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    spatialReviewButton
                    propertyGroupingButton
                }
            }
        }
        .padding(16)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var spatialReviewButton: some View {
        Button("Review orientation") {
            showingSpatialReview = true
        }
        .buttonStyle(InstrumentButtonStyle(role: .primary))
        .accessibilityIdentifier("detail.reviewOrientation")
    }

    private var propertyGroupingButton: some View {
        Button("Property group") {
            showingPropertyGrouping = true
        }
        .buttonStyle(InstrumentButtonStyle(role: .secondary))
        .accessibilityIdentifier("detail.propertyGrouping")
        .accessibilityHint("Groups independent room projects only; no alignment or connectivity is inferred.")
    }

    private var aiRedesignSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI ROOM PACKAGE / CONCEPT SETS")
                .font(AppTypography.measurement)
                .tracking(1.2)
                .foregroundStyle(AppPalette.blueprint)
            Text("Prepare a provider-neutral, revision-bound package; inspect its disclosure; then import visual concepts without changing room truth.")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await openAIRedesign() }
            } label: {
                if preparingAIRedesign {
                    ProgressView()
                } else {
                    Label("Open AI package workspace", systemImage: "shippingbox.and.arrow.backward")
                }
            }
            .buttonStyle(InstrumentButtonStyle(role: .primary))
            .disabled(preparingAIRedesign)
            .accessibilityIdentifier("detail.aiRedesign")
            .accessibilityHint("Requires a confirmed room orientation. No room data is uploaded automatically.")
            if let aiRedesignErrorMessage {
                Label(aiRedesignErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("detail.aiRedesignError")
            }
        }
        .padding(16)
        .background(
            AppPalette.raisedSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func openAIRedesign() async {
        guard !preparingAIRedesign else { return }
        preparingAIRedesign = true
        defer { preparingAIRedesign = false }
        do {
            aiRedesignModel = try await aiRedesignModelFactory.makeModel(
                projectID: projectID
            )
            aiRedesignErrorMessage = nil
            showingAIRedesign = true
        } catch {
            aiRedesignModel = nil
            aiRedesignErrorMessage = error.localizedDescription
        }
    }

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

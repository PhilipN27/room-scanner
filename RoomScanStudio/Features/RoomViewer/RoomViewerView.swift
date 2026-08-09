import SwiftUI
import RoomScanCore

private enum RoomViewerInputMode: String, CaseIterable, Identifiable {
    case orbit
    case pan

    var id: String { rawValue }
}

/// Saved-room inspection only. The black viewport contains normalized semantic
/// bounding boxes, not captured mesh/USDZ geometry and not a live AR camera.
@MainActor
struct RoomViewerView: View {
    let roomName: String
    let payload: RoomRevisionPayload

    @Environment(\.dismiss) private var dismiss
    @State private var camera = RoomViewerCamera.defaultState
    @State private var visibility = RoomViewerVisibility()
    @State private var inputMode: RoomViewerInputMode = .orbit
    @State private var previousDragTranslation: CGSize = .zero
    @State private var previousMagnificationScale: CGFloat = 1
    @State private var selectedElementID: String?
    @State private var errorMessage: String?

    private var scenePlan: RoomViewerScenePlan {
        RoomViewerScenePlan(payload: payload)
    }

    private var elements: [RoomSemanticElement] {
        scenePlan.structuralElements + scenePlan.objectElements
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("SAVED ROOM / VIEWER")
                        .font(AppTypography.measurement)
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.blueprint)

                    Text(roomName)
                        .font(AppTypography.editorial)
                        .foregroundStyle(AppPalette.ink)
                        .accessibilityIdentifier("viewer.title")

                    viewerCanvas
                    cameraControls
                    visibilityControls
                    selectionPanel

                    Label(
                        payload.semanticSnapshot.accuracyDisclaimer,
                        systemImage: "ruler"
                    )
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("viewer.disclaimer")

                    if camera.isNoClip {
                        Label(
                            "First-person is no-clip inspection. Semantic boxes are not collision or survey geometry.",
                            systemImage: "figure.walk"
                        )
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("viewer.noClipDisclosure")
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.amber)
                            .accessibilityIdentifier("viewer.error")
                    }
                }
                .padding(24)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("Saved room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("viewer.close")
                }
            }
        }
    }

    private var viewerCanvas: some View {
        RoomViewerRealityView(
            scenePlan: scenePlan,
            camera: camera,
            visibility: visibility
        )
        .frame(minHeight: 320)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 3) {
                Text(camera.mode == .orbit ? "ORBIT INSPECTION" : "FIRST-PERSON / NO-CLIP")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.blueprintOnDark)
                Text("Semantic bounding boxes only")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedOnDark)
            }
            .padding(14)
        }
        .background(AppPalette.captureBlack, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            // SwiftUI reports gesture values cumulatively. Feed the pure
            // reducer only the delta since the last update to avoid applying
            // the whole drag repeatedly and overshooting the camera.
            let delta = CGSize(
                width: value.translation.width - previousDragTranslation.width,
                height: value.translation.height - previousDragTranslation.height
            )
            previousDragTranslation = value.translation
            switch inputMode {
            case .orbit:
                apply(.orbit(
                    yawDeltaRadians: Double(delta.width) * 0.003,
                    pitchDeltaRadians: Double(delta.height) * 0.003
                ))
            case .pan:
                apply(.pan(delta: RoomPoint3D(
                    x: Double(delta.width) * 0.004,
                    y: 0,
                    z: Double(delta.height) * 0.004
                )))
            }
        }.onEnded { _ in
            previousDragTranslation = .zero
        })
        .simultaneousGesture(MagnificationGesture().onChanged { value in
            let incrementalScale = value / previousMagnificationScale
            previousMagnificationScale = value
            apply(.zoom(deltaMeters: Double(1 - incrementalScale) * 0.4))
        }.onEnded { _ in
            previousMagnificationScale = 1
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved room semantic viewer")
        .accessibilityValue("\(scenePlan.structuralElements.count) structural elements and \(scenePlan.objectElements.count) objects in \(camera.mode == .orbit ? \"orbit\" : \"first-person no-clip\") mode")
        .accessibilityHint("Shows semantic bounding boxes only. Measurements are estimates, not survey geometry.")
        .accessibilityIdentifier("viewer.canvas")
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CAMERA")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.blueprint)
            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                Button("Orbit") {
                    inputMode = .orbit
                    apply(.orbitMode)
                }
                .buttonStyle(.borderedProminent)
                .tint(inputMode == .orbit ? AppPalette.primaryAction : AppPalette.mutedInk)
                .accessibilityIdentifier("viewer.orbit")

                Button("Pan") {
                    inputMode = .pan
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("viewer.pan")

                Button("First person") {
                    apply(.firstPerson)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("viewer.firstPerson")

                Button("Reset") {
                    apply(.reset)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("viewer.reset")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                Button("Top") { apply(.top) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("viewer.top")
                Button("Front") { apply(.front) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("viewer.front")
                Button("Side") { apply(.side) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("viewer.side")
            }
        }
        .padding(16)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var visibilityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VISIBLE ROOTS")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.blueprint)
            Toggle("Structure", isOn: Binding(
                get: { visibility.structural },
                set: { visibility.structural = $0 }
            ))
            .accessibilityIdentifier("viewer.visibility.structural")
            Toggle("Objects", isOn: Binding(
                get: { visibility.objects },
                set: { visibility.objects = $0 }
            ))
            .accessibilityIdentifier("viewer.visibility.objects")
            Toggle("Measurements", isOn: Binding(
                get: { visibility.measurements },
                set: { visibility.measurements = $0 }
            ))
            .accessibilityIdentifier("viewer.visibility.measurements")
            Toggle("Annotations", isOn: Binding(
                get: { visibility.annotations },
                set: { visibility.annotations = $0 }
            ))
            .accessibilityIdentifier("viewer.visibility.annotations")
            Toggle("Photo markers", isOn: Binding(
                get: { visibility.photos },
                set: { visibility.photos = $0 }
            ))
            .accessibilityIdentifier("viewer.visibility.photos")
        }
        .font(AppTypography.bodyEmphasized)
        .tint(AppPalette.blueprint)
        .padding(16)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var selectionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SEMANTIC ITEMS")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.blueprint)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(elements) { element in
                        Button(element.label) {
                            selectedElementID = element.id
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedElementID == element.id ? AppPalette.blueprint : AppPalette.mutedInk)
                        .accessibilityIdentifier("viewer.selection.\(element.id)")
                    }
                }
            }
            if let selected = elements.first(where: { $0.id == selectedElementID }) {
                Text("\(selected.kind.uppercased()) / \(selected.dimensionsMeters.width, specifier: "%.2f") x \(selected.dimensionsMeters.height, specifier: "%.2f") x \(selected.dimensionsMeters.depth, specifier: "%.2f") m")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.ink)
                    .accessibilityIdentifier("viewer.selectedDetail")
            } else {
                Text("Select a semantic item to inspect its normalized dimensions.")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
            }
        }
        .padding(16)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func apply(_ action: RoomViewerCameraAction) {
        do {
            camera = try RoomViewerCameraReducer.reduce(camera, action: action)
            errorMessage = nil
        } catch {
            errorMessage = "The viewer ignored an invalid camera input."
        }
    }
}

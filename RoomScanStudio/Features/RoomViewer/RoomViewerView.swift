import SwiftUI
import RoomScanCore

/// Saved-room inspection only. The full-bleed viewport contains normalized
/// semantic bounding boxes, not captured mesh/USDZ geometry and not a live
/// AR camera. Presented as a `fullScreenCover` by the room profile screen;
/// this view owns its own Close control and has no inner NavigationStack.
@MainActor
struct RoomViewerView: View {
    let roomName: String
    let payload: RoomRevisionPayload

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    @State private var camera = RoomViewerCamera.defaultState
    @State private var visibility = RoomViewerVisibility()
    @State private var selectedElementID: String?
    @State private var errorMessage: String?
    @State private var showingLayers = false

    // Walk-mode joystick: a transient view-layer vector, never persisted in
    // the Codable RoomViewerCamera. `moveInput` is dispatched to the
    // reducer's `.move` action once per display-linked tick while
    // `joystickEngaged`; both are cleared on gesture end, mode change,
    // disappear, and scene deactivation so a stale drag can never keep
    // walking after the reason it started is gone.
    @State private var moveInput: CGVector = .zero
    @State private var joystickEngaged = false
    @State private var lastMoveTick: TimeInterval?

    private var scenePlan: RoomViewerScenePlan {
        RoomViewerScenePlan(payload: payload)
    }

    private var elements: [RoomSemanticElement] {
        scenePlan.structuralElements + scenePlan.objectElements
    }

    var body: some View {
        ZStack {
            viewerCanvas
                .ignoresSafeArea()

            walkTicker

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.amberOnDark)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("viewer.error")
                }
                bottomChrome
            }
        }
        .background(AppPalette.captureBlack.ignoresSafeArea())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: camera.mode)
        .onChange(of: camera.mode) { _, newMode in
            guard newMode != .firstPerson else { return }
            clearWalkInput()
        }
        .onChange(of: joystickEngaged) { _, engaged in
            // TimelineView pauses the instant `engaged` goes false, so
            // tickMove's own "not engaged" branch (which nils this out)
            // never runs again — without this, a stale timestamp survives
            // to the next drag and its first tick measures a multi-second
            // gap instead of one frame.
            guard !engaged else { return }
            lastMoveTick = nil
        }
        .onDisappear {
            clearWalkInput()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase != .active else { return }
            clearWalkInput()
        }
    }

    // MARK: - Top chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewerChrome(
                onClose: { dismiss() },
                primaryModeLabel: "Orbit",
                secondaryModeLabel: "Walk",
                isPrimaryModeActive: camera.mode == .orbit,
                onSelectPrimaryMode: { apply(.orbitMode) },
                onSelectSecondaryMode: { apply(.firstPerson) },
                trailing: { layersButton }
            )

            Text(roomName)
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedOnDark)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("viewer.title")

            Text("SEMANTIC BOXES / NOT SURVEY GEOMETRY")
                .font(AppTypography.measurement)
                .tracking(1.0)
                .foregroundStyle(AppPalette.mutedOnDark)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("viewer.disclaimer")

            if camera.isNoClip {
                Label(
                    "Walk is no-clip inspection. Semantic boxes are not collision or survey geometry.",
                    systemImage: "figure.walk"
                )
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.amberOnDark)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("viewer.noClipDisclosure")
            }
        }
        // Canvas metadata remains legible at accessibility sizes without
        // consuming the entire viewport. Primary controls continue to follow
        // the user's uncapped Dynamic Type setting in `ViewerChrome`.
        .dynamicTypeSize(.xSmall ... .accessibility1)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.65), .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var layersButton: some View {
        Button {
            showingLayers = true
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(AppTypography.symbol)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppPalette.primaryOnDark)
        .accessibilityIdentifier("viewer.layers")
        .accessibilityLabel("Layers")
        .accessibilityHint("Choose which semantic layers are visible.")
        .popover(isPresented: $showingLayers) {
            layersPopoverContent
        }
    }

    private var layersPopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("VISIBLE LAYERS")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
            Toggle("Structure", isOn: $visibility.structural)
                .accessibilityIdentifier("viewer.visibility.structural")
            Toggle("Objects", isOn: $visibility.objects)
                .accessibilityIdentifier("viewer.visibility.objects")
            Toggle("Measurements", isOn: $visibility.measurements)
                .accessibilityIdentifier("viewer.visibility.measurements")
            Toggle("Annotations", isOn: $visibility.annotations)
                .accessibilityIdentifier("viewer.visibility.annotations")
            Toggle("Photo markers", isOn: $visibility.photos)
                .accessibilityIdentifier("viewer.visibility.photos")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .tint(AppPalette.blueprint)
        .frame(minWidth: 260)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Canvas

    private var viewerCanvas: some View {
        RoomViewerRealityView(
            scenePlan: scenePlan,
            camera: camera,
            visibility: visibility,
            selectedElementID: selectedElementID,
            onCameraAction: apply
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved room semantic viewer")
        .accessibilityValue("\(scenePlan.structuralElements.count) structural elements and \(scenePlan.objectElements.count) objects in \(camera.mode == .orbit ? "orbit" : "walk") mode")
        .accessibilityHint("Shows semantic bounding boxes only. Measurements are estimates, not survey geometry. One finger drags to look or orbit; two fingers pan and pinch zooms in orbit mode.")
        .accessibilityIdentifier("viewer.canvas")
    }

    /// A hidden, display-linked tick that advances the walk camera while the
    /// joystick is engaged. Paused whenever there is nothing to advance, so
    /// it costs nothing in orbit mode or with an idle thumb.
    private var walkTicker: some View {
        TimelineView(.animation(paused: !(camera.mode == .firstPerson && joystickEngaged))) { timeline in
            Color.clear
                .onChange(of: timeline.date) { _, newDate in
                    tickMove(at: newDate)
                }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tickMove(at date: Date) {
        guard camera.mode == .firstPerson, joystickEngaged else {
            lastMoveTick = nil
            return
        }
        let now = date.timeIntervalSinceReferenceDate
        defer { lastMoveTick = now }
        guard let lastMoveTick else { return }
        apply(.move(localX: moveInput.dx, localZ: moveInput.dy, deltaTime: now - lastMoveTick))
    }

    private func clearWalkInput() {
        joystickEngaged = false
        moveInput = .zero
        lastMoveTick = nil
    }

    // MARK: - Bottom chrome

    @ViewBuilder
    private var bottomChrome: some View {
        VStack(alignment: .leading, spacing: 12) {
            semanticLegend
            if !elements.isEmpty {
                selectionDrawer
            }

            switch camera.mode {
            case .orbit:
                orbitTray
                    .transition(reduceMotion ? .identity : .opacity)
            case .firstPerson:
                walkControls
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .padding(.top, 10)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A plain horizontal row, not `AdaptiveActionRow` — that component
    /// stacks vertically at `.compact` horizontal size class, which is every
    /// iPhone in portrait, turning this into four full-width rows over the
    /// full-bleed renderer. The spec calls for a single compact tray; the
    /// scroll view keeps it reachable at accessibility Dynamic Type sizes
    /// instead of wrapping.
    private var orbitTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button("Reset") { apply(.reset) }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.mutedOnDark)
                    .accessibilityIdentifier("viewer.reset")
                Button("Top") { apply(.top) }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.mutedOnDark)
                    .accessibilityIdentifier("viewer.top")
                Button("Front") { apply(.front) }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.mutedOnDark)
                    .accessibilityIdentifier("viewer.front")
                Button("Side") { apply(.side) }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.mutedOnDark)
                    .accessibilityIdentifier("viewer.side")
            }
            .frame(minHeight: 44)
        }
    }

    private var walkControls: some View {
        HStack(alignment: .bottom, spacing: 12) {
            RoomViewerWalkJoystick(
                moveInput: $moveInput,
                engaged: $joystickEngaged,
                onDirectionalStep: { localX, localZ in
                    apply(.move(
                        localX: localX,
                        localZ: localZ,
                        deltaTime: RoomViewerCameraReducer.maximumMoveDeltaTime
                    ))
                }
            )
            Text("Drag to look. Use the joystick to walk.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedOnDark)
                .padding(.bottom, 8)
            Spacer(minLength: 0)
        }
    }

    private var selectionDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(elements) { element in
                        let token = RoomSemanticPresentation.token(for: element)
                        Button {
                            selectedElementID = element.id
                        } label: {
                            Label(element.label, systemImage: token.symbolName)
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedElementID == element.id ? AppPalette.blueprintOnDark : AppPalette.mutedOnDark)
                        .accessibilityLabel(token.accessibilityDescription(for: element))
                        .accessibilityAddTraits(selectedElementID == element.id ? .isSelected : [])
                        .accessibilityIdentifier("viewer.selection.\(element.id)")
                    }
                }
            }

            if let selected = elements.first(where: { $0.id == selectedElementID }) {
                let token = RoomSemanticPresentation.token(for: selected)
                HStack(alignment: .top, spacing: 8) {
                    Label {
                        Text("\(token.displayName.uppercased()) / \(selected.dimensionsMeters.width, specifier: "%.2f") x \(selected.dimensionsMeters.height, specifier: "%.2f") x \(selected.dimensionsMeters.depth, specifier: "%.2f") m")
                    } icon: {
                        Image(systemName: token.symbolName)
                    }
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.primaryOnDark)
                        .accessibilityIdentifier("viewer.selectedDetail")
                    Spacer(minLength: 8)
                    Button {
                        selectedElementID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.mutedOnDark)
                    .accessibilityLabel("Dismiss selection detail")
                }
            }
        }
        .padding(12)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var semanticLegend: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: 3),
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(RoomSemanticRole.allCases, id: \.rawValue) { role in
                let token = RoomSemanticPresentation.token(for: role)
                Label(token.displayName, systemImage: token.symbolName)
                    .font(AppTypography.measurement)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(Color(uiColor: RoomSemanticVisualStyle.color(for: role)))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 7)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(style: StrokeStyle(
                                lineWidth: 1,
                                dash: token.materialPattern == .dashed ? [3, 2] : []
                            ))
                            .foregroundStyle(Color(uiColor: RoomSemanticVisualStyle.color(for: role)))
                    }
                    .accessibilityLabel("\(token.displayName), \(token.materialPattern.rawValue) semantic pattern")
                    .accessibilityIdentifier("viewer.legend.\(role.rawValue)")
            }
        }
        // The complete nine-role legend must remain simultaneously visible;
        // cap this dense reference key while all interactive controls retain
        // the user's full accessibility size.
        .dynamicTypeSize(.xSmall ... .xxxLarge)
        .accessibilityIdentifier("viewer.semanticLegend")
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

/// Safe-area-aware overlay chrome shared by the full-screen renderer
/// screens: a labeled Close affordance, a two-mode switcher, and a trailing
/// accessory slot (Layers here; the pattern is available to the mesh/splat
/// screens without forcing their existing dark toolbars to adopt it).
struct ViewerChrome<Trailing: View>: View {
    let onClose: () -> Void
    let primaryModeLabel: String
    let secondaryModeLabel: String
    let isPrimaryModeActive: Bool
    let onSelectPrimaryMode: () -> Void
    let onSelectSecondaryMode: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    closeButton
                    Spacer(minLength: 8)
                    trailing()
                }
                modeSwitcher
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                closeButton
                Spacer(minLength: 4)
                modeSwitcher
                Spacer(minLength: 4)
                trailing()
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Label("Close", systemImage: "chevron.left")
                .font(AppTypography.bodyEmphasized)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppPalette.primaryOnDark)
        .accessibilityIdentifier("viewer.close")
        .accessibilityLabel("Close viewer")
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            modeButton(primaryModeLabel, isActive: isPrimaryModeActive, identifier: "viewer.orbit", action: onSelectPrimaryMode)
            modeButton(secondaryModeLabel, isActive: !isPrimaryModeActive, identifier: "viewer.firstPerson", action: onSelectSecondaryMode)
        }
        .padding(3)
        .background(.white.opacity(0.1), in: Capsule())
    }

    private func modeButton(
        _ title: String,
        isActive: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.measurement)
                .textCase(.uppercase)
                .kerning(1.0)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? AppPalette.captureBlack : AppPalette.mutedOnDark)
        .background(isActive ? AppPalette.blueprintOnDark : Color.clear, in: Capsule())
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Bottom-leading virtual joystick for the semantic viewer's walk mode.
/// Shares its radial-clamp math with `SplatCameraController` (the same
/// shape used by the colored-mesh and splat Metal viewers) so a diagonal
/// drag cannot exceed the dial's radius, and exposes four named
/// accessibility actions as a directional alternative for VoiceOver and
/// Switch Control, which cannot perform a continuous drag gesture.
struct RoomViewerWalkJoystick: View {
    @Binding var moveInput: CGVector
    @Binding var engaged: Bool
    let onDirectionalStep: (_ localX: Double, _ localZ: Double) -> Void

    @State private var thumbOffset: CGSize = .zero
    private let radius: CGFloat = 56

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: 46, height: 46)
                .offset(thumbOffset)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    thumbOffset = SplatCameraController.radiallyClampedJoystickOffset(
                        value.translation,
                        radius: radius
                    )
                    engaged = true
                    moveInput = CGVector(
                        dx: thumbOffset.width / radius,
                        dy: -thumbOffset.height / radius
                    )
                }
                .onEnded { _ in
                    thumbOffset = .zero
                    engaged = false
                    moveInput = .zero
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Walk joystick")
        .accessibilityHint("Drag to walk through the room. Four walk actions are also available directly.")
        .accessibilityAction(named: "Walk forward") { onDirectionalStep(0, -1) }
        .accessibilityAction(named: "Walk backward") { onDirectionalStep(0, 1) }
        .accessibilityAction(named: "Strafe left") { onDirectionalStep(-1, 0) }
        .accessibilityAction(named: "Strafe right") { onDirectionalStep(1, 0) }
    }
}

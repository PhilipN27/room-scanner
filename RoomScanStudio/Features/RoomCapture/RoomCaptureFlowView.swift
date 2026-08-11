import SwiftUI
import RoomScanCore

/// During an active scan this is a full-screen live camera surface: the
/// driver's RoomCaptureView renders the camera feed with RoomPlan's live
/// model overlay, and controls float above it like the system camera.
/// Deterministic drivers have no camera view, so the semantic canvas remains
/// the scan surface on simulators and in UI tests. All other phases keep the
/// instrument-card layout.
struct RoomCaptureFlowView: View {
    @StateObject private var coordinator: RoomCaptureCoordinator
    let sceneMeshAvailable: Bool
    let onDiscard: () -> Void
    let onSaved: () -> Void
    @State private var routedTerminalPhase = false

    init(
        coordinator: RoomCaptureCoordinator,
        sceneMeshAvailable: Bool,
        onDiscard: @escaping () -> Void,
        onSaved: @escaping () -> Void
    ) {
        _coordinator = StateObject(wrappedValue: coordinator)
        self.sceneMeshAvailable = sceneMeshAvailable
        self.onDiscard = onDiscard
        self.onSaved = onSaved
    }

    var body: some View {
        Group {
            if isImmersiveScanPhase {
                immersiveScanLayout
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        if sceneMeshAvailable {
                            Label(
                                "Optional scene mesh is available, but raw mesh is not collected in this version. RoomPlan evidence remains the reviewed capture record.",
                                systemImage: "cube.transparent"
                            )
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.amberOnDark)
                            .accessibilityIdentifier("capture.meshV1Omitted")
                        } else {
                            Label(
                                "Optional scene mesh is unavailable. This does not block RoomPlan capture; raw-mesh evidence is omitted.",
                                systemImage: "cube.transparent"
                            )
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.amberOnDark)
                            .accessibilityIdentifier("capture.meshUnavailable")
                        }

                        phaseContent
                        cleanupErrorReadout

                        Label(
                            RoomCaptureState.nonSurveyAccuracyDisclaimer,
                            systemImage: "ruler"
                        )
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedOnDark)
                    }
                    .padding(24)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .background(AppPalette.captureBlack.ignoresSafeArea())
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(coordinator.blocksNavigationExit)
        .interactiveDismissDisabled(coordinator.blocksNavigationExit)
        .toolbar {
            if coordinator.showsDiscard {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close / Discard", role: .destructive) {
                        coordinator.discard()
                    }
                    .accessibilityIdentifier("capture.closeDiscard")
                }
            }
        }
        .onChange(of: coordinator.state.phase) { phase in
            guard !routedTerminalPhase else { return }
            switch phase {
            case .saved:
                routedTerminalPhase = true
                onSaved()
            case .discarded, .cancelled:
                routedTerminalPhase = true
                onDiscard()
            case .preflight, .requestingCamera, .ready, .starting, .scanning,
                 .stopping, .processing, .review, .saving, .failed, .discarding:
                break
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ROOMPLAN / CAPTURE")
                .font(AppTypography.measurement)
                .tracking(2)
                .foregroundStyle(AppPalette.amberOnDark)
            Text(titleForPhase)
                .font(AppTypography.editorial)
                .foregroundStyle(AppPalette.primaryOnDark)
                .accessibilityIdentifier("capture.title")
            Text("One reviewed attempt at a time. Save is available only after review; Discard never creates a room profile.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedOnDark)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch coordinator.state.phase {
        case .preflight:
            instrumentCard {
                Text("Prepare starts the camera-permission request. Nothing opens a camera or creates a package before this explicit action.")
                    .foregroundStyle(AppPalette.primaryOnDark)
                Button("Prepare capture") {
                    coordinator.prepare()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.blueprintOnDark)
                .accessibilityIdentifier("capture.prepare")
            }

        case .requestingCamera:
            instrumentCard {
                ProgressView("Requesting camera permission...")
                    .tint(AppPalette.blueprintOnDark)
                    .foregroundStyle(AppPalette.primaryOnDark)
            }

        case .ready:
            instrumentCard {
                Text("Camera access is ready. Optional GPS can still be declined; manual location remains editable in review.")
                    .foregroundStyle(AppPalette.primaryOnDark)
                actionRow(showStart: true)
                gpsReadout
            }

        case .starting, .scanning, .stopping, .processing:
            // These phases render through `immersiveScanLayout` instead of the
            // scrolling instrument stack.
            EmptyView()

        case .review:
            reviewInstrument

        case .saving:
            instrumentCard {
                ProgressView("Promoting the reviewed local package...")
                    .tint(AppPalette.blueprintOnDark)
                    .foregroundStyle(AppPalette.primaryOnDark)
                    .accessibilityIdentifier("capture.saving")
                Text("Save is in progress. Discard is intentionally unavailable until the promotion succeeds or fails.")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedOnDark)
            }

        case .saved:
            instrumentCard {
                ProgressView("Opening the local library...")
                    .tint(AppPalette.blueprintOnDark)
                    .foregroundStyle(AppPalette.primaryOnDark)
            }

        case .failed:
            failureInstrument

        case .discarding:
            instrumentCard {
                ProgressView("Cleaning attempt-local scratch data...")
                    .tint(AppPalette.amberOnDark)
                    .foregroundStyle(AppPalette.primaryOnDark)
            }

        case .discarded, .cancelled:
            EmptyView()
        }
    }

    /// `.starting` is immersive so the camera view is installed in a window
    /// before the driver runs the capture session — RoomCaptureView's
    /// documented order is display first, then run.
    private var isImmersiveScanPhase: Bool {
        switch coordinator.state.phase {
        case .starting, .scanning, .stopping, .processing:
            return true
        case .preflight, .requestingCamera, .ready, .review,
             .saving, .saved, .failed, .discarding, .discarded, .cancelled:
            return false
        }
    }

    /// Full-screen scan surface with floating controls, like the system
    /// camera. The live camera view fills the display when the driver has
    /// one; the semantic canvas remains the fallback surface.
    private var immersiveScanLayout: some View {
        ZStack(alignment: .bottom) {
            scanSurface
                .ignoresSafeArea()
            // At accessibility Dynamic Type sizes (where AdaptiveActionRow
            // stacks every action vertically) the overlay can outgrow the
            // screen, so it degrades to a scrollable panel instead of pushing
            // Stop/Discard out of the viewport.
            ViewThatFits(in: .vertical) {
                immersiveOverlayContent
                ScrollView {
                    immersiveOverlayContent
                }
            }
            .background(
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    private var immersiveOverlayContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            guidanceReadout
            scanReadout
            if coordinator.state.referencePhotoCount > 0 {
                Text("Reference photo attached")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedOnDark)
                    .accessibilityIdentifier("capture.photoReady")
            }
            if coordinator.state.referencePhotoLastRequestFailed {
                Label(
                    "Reference photo failed. You can retry or stop the scan.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.amberOnDark)
                .accessibilityIdentifier("capture.photoError")
            }
            scanPhaseControls
            Label(
                RoomCaptureState.nonSurveyAccuracyDisclaimer,
                systemImage: "ruler"
            )
            .font(AppTypography.measurement)
            .foregroundStyle(AppPalette.mutedOnDark)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var scanSurface: some View {
        if let cameraView = coordinator.liveCameraView {
            RoomLiveCaptureViewRepresentable(cameraView: cameraView)
                .accessibilityIdentifier("capture.canvas")
        } else {
            RoomSemanticCanvas(snapshot: coordinator.liveSnapshot)
                .accessibilityIdentifier("capture.canvas")
        }
    }

    @ViewBuilder
    private var scanPhaseControls: some View {
        switch coordinator.state.phase {
        case .starting:
            ProgressView("Starting the capture attempt...")
                .tint(AppPalette.blueprintOnDark)
                .foregroundStyle(AppPalette.primaryOnDark)
            if coordinator.showsDiscard {
                discardButton
            }

        case .scanning:
            AdaptiveActionRow(alignment: .leading, spacing: 12) {
                if coordinator.state.referencePhotoRequestID != nil {
                    ProgressView("Reference photo in flight")
                        .tint(AppPalette.amberOnDark)
                        .foregroundStyle(AppPalette.primaryOnDark)
                        .accessibilityIdentifier("capture.photoInFlight")
                } else if coordinator.canRequestReferencePhoto {
                    Button("Reference photo") {
                        coordinator.requestReferencePhoto()
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.blueprintOnDark)
                    .accessibilityIdentifier("capture.referencePhoto")
                }

                Button("Stop scan") {
                    coordinator.stop()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.amberOnDark)
                .disabled(!coordinator.canStop)
                .accessibilityIdentifier("capture.stop")

                if coordinator.showsDiscard {
                    discardButton
                }
            }

        case .stopping:
            ProgressView("Finishing the scan before review...")
                .tint(AppPalette.blueprintOnDark)
                .foregroundStyle(AppPalette.primaryOnDark)

        case .processing:
            ProgressView("Preparing immutable review evidence...")
                .tint(AppPalette.blueprintOnDark)
                .foregroundStyle(AppPalette.primaryOnDark)
                .accessibilityIdentifier("capture.processing")
            if coordinator.showsDiscard {
                discardButton
            }

        case .preflight, .requestingCamera, .ready, .review,
             .saving, .saved, .failed, .discarding, .discarded, .cancelled:
            EmptyView()
        }
    }

    private var reviewInstrument: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoomSemanticCanvas(snapshot: coordinator.liveSnapshot)
                .frame(minHeight: 230)
                .accessibilityIdentifier("capture.canvas")
            scanReadout
            guidanceReadout
            Text("REVIEW METADATA")
                .font(AppTypography.measurement)
                .tracking(1.4)
                .foregroundStyle(AppPalette.blueprintOnDark)
            TextField("Room name", text: $coordinator.roomName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("capture.roomName")
            TextField("Manual location", text: $coordinator.manualLocation)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("capture.manualLocation")
            TextField("Notes", text: $coordinator.notes, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("capture.notes")
            TextField("Tags, separated by commas", text: $coordinator.tagsText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("capture.tags")

            gpsReadout

            if coordinator.state.failure == .saveFailed {
                Text(coordinator.errorMessage ?? "Save failed; review remains available.")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amberOnDark)
                    .accessibilityIdentifier("capture.saveError")
            }

            AdaptiveActionRow(alignment: .leading, spacing: 12) {
                if coordinator.canRequestGPS {
                    Button("Request GPS") {
                        coordinator.requestGPS()
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.blueprintOnDark)
                    .accessibilityIdentifier("capture.requestGPS")
                }
                Button("Save") {
                    coordinator.save()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.blueprintOnDark)
                .disabled(!coordinator.canSave)
                .accessibilityIdentifier("capture.save")
            }
            discardButton
        }
        .padding(18)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var failureInstrument: some View {
        instrumentCard {
            if coordinator.state.failure == .cameraDenied {
                Text("Camera permission was denied. Live capture cannot start, and no local profile was created.")
                    .foregroundStyle(AppPalette.primaryOnDark)
                    .accessibilityIdentifier("capture.cameraDenied")
            } else if coordinator.state.failure == .captureTerminated,
                      let reason = coordinator.state.captureTerminationReason {
                Label(
                    RoomCaptureTerminationPresentation.message(for: reason),
                    systemImage: "exclamationmark.triangle"
                )
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.amberOnDark)
                .accessibilityIdentifier("capture.termination")
            } else {
                Text(coordinator.errorMessage ?? "This capture attempt could not continue.")
                    .foregroundStyle(AppPalette.primaryOnDark)
            }
            if coordinator.state.failure == .processingFailed && coordinator.state.retryable {
                Button("Retry processing") {
                    coordinator.retryProcessing()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.blueprintOnDark)
                .accessibilityIdentifier("capture.retry")
            }
            if coordinator.showsDiscard {
                discardButton
            }
        }
    }

    @ViewBuilder
    private func instrumentCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func actionRow(showStart: Bool) -> some View {
        AdaptiveActionRow(alignment: .leading, spacing: 12) {
            if showStart {
                Button("Start scan") {
                    coordinator.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.blueprintOnDark)
                .disabled(!coordinator.canStart)
                .accessibilityIdentifier("capture.start")
            }
            if coordinator.canRequestGPS {
                Button("Request GPS") {
                    coordinator.requestGPS()
                }
                .buttonStyle(.bordered)
                .tint(AppPalette.blueprintOnDark)
                .accessibilityIdentifier("capture.requestGPS")
            }
            if coordinator.showsDiscard {
                discardButton
            }
        }
    }

    private var discardButton: some View {
        Button("Discard", role: .destructive) {
            coordinator.discard()
        }
        .buttonStyle(.bordered)
        .tint(AppPalette.amberOnDark)
        .accessibilityIdentifier("capture.discard")
    }

    @ViewBuilder
    private var cleanupErrorReadout: some View {
        if let cleanupErrorMessage = coordinator.cleanupErrorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    cleanupErrorMessage,
                    systemImage: "exclamationmark.triangle"
                )
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.amberOnDark)
                .accessibilityIdentifier("capture.cleanupError")
                if coordinator.canRetryCleanup {
                    Button("Retry cleanup") {
                        coordinator.retryCleanup()
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.amberOnDark)
                    .accessibilityIdentifier("capture.retryCleanup")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var scanReadout: some View {
        HStack(spacing: 14) {
            let snapshot = coordinator.liveSnapshot
            Label(
                "\(snapshot?.structuralElements.count ?? 0) structural",
                systemImage: "square.dashed"
            )
            Label(
                "\(snapshot?.objectElements.count ?? 0) objects",
                systemImage: "cube"
            )
            Label(
                "\(coordinator.state.referencePhotoCount) photos",
                systemImage: "photo"
            )
            .accessibilityIdentifier("capture.photoCount")
        }
        .font(AppTypography.measurement)
            .foregroundStyle(AppPalette.mutedOnDark)
    }

    @ViewBuilder
    private var guidanceReadout: some View {
        if !coordinator.qualitativeGuidance.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("FIELD GUIDANCE")
                    .font(AppTypography.measurement)
                    .tracking(1.2)
                    .foregroundStyle(AppPalette.amberOnDark)
                ForEach(coordinator.qualitativeGuidance, id: \.self) { guidance in
                    Text(guidance)
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedOnDark)
                }
            }
            .accessibilityIdentifier("capture.guidance")
        }
    }

    @ViewBuilder
    private var gpsReadout: some View {
        switch coordinator.state.gpsPermission {
        case .denied:
            Text("GPS was denied. Manual location remains available.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.amberOnDark)
                .accessibilityIdentifier("capture.gpsDenied")
        case .authorized:
            Text(coordinator.capturedGPS == nil ? "GPS permission granted; no location fix was attached." : "GPS location attached to this review.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedOnDark)
        case .unknown:
            Text("GPS is optional and never blocks manual location or Save.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedOnDark)
        }
    }

    private var titleForPhase: String {
        switch coordinator.state.phase {
        case .preflight:
            return "Prepare a capture"
        case .requestingCamera:
            return "Waiting for camera permission"
        case .ready:
            return "Ready to scan"
        case .starting:
            return "Starting capture"
        case .scanning:
            return "Scanning the room"
        case .stopping:
            return "Finishing scan"
        case .processing:
            return "Preparing review"
        case .review:
            return "Review before save"
        case .saving:
            return "Saving reviewed capture"
        case .saved:
            return "Capture saved"
        case .failed:
            return "Capture needs attention"
        case .discarding:
            return "Discarding capture"
        case .discarded, .cancelled:
            return "Capture closed"
        }
    }
}

/// Recovery copy is kept categorical and actionable. It never reinterprets a
/// RoomPlan capture error as a measurement-confidence or geometric-accuracy
/// claim.
enum RoomCaptureTerminationPresentation {
    static func message(for reason: RoomCaptureTerminationReason) -> String {
        switch reason {
        case .deviceNotSupported:
            return "This device cannot run RoomPlan capture. Use the deterministic fixture path or a supported device; no room profile was created."
        case .deviceTooHot:
            return "The device is too hot. Let it cool before starting a new capture attempt; no room profile was created."
        case .exceedSceneSizeLimit:
            return "The scene-size limit was reached. Capture a smaller room or make a separate attempt; no room profile was created."
        case .invalidARConfiguration:
            return "The AR configuration became invalid. Close this attempt and start again on supported hardware."
        case .worldTrackingFailure:
            return "World tracking failed. Improve lighting and visible texture, then start a new attempt."
        case .internalError:
            return "RoomPlan stopped unexpectedly. Close this attempt and start a new one; no room profile was created."
        case .unknown:
            return "RoomPlan ended for an unknown reason. Close this attempt and start a new one; no room profile was created."
        }
    }
}

/// Hosts the driver-owned live capture UIView (RoomPlan's camera + live model
/// overlay). The driver keeps ownership; this wrapper only parents it for the
/// duration of the scan phases.
private struct RoomLiveCaptureViewRepresentable: UIViewRepresentable {
    let cameraView: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        attach(cameraView, to: container)
        return container
    }

    /// Reclaims the shared camera view only when it is unparented or its
    /// current host has left the window. During a navigation transition two
    /// hosts can briefly coexist; without this guard each would steal the
    /// singleton view back on every update, flickering the feed.
    func updateUIView(_ container: UIView, context: Context) {
        guard cameraView.superview !== container else { return }
        if cameraView.superview == nil || cameraView.superview?.window == nil {
            attach(cameraView, to: container)
        }
    }

    private func attach(_ view: UIView, to container: UIView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

private struct RoomSemanticCanvas: View {
    let snapshot: RoomSemanticSnapshot?

    var body: some View {
        Canvas { context, size in
            let elements = (snapshot?.structuralElements ?? [])
                + (snapshot?.objectElements ?? [])
            let corners = elements.flatMap { $0.polygonCorners ?? [] }
            let xValues = corners.map(\.x)
            let yValues = corners.map(\.y)
            let minX = xValues.min() ?? -2
            let maxX = xValues.max() ?? 2
            let minY = yValues.min() ?? -2
            let maxY = yValues.max() ?? 2
            let xSpan = max(maxX - minX, 0.01)
            let ySpan = max(maxY - minY, 0.01)

            for (index, element) in elements.enumerated() {
                let color = element.mobility == .structural
                    ? AppPalette.blueprintOnDark
                    : AppPalette.amberOnDark
                if let polygon = element.polygonCorners, polygon.count >= 3 {
                    var path = Path()
                    for (cornerIndex, corner) in polygon.enumerated() {
                        let point = CGPoint(
                            x: ((corner.x - minX) / xSpan) * Double(size.width),
                            y: Double(size.height) - ((corner.y - minY) / ySpan) * Double(size.height)
                        )
                        if cornerIndex == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                    path.closeSubpath()
                    context.stroke(path, with: .color(color), lineWidth: 2)
                    context.fill(path, with: .color(color.opacity(0.12)))
                } else {
                    let inset = CGFloat(26 + index * 18)
                    let width = max(42, size.width - inset * 2)
                    let height = max(34, size.height * 0.18)
                    let rect = CGRect(
                        x: inset,
                        y: CGFloat(index % 3) * (height + 16) + 28,
                        width: width,
                        height: height
                    )
                    context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(color), lineWidth: 2)
                }
            }

            if elements.isEmpty {
                let placeholder = Path(
                    roundedRect: CGRect(
                        x: 22,
                        y: 22,
                        width: max(0, size.width - 44),
                        height: max(0, size.height - 44)
                    ),
                    cornerRadius: 12
                )
                context.stroke(
                    placeholder,
                    with: .color(Color.white.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 1, dash: [7, 6])
                )
            }
        }
        .background(AppPalette.captureBlack, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            Text(snapshot == nil ? "LIVE SEMANTIC CANVAS / awaiting scan" : "LIVE SEMANTIC CANVAS / normalized geometry")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedOnDark)
                .padding(12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live semantic room geometry")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Shows normalized room geometry during a scan. Measurements are estimates, not survey evidence.")
    }

    private var accessibilitySummary: String {
        let structuralCount = snapshot?.structuralElements.count ?? 0
        let objectCount = snapshot?.objectElements.count ?? 0
        return "\(structuralCount) structural elements and \(objectCount) objects"
    }
}

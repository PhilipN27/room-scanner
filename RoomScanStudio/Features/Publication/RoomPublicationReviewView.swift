import RoomScanCore
import SwiftUI
import UIKit

/// Native pre-publication review. This surface deliberately never displays a
/// bearer link or private package content: it reviews the typed public draft,
/// its exact immutable bindings, and bounded link policy before publication.
struct RoomPublicationReviewView: View {
    @ObservedObject var model: RoomPublicationReviewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var isPreparing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    modeSection
                    snapshotSection
                    portalPreviewSection
                    brandingSection
                    linkControlsSection
                    disclosureSection
                    statusSection
                    actionSection
                    attribution
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .accessibilityIdentifier("publication.scroll")
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("Client portal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        pin = ""
                        model.dismissReview()
                        dismiss()
                    }
                        .accessibilityIdentifier("publication.close")
                }
            }
            .task {
                guard model.input == nil,
                      model.reviewState == .drafting,
                      model.isBrandingComplete,
                      !isPreparing
                else { return }
                isPreparing = true
                defer { isPreparing = false }
                do {
                    try await model.prepareReview()
                } catch {
                    model.present(error)
                }
            }
            .onDisappear {
                pin = ""
                model.dismissReview()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("PUBLISH CLIENT PORTAL", systemImage: "rectangle.3.group.bubble")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.blueprint)
                .textCase(.uppercase)
                .kerning(1.2)
            Text("Review an immutable public snapshot")
                .font(AppTypography.editorial)
                .foregroundStyle(AppPalette.ink)
                .accessibilityIdentifier("publication.title")
            Text("Only selected bounded derivatives are staged. Raw capture data, diagnostics, private notes, GPS, and revision history are not part of this portal.")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.mutedInk)
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Presentation scope")
            Picker("Presentation scope", selection: Binding(
                get: { model.options.mode },
                set: { model.setMode($0) }
            )) {
                ForEach(RoomPublicationReviewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("publication.mode")

            if let notice = model.independentRoomNotice {
                Label(notice, systemImage: "square.stack.3d.down.right")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("publication.independentRooms")
            } else {
                Text("A room portal uses one room-local orientation and layout.")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
            }
        }
    }

    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Reviewed immutable input")
            if let sourceDigest = model.sourceBindingsDigest,
               let selectionDigest = model.selectionManifestDigest {
                StatusRail(items: [
                    .init("source \(shortDigest(sourceDigest))", accent: true),
                    .init("selection \(shortDigest(selectionDigest))", accent: true),
                ])
                Text("Changing the source revision, mode, branding, selected concept, download option, or link policy requires a new review approval.")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
                ForEach(model.selectedSourceRevisions) { binding in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(binding.roomLabel) • exact source revision")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.mutedInk)
                        Text(binding.revisionID)
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.ink)
                            .textSelection(.enabled)
                    }
                    .accessibilityIdentifier("publication.source.\(binding.roomKey)")
                }
            } else if model.reviewState == .drafting || model.reviewState == .preparing {
                ProgressView("Preparing the public-only review candidate…")
                    .tint(AppPalette.blueprint)
                    .accessibilityIdentifier("publication.preparing")
            } else {
                Text("No local review candidate is loaded for this portal status. Local room data remains intact.")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
                    .accessibilityIdentifier("publication.snapshotUnavailable")
            }

            if let choices = model.input?.conceptChoices, !choices.isEmpty {
                ForEach(choices) { choice in
                    Toggle(choice.label, isOn: Binding(
                        get: { model.options.selectedConceptIDs.contains(choice.id) },
                        set: { isSelected in
                            var selected = model.options.selectedConceptIDs
                            if isSelected { selected.insert(choice.id) } else { selected.remove(choice.id) }
                            model.setSelectedConceptIDs(selected)
                        }
                    ))
                    .font(AppTypography.callout)
                    .accessibilityIdentifier("publication.concept.\(choice.id)")
                }
            }
            if let packageChoices = model.input?.aiReadyPackageChoices,
               !packageChoices.isEmpty {
                Text("Optional AI-ready package")
                    .font(AppTypography.calloutEmphasized)
                    .foregroundStyle(AppPalette.ink)
                Text("Select one already-finalized local package to bind into this immutable snapshot. Its private package details are not shown in the portal.")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
                ForEach(packageChoices) { choice in
                    Toggle("Include \(choice.label)", isOn: Binding(
                        get: { model.options.selectedAIReadyPackageRoomKey == choice.publicRoomKey },
                        set: { selected in
                            model.setSelectedAIReadyPackageRoomKey(
                                selected ? choice.publicRoomKey : nil
                            )
                        }
                    ))
                    .font(AppTypography.callout)
                    .accessibilityIdentifier("publication.aiReadySelection.\(choice.publicRoomKey)")
                    .accessibilityHint("Changing this selection invalidates approval and requires a fresh public-only review.")
                }
            }
            if !model.reviewedRasters.isEmpty {
                Text("Exact selected public rasters")
                    .font(AppTypography.calloutEmphasized)
                    .foregroundStyle(AppPalette.ink)
                ForEach(model.reviewedRasters) { raster in
                    reviewedRasterPreview(raster)
                }
            }
            if let warnings = model.input?.qualityWarnings, !warnings.isEmpty {
                ForEach(warnings, id: \.code) { warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle")
                        .font(AppTypography.callout)
                        .foregroundStyle(AppPalette.amber)
                        .accessibilityIdentifier("publication.warning.\(warning.code)")
                }
            }
        }
    }

    private var portalPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Portal preview")
            TextField("Portal title (optional override)", text: Binding(
                get: { model.options.title },
                set: { model.updateTitle($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("publication.portalTitle")
            if let title = model.preparedPresentationTitle {
                Text(title)
                    .font(AppTypography.calloutEmphasized)
                    .foregroundStyle(AppPalette.ink)
                    .accessibilityIdentifier("publication.preparedTitle")
            } else {
                Text("The room or property’s current title will be shown after the public review is prepared.")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    previewTile("Floor plan", symbol: "viewfinder", detail: "Room-local layout and measured dimensions")
                    previewTile("3D orientation", symbol: "cube.transparent", detail: "A room-local starting view")
                    previewTile("Fallback", symbol: "doc.richtext", detail: "Static PDF and gallery when enabled")
                }
                VStack(alignment: .leading, spacing: 10) {
                    previewTile("Floor plan", symbol: "viewfinder", detail: "Room-local layout and measured dimensions")
                    previewTile("3D orientation", symbol: "cube.transparent", detail: "A room-local starting view")
                    previewTile("Fallback", symbol: "doc.richtext", detail: "Static PDF and gallery when enabled")
                }
            }
            Text("Original room evidence is authoritative. Concepts are visual references and do not change the room.")
                .font(AppTypography.calloutEmphasized)
                .foregroundStyle(AppPalette.ink)
                .accessibilityIdentifier("publication.originalAuthority")
        }
    }

    private var brandingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Constrained branding")
            TextField("Business name", text: Binding(
                get: { model.options.branding.businessName },
                set: { value in
                    var branding = model.options.branding
                    branding.businessName = value
                    model.updateBranding(branding)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("publication.businessName")
            TextField("Contact phone", text: Binding(
                get: { model.options.branding.phone },
                set: { value in
                    var branding = model.options.branding
                    branding.phone = value
                    model.updateBranding(branding)
                }
            ))
            .textContentType(.telephoneNumber)
            .keyboardType(.phonePad)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("publication.contactPhone")
            TextField("Website", text: Binding(
                get: { model.options.branding.website },
                set: { value in
                    var branding = model.options.branding
                    branding.website = value
                    model.updateBranding(branding)
                }
            ))
            .textContentType(.URL)
            .keyboardType(.URL)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("publication.contactWebsite")
            Picker("Semantic accent", selection: Binding(
                get: { model.options.branding.accent },
                set: { value in
                    var branding = model.options.branding
                    branding.accent = value
                    model.updateBranding(branding)
                }
            )) {
                ForEach(RoomPublishedSemanticAccent.allCases, id: \.self) { accent in
                    Text(accent.rawValue.capitalized).tag(accent)
                }
            }
            .accessibilityIdentifier("publication.accent")
            if let logo = model.options.branding.logo,
               let image = UIImage(data: logo.data) {
                HStack(spacing: 10) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Configured business logo. It will be freshly encoded as a bounded public branding asset.")
                        .font(AppTypography.callout)
                        .foregroundStyle(AppPalette.mutedInk)
                }
                .accessibilityIdentifier("publication.logoPreview")
            } else {
                Label("Optional business logo is supplied by the signed-in professional business profile when this build is configured.", systemImage: "building.2")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
                    .accessibilityIdentifier("publication.logoProvider")
            }
            if !model.isBrandingComplete {
                Label("Enter an owner business name and at least one public contact method before preparing the portal review.", systemImage: "person.text.rectangle")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("publication.brandingIncomplete")
            }
        }
    }

    private var linkControlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Portal link controls")
            Toggle("Use the server’s 30-day default", isOn: Binding(
                get: { model.options.linkControls.expiresAt == nil },
                set: { usesDefault in
                    var controls = model.options.linkControls
                    controls.setExpiration(usesDefault ? nil : model.minimumLinkExpiry, now: model.clockNow)
                    model.updateLinkControls(controls)
                }
            ))
            .accessibilityIdentifier("publication.serverDefaultExpiry")
            if model.options.linkControls.expiresAt != nil {
                DatePicker(
                    "Link expiry",
                    selection: Binding(
                        get: { model.options.linkControls.expiresAt ?? model.minimumLinkExpiry },
                        set: { date in model.setLinkExpiry(date) }
                    ),
                    in: model.minimumLinkExpiry...model.maximumLinkExpiry,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("publication.expiry")
            }
            Toggle("Require a PIN", isOn: Binding(
                get: { model.options.linkControls.requiresPIN },
                set: { enabled in
                    var controls = model.options.linkControls
                    controls.requiresPIN = enabled
                    model.updateLinkControls(controls)
                    if !enabled { pin = "" }
                }
            ))
            .accessibilityIdentifier("publication.pin")
            if model.options.linkControls.requiresPIN {
                SecureField("6 digit PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pin) { _, value in setPINInput(value) }
                    .accessibilityIdentifier("publication.pinValue")
                    .accessibilityHint("The PIN is sent only for server-side verification setup and is not included in the snapshot archive.")
            }
            if model.hasValidatedAIReadyPackage {
                Toggle("Allow AI-ready package download", isOn: Binding(
                    get: { model.options.linkControls.allowsAIReadyPackageDownload },
                    set: { enabled in
                        var controls = model.options.linkControls
                        controls.allowsAIReadyPackageDownload = enabled
                        model.updateLinkControls(controls)
                    }
                ))
                .accessibilityIdentifier("publication.aiDownload")
                .accessibilityHint("This per-link entitlement is available because the exact reviewed snapshot includes a validated AI-ready package.")
            } else {
                Toggle("Allow AI-ready package download", isOn: .constant(false))
                    .disabled(true)
                    .accessibilityIdentifier("publication.aiDownload")
                Label("AI-ready package download is unavailable until this snapshot contains an exact, validated AI-ready package asset.", systemImage: "lock")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
                    .accessibilityIdentifier("publication.aiDownloadUnavailable")
            }
            Toggle("Enable floor-plan PDF fallback", isOn: Binding(
                get: { model.options.staticDownloads.allowsFloorPlanPDF },
                set: { enabled in
                    var downloads = model.options.staticDownloads
                    downloads.allowsFloorPlanPDF = enabled
                    model.updateStaticDownloads(downloads)
                }
            ))
            .accessibilityIdentifier("publication.floorPlanPDF")
            Toggle("Enable gallery ZIP fallback", isOn: Binding(
                get: { model.options.staticDownloads.allowsGalleryZIP },
                set: { enabled in
                    var downloads = model.options.staticDownloads
                    downloads.allowsGalleryZIP = enabled
                    model.updateStaticDownloads(downloads)
                }
            ))
            .accessibilityIdentifier("publication.galleryZIP")
            Toggle("Allow verified feedback", isOn: Binding(
                get: { model.options.linkControls.allowsFeedback },
                set: { enabled in
                    var controls = model.options.linkControls
                    controls.allowsFeedback = enabled
                    model.updateLinkControls(controls)
                }
            ))
            .accessibilityIdentifier("publication.feedback")
            Text("Links default to 30 days. Expiry, PIN protection, downloads, feedback, and immediate revocation are enforced by the hosted portal; this review never shows bearer link material.")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.mutedInk)
        }
    }

    private var disclosureSection: some View {
        Toggle("I confirm this public snapshot contains only the reviewed portal derivatives.", isOn: Binding(
            get: { model.options.disclosureConfirmed },
            set: { model.setDisclosureConfirmed($0) }
        ))
        .font(AppTypography.calloutEmphasized)
        .accessibilityIdentifier("publication.disclosure")
        .accessibilityHint("Required before approving the exact source and selection digest.")
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.reviewState {
        case .drafting, .preparing:
            if !model.isBrandingComplete {
                Label("Owner branding is incomplete. The review has not been prepared.", systemImage: "person.text.rectangle")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("publication.brandingNeeded")
            }
        case .readyForApproval:
            Label(model.approval == nil ? "Ready for disclosure approval." : "Exact review approval is ready to publish.", systemImage: "checkmark.seal")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.blueprint)
                .accessibilityIdentifier("publication.ready")
        case .approvalInvalidated:
            Label("Review approval was invalidated by a changed source, selection, or portal control.", systemImage: "arrow.triangle.2.circlepath")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.amber)
                .accessibilityIdentifier("publication.invalidated")
        case .publishing:
            ProgressView("Building the public-only archive and authorizing the portal link…")
                .tint(AppPalette.blueprint)
        case .allocationPending:
            Label("The immutable allocation is pending hosted validation. Retry will reconcile this exact allocation before any new upload.", systemImage: "clock.badge.exclamationmark")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.amber)
                .accessibilityIdentifier("publication.allocationPending")
        case .linkPending:
            Label("The immutable snapshot is retained. Portal-link authorization can be retried without creating another snapshot.", systemImage: "link.badge.plus")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.amber)
                .accessibilityIdentifier("publication.linkPending")
        case .published:
            Label("Portal link is active. Immediate revocation remains available.", systemImage: "checkmark.shield")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.blueprint)
                .accessibilityIdentifier("publication.published")
        case .revoked:
            Label("Portal link is revoked. Existing portal sessions and protected assets must be denied by the service.", systemImage: "xmark.shield")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.amber)
                .accessibilityIdentifier("publication.revoked")
        case let .rejected(code):
            Label(code.map { "Hosted validation rejected this allocation (\($0)). Local rooms and private recovery remain intact." }
                ?? "Hosted validation rejected this allocation. Local rooms and private recovery remain intact.", systemImage: "xmark.shield")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.amber)
                .accessibilityIdentifier("publication.rejected")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.amber)
                .accessibilityIdentifier("publication.failure")
        }

        if let feedback = model.portalLinkStatus?.feedbackSummary {
            Text(feedbackSummaryText(feedback))
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.mutedInk)
                .accessibilityIdentifier("publication.feedbackSummary")
        }
    }

    private var actionSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons }
            VStack(alignment: .leading, spacing: 10) { actionButtons }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Refresh review") {
            Task {
                do { try await model.prepareReview() }
                catch { model.present(error) }
            }
        }
        .buttonStyle(InstrumentButtonStyle(role: .secondary))
        .accessibilityIdentifier("publication.prepare")
        .accessibilityHint("Rebuilds the public allowlist and current immutable control digests.")

        Button("Approve exact review") {
            do { try model.approveReview() }
            catch { model.present(error) }
        }
        .buttonStyle(InstrumentButtonStyle(role: .secondary))
        .disabled(model.preparation == nil || !model.options.disclosureConfirmed)
        .accessibilityIdentifier("publication.approve")

        Button("Publish portal") {
            Task {
                do { try await model.publish() }
                catch { model.present(error) }
            }
        }
        .buttonStyle(InstrumentButtonStyle(role: .primary))
        .disabled(model.approval == nil || model.reviewState == .publishing)
        .accessibilityIdentifier("publication.publish")
        .accessibilityHint("Requires a fresh device confirmation before the archive and portal link are authorized.")

        if model.portalLinkStatus?.lifecycle == .active {
            Button("Revoke portal link", role: .destructive) {
                Task {
                    do { try await model.revokePortalLink() }
                    catch { model.present(error) }
                }
            }
            .buttonStyle(InstrumentButtonStyle(role: .destructive))
            .accessibilityIdentifier("publication.revoke")
        }
    }

    private var attribution: some View {
        HStack(spacing: 8) {
            Image(systemName: "ruler")
            Text("Presented with RoomScanStudio")
        }
        .font(AppTypography.measurement)
        .foregroundStyle(AppPalette.mutedInk)
        .accessibilityIdentifier("publication.attribution")
    }

    private func sectionHeading(_ value: String) -> some View {
        Text(value)
            .font(AppTypography.section)
            .foregroundStyle(AppPalette.ink)
    }

    private func previewTile(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(AppTypography.symbol)
                .foregroundStyle(AppPalette.blueprint)
            Text(title)
                .font(AppTypography.calloutEmphasized)
                .foregroundStyle(AppPalette.ink)
            Text(detail)
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.mutedInk)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func reviewedRasterPreview(
        _ raster: RoomPublicationReviewedRaster
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let image = UIImage(data: raster.data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(AppTypography.symbol)
                            .foregroundStyle(AppPalette.mutedInk)
                    }
                }
                .frame(width: 112, height: 76)
                .clipped()
                .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(raster.displayLabel)
                        .font(AppTypography.calloutEmphasized)
                        .foregroundStyle(AppPalette.ink)
                    Text("\(raster.mediaType.rawValue) • pixel preview of public candidate")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedInk)
                    if let digest = raster.sealedSHA256,
                       let byteCount = raster.sealedByteCount {
                        Text("Sealed archive bytes: \(byteCount)")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.mutedInk)
                        Text(digest)
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.mutedInk)
                            .textSelection(.enabled)
                            .accessibilityLabel("Prepared raster digest \(digest)")
                    } else {
                        Text("Excluded from the current public closure. Include it and refresh review to seal new bytes.")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.amber)
                    }
                }
            }
            if raster.canBeExcluded {
                Toggle("Include this selected original", isOn: Binding(
                    get: { model.isRasterIncluded(raster.assetID) },
                    set: { model.setRasterIncluded(raster.assetID, included: $0) }
                ))
                .font(AppTypography.callout)
                .accessibilityIdentifier("publication.raster.include.\(raster.assetID)")
                .accessibilityHint("Changing this selection invalidates approval and requires a fresh public review.")
            } else if raster.assetClass == .floorPlan {
                Text("Required room-local floor-plan derivative.")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
            }
        }
        .padding(12)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("publication.raster.\(raster.assetID)")
    }

    private func shortDigest(_ value: String) -> String {
        String(value.prefix(10))
    }

    private func feedbackSummaryText(_ feedback: RoomPublicationFeedbackSummary) -> String {
        guard feedback.recordCount > 0 else { return "No verified feedback records yet." }
        if let latest = feedback.latestActionLabel {
            return "\(feedback.recordCount) immutable feedback record(s). Latest action: \(latest)."
        }
        return "\(feedback.recordCount) immutable feedback record(s)."
    }

    private func setPINInput(_ value: String) {
        // Clear both the field and model candidate on any invalid character or
        // excess digit: a visual seven-digit value must never retain a hidden
        // previous six-digit candidate for a later publish attempt.
        guard value.count <= 6, value.allSatisfy({ ("0"..."9").contains($0) }) else {
            pin = ""
            model.clearPIN()
            return
        }
        pin = value
        guard value.count == 6 else {
            // One through five digits are incomplete input, not a model
            // error. Clear any earlier complete candidate before returning.
            model.clearPIN()
            return
        }
        do { try model.setPIN(value) }
        catch { model.present(error) }
    }
}

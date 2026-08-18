import Combine
import SwiftUI
import UIKit

// MARK: - Presentation contract

/// UI-only vocabulary for the AI Room Package flow. The production adapter
/// translates these values to the canonical Core package contracts; keeping
/// this boundary small means the view never decides package eligibility.
enum RoomAIRedesignProfile: String, CaseIterable, Identifiable {
    case aiReady = "AI-ready"
    case complete = "Complete"

    var id: String { rawValue }
    var summary: String {
        switch self {
        case .aiReady: "Derived room evidence only; original capture media stays local."
        case .complete: "Adds selected original capture media after explicit review and consent."
        }
    }
}

enum RoomAIChangeRequest: String, CaseIterable, Identifiable {
    case preserve = "Preserve"
    case mayChange = "May change"
    case requestedChange = "Requested change"
    var id: String { rawValue }
}

enum RoomAIReviewState: String {
    case drafting, readyForReview, approved, stale, archiveReady, cleanupFailed
}

struct RoomAIReadinessItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let isReady: Bool
}

struct RoomAIImageReviewItem: Identifiable {
    let id: String
    let title: String
    let metadata: String
    let advisory: String?
    let previewData: Data?
    var isIncluded: Bool
    let allowsSelectionChanges: Bool

    init(
        id: String,
        title: String,
        metadata: String,
        advisory: String?,
        previewData: Data?,
        isIncluded: Bool,
        allowsSelectionChanges: Bool = true
    ) {
        self.id = id
        self.title = title
        self.metadata = metadata
        self.advisory = advisory
        self.previewData = previewData
        self.isIncluded = isIncluded
        self.allowsSelectionChanges = allowsSelectionChanges
    }
}

struct RoomAIArtifactInventoryItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let included: Bool
    let reason: String
}

enum RoomAIDisclosurePresentationPolicy {
    static func requiresRawEvidenceConsent(
        profile: RoomAIRedesignProfile,
        includesRawEvidence: Bool
    ) -> Bool {
        profile == .complete && includesRawEvidence
    }
}

enum RoomAIConceptMapping: String { case automatic, manual, unmatched }

struct RoomAIConceptItem: Identifiable {
    let id: String
    let name: String
    let provenance: String
    let sourceRevision: String
    let providerDisclosure: String?
    var mapping: RoomAIConceptMapping
    var mappingDetail: String
    var approved: Bool
    var archived: Bool
}

@MainActor
protocol RoomAIRedesignScreenModel: ObservableObject {
    var selectedProfile: RoomAIRedesignProfile { get set }
    var brief: String { get set }
    var intent: String { get set }
    var featureChoices: [String: RoomAIChangeRequest] { get set }
    var readiness: [RoomAIReadinessItem] { get }
    var images: [RoomAIImageReviewItem] { get }
    var inventory: [RoomAIArtifactInventoryItem] { get }
    var qualityAdvisories: [String] { get }
    var estimatedSize: String { get }
    var reviewState: RoomAIReviewState { get }
    var reviewInputsLocked: Bool { get }
    var includesRawEvidence: Bool { get }
    var externalProviderNoticeAccepted: Bool { get set }
    var completeRawConsent: Bool { get set }
    var reviewMessage: String? { get }
    var concepts: [RoomAIConceptItem] { get }
    var selectedConceptID: String? { get set }
    var canonicalViewChoices: [String] { get }
    var selectedCanonicalView: String { get set }
    var comparisonPresentation: RoomAIConceptComparisonPresentation? { get }

    func prepareReview()
    func excludeImage(_ id: String)
    func replaceImage(_ id: String)
    func approveReview()
    func shareArchive()
    func retryCleanup()
    func importLooseConcept()
    func importPackageConcept()
    func applyManualMapping()
    func toggleConceptApproval(_ id: String)
    func archiveConcept(_ id: String)
    func unarchiveConcept(_ id: String)
    func deleteConcept(_ id: String)
    func compareConcept(_ id: String)
    func dismissComparison()
}

/// A reusable, adapter-free screen. It deliberately accepts an observable
/// model rather than owning any package files, photo pickers, or provider API.
struct RoomAIRedesignView<Model: RoomAIRedesignScreenModel>: View {
    @ObservedObject var model: Model
    @State private var selectedTab = 0
    @State private var showingDeleteConfirmation = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Workspace", selection: $selectedTab) {
                    Text("Room package").tag(0)
                    Text("Concept Sets").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .accessibilityIdentifier("ai.workspace")

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if selectedTab == 0 { packageFlow } else { conceptsFlow }
                    }
                    .padding(20)
                    .frame(maxWidth: 840, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .accessibilityIdentifier(selectedTab == 0 ? "ai.scroll" : "concept.scroll")
            }
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle(selectedTab == 0 ? "AI Room Package" : "Concept Sets")
            .navigationBarTitleDisplayMode(.inline)
        }
        .confirmationDialog(
            "Delete this Concept Set?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Concept Set", role: .destructive) {
                if let id = model.selectedConceptID { model.deleteConcept(id) }
            }
            .accessibilityIdentifier("concept.delete.confirm")
            Button("Keep Concept Set", role: .cancel) {}
                .accessibilityIdentifier("concept.delete.cancel")
        } message: {
            Text("This removes the local Concept Set and its imported media. It does not change the room scan.")
        }
        .sheet(item: comparisonBinding) { comparison in
            comparisonView(comparison)
        }
    }

    private var packageFlow: some View {
        Group {
            folioHeader
            profileSection
            briefSection
            readinessSection
            reviewSection
            archiveSection
        }
    }

    private var folioHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LOCAL PACKAGE / REVIEW BEFORE HANDOFF")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.blueprint)
                .accessibilityIdentifier("ai.kicker")
            Text("Make a room brief that can be inspected before it leaves this device.")
                .font(AppTypography.editorial)
                .foregroundStyle(AppPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Preparing an archive never uploads room data. Sharing is an explicit, system-controlled next step.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(AppPalette.paperShadow)
        }
        .accessibilityElement(children: .contain)
    }

    private var profileSection: some View {
        section("1 / PACKAGE PROFILE", detail: "Choose the minimum evidence needed for the external tool.") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(RoomAIRedesignProfile.allCases) { profile in
                    Button {
                        model.selectedProfile = profile
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: model.selectedProfile == profile ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.selectedProfile == profile ? AppPalette.blueprint : AppPalette.mutedInk)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.rawValue).font(AppTypography.bodyEmphasized)
                                Text(profile.summary).font(AppTypography.callout).foregroundStyle(AppPalette.mutedInk)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(InstrumentButtonStyle(role: .secondary))
                    .accessibilityIdentifier("ai.profile.\(profile == .aiReady ? "ready" : "complete")")
                    .accessibilityLabel("\(profile.rawValue) package profile")
                    .accessibilityValue(model.selectedProfile == profile ? "Selected" : "Not selected")
                    .accessibilityHint(profile.summary)
                }
            }
        }
        .disabled(model.reviewInputsLocked)
    }

    private var briefSection: some View {
        section("2 / REDESIGN BRIEF", detail: "This brief is included in the package. Be specific about what must remain true.") {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Intent", selection: $model.intent) {
                    Text("Stage").tag("Stage")
                    Text("Renovate").tag("Renovate")
                    Text("Reimagine").tag("Reimagine")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("ai.intent")

                TextField("Describe the requested room direction", text: $model.brief, axis: .vertical)
                    .lineLimit(4...9)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ai.brief")
                    .accessibilityHint("Required before review can be prepared.")

                VStack(alignment: .leading, spacing: 10) {
                    Text("CONSTRAINT SUMMARY").font(AppTypography.measurement).foregroundStyle(AppPalette.mutedInk)
                    ForEach(model.featureChoices.keys.sorted(), id: \.self) { feature in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(feature).font(AppTypography.bodyEmphasized)
                            Picker("\(feature) treatment", selection: binding(for: feature)) {
                                ForEach(RoomAIChangeRequest.allCases) { request in
                                    Text(request.rawValue).tag(request)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("ai.constraint.\(stableID(feature))")
                        }
                    }
                }
            }
        }
        .disabled(model.reviewInputsLocked)
    }

    private var readinessSection: some View {
        section("3 / READINESS", detail: "Every item must point to this exact, sealed room revision.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.readiness) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isReady ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(item.isReady ? AppPalette.blueprint : AppPalette.amber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(AppTypography.bodyEmphasized)
                            Text(item.detail).font(AppTypography.callout).foregroundStyle(AppPalette.mutedInk)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ai.readiness.\(item.id)")
                }
                Button("Prepare review") { model.prepareReview() }
                    .buttonStyle(InstrumentButtonStyle(role: .primary))
                    .disabled(
                        model.reviewInputsLocked
                            || model.readiness.contains { !$0.isReady }
                    )
                    .accessibilityIdentifier("ai.prepare")
                    .accessibilityHint("Builds a local review. Nothing is uploaded.")
            }
        }
    }

    private var reviewSection: some View {
        section("4 / DISCLOSURE REVIEW", detail: "Check selected media, omissions, and provider boundary before approving.") {
            VStack(alignment: .leading, spacing: 18) {
                statusLine
                Text("SELECTED / RAW IMAGES").font(AppTypography.measurement).foregroundStyle(AppPalette.mutedInk)
                ForEach(model.images) { image in imageRow(image) }
                inventorySection
                providerNotice
                if model.includesRawEvidence { rawConsent }
                approvalControls
            }
        }
    }

    private var statusLine: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: reviewIcon)
                .foregroundStyle(reviewColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(reviewTitle).font(AppTypography.bodyEmphasized)
                if let message = model.reviewMessage {
                    Text(message).font(AppTypography.callout).foregroundStyle(AppPalette.mutedInk)
                }
            }
        }
        .accessibilityIdentifier("ai.review.status")
    }

    private func imageRow(_ image: RoomAIImageReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let previewData = image.previewData,
               let preview = UIImage(data: previewData) {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Selected image preview: \(image.title)")
                    .accessibilityIdentifier("ai.image.\(image.id).preview")
            } else {
                Label("Preview unavailable — exclude this image or refresh review.", systemImage: "photo.badge.exclamationmark")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("ai.image.\(image.id).previewUnavailable")
            }
            HStack(alignment: .top) {
                Image(systemName: image.isIncluded ? "photo" : "photo.badge.minus")
                    .foregroundStyle(image.isIncluded ? AppPalette.blueprint : AppPalette.mutedInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text(image.title).font(AppTypography.bodyEmphasized)
                    Text(image.metadata).font(AppTypography.measurement).foregroundStyle(AppPalette.mutedInk)
                    if let advisory = image.advisory {
                        Label(advisory, systemImage: "eye.trianglebadge.exclamationmark")
                            .font(AppTypography.callout)
                            .foregroundStyle(AppPalette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(image.isIncluded ? "INCLUDED" : "EXCLUDED")
                    .font(AppTypography.measurement)
                    .foregroundStyle(image.isIncluded ? AppPalette.blueprint : AppPalette.mutedInk)
            }
            if image.allowsSelectionChanges {
                AdaptiveActionRow {
                    Button(image.isIncluded ? "Exclude" : "Include") { model.excludeImage(image.id) }
                        .buttonStyle(InstrumentButtonStyle(role: .secondary))
                        .disabled(model.reviewInputsLocked)
                        .accessibilityIdentifier("ai.image.\(image.id).exclude")
                    Button("Replace") { model.replaceImage(image.id) }
                        .buttonStyle(InstrumentButtonStyle(role: .quiet))
                        .disabled(model.reviewInputsLocked)
                        .accessibilityIdentifier("ai.image.\(image.id).replace")
                        .accessibilityHint("Choose another local image; this does not open a provider.")
                }
            } else {
                Label(
                    "Included only through the Complete raw-evidence consent below.",
                    systemImage: "lock.shield"
                )
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.blueprint)
                .accessibilityIdentifier("ai.image.\(image.id).rawDisclosure")
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().overlay(AppPalette.paperShadow) }
        .accessibilityElement(children: .contain)
    }

    private var inventorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ARTIFACT INVENTORY / \(model.estimatedSize)")
                .font(AppTypography.measurement).foregroundStyle(AppPalette.mutedInk)
            ForEach(model.inventory) { item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: item.included ? "checkmark" : "minus")
                        .foregroundStyle(item.included ? AppPalette.blueprint : AppPalette.mutedInk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(AppTypography.calloutEmphasized)
                        Text("\(item.detail) — \(item.reason)")
                            .font(AppTypography.callout).foregroundStyle(AppPalette.mutedInk)
                    }
                }
                .accessibilityIdentifier("ai.inventory.\(item.id)")
            }
            Label("GPS coordinates and precise location are always excluded.", systemImage: "location.slash")
                .font(AppTypography.callout)
                .foregroundStyle(AppPalette.blueprint)
                .accessibilityIdentifier("ai.gps.excluded")
            ForEach(model.qualityAdvisories, id: \.self) { advisory in
                Label(advisory, systemImage: "exclamationmark.triangle")
                    .font(AppTypography.callout).foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("ai.quality.advisory")
            }
        }
    }

    private var providerNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("External provider boundary", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(AppTypography.bodyEmphasized).foregroundStyle(AppPalette.ink)
                .accessibilityIdentifier("ai.provider.notice")
            Text("If you share this archive with ChatGPT, Claude, Grok, or another external provider, that provider’s privacy terms, retention, account, and regional availability rules apply. Review those terms before uploading.")
                .font(AppTypography.callout).foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            Text("RoomScanStudio makes no upload, account, or provider-processing claim here.")
                .font(AppTypography.measurement).foregroundStyle(AppPalette.blueprint)
            Toggle(isOn: $model.externalProviderNoticeAccepted) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("I reviewed the external-provider boundary")
                        .font(AppTypography.bodyEmphasized)
                    Text("Sharing remains a separate system action; this acknowledgement does not upload anything.")
                        .font(AppTypography.callout)
                        .foregroundStyle(AppPalette.mutedInk)
                }
            }
            .tint(AppPalette.primaryAction)
            .disabled(model.reviewInputsLocked || model.reviewState != .readyForReview)
            .accessibilityIdentifier("ai.provider.acknowledge")
        }
    }

    private var rawConsent: some View {
        Toggle(isOn: $model.completeRawConsent) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Include selected original capture media")
                    .font(AppTypography.bodyEmphasized)
                Text("Complete packages may contain selected raw images. I reviewed this expanded disclosure and consent to include them.")
                    .font(AppTypography.callout).foregroundStyle(AppPalette.mutedInk)
            }
        }
        .tint(AppPalette.primaryAction)
        .disabled(model.reviewInputsLocked || model.reviewState != .readyForReview)
        .accessibilityIdentifier("ai.complete.rawConsent")
        .accessibilityHint("Required to approve a Complete package with selected original media.")
    }

    private var approvalControls: some View {
        AdaptiveActionRow {
            Button(approvalTitle) { model.approveReview() }
                .buttonStyle(InstrumentButtonStyle(role: .primary))
                .disabled(
                    model.reviewInputsLocked
                        || model.reviewState != .readyForReview
                        || !model.externalProviderNoticeAccepted
                        || (RoomAIDisclosurePresentationPolicy.requiresRawEvidenceConsent(
                            profile: model.selectedProfile,
                            includesRawEvidence: model.includesRawEvidence
                        ) && !model.completeRawConsent)
                )
                .accessibilityIdentifier("ai.disclosure.approve")
            if model.reviewState == .stale {
                Button("Refresh review") { model.prepareReview() }
                    .buttonStyle(InstrumentButtonStyle(role: .secondary))
                    .accessibilityIdentifier("ai.disclosure.refresh")
            }
        }
    }

    private var archiveSection: some View {
        Group {
            if model.reviewState == .archiveReady || model.reviewState == .cleanupFailed {
                section("5 / LOCAL ARCHIVE", detail: "A final archive is ready only after this disclosure approval.") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Package ready for a system share sheet.", systemImage: "archivebox.fill")
                            .font(AppTypography.bodyEmphasized).foregroundStyle(AppPalette.blueprint)
                        if model.reviewState == .cleanupFailed {
                            Label("The share finished, but temporary archive cleanup needs another attempt.", systemImage: "exclamationmark.triangle")
                                .font(AppTypography.callout).foregroundStyle(AppPalette.amber)
                            Button("Retry cleanup") { model.retryCleanup() }
                                .buttonStyle(InstrumentButtonStyle(role: .secondary))
                                .accessibilityIdentifier("ai.share.retryCleanup")
                        } else {
                            Button("Share local archive") { model.shareArchive() }
                                .buttonStyle(InstrumentButtonStyle(role: .primary))
                                .accessibilityIdentifier("ai.share")
                                .accessibilityHint("Opens the system share sheet. The temporary archive is cleaned after completion or cancellation.")
                        }
                    }
                }
            }
        }
    }

    private var conceptsFlow: some View {
        Group {
            section("CONCEPT SETS", detail: "Local visual references, separately preserved from room truth and package evidence.") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Import either a loose JPEG/PNG or a verified Concept Set package. Imported media is sanitized locally before persistence.")
                        .font(AppTypography.body).foregroundStyle(AppPalette.mutedInk)
                    AdaptiveActionRow {
                        Button("Import loose image") { model.importLooseConcept() }
                            .buttonStyle(InstrumentButtonStyle(role: .primary))
                            .accessibilityIdentifier("concept.import.loose")
                        Button("Import package") { model.importPackageConcept() }
                            .buttonStyle(InstrumentButtonStyle(role: .secondary))
                            .accessibilityIdentifier("concept.import.package")
                    }
                }
            }
            ForEach(model.concepts) { concept in conceptSection(concept) }
        }
    }

    private func conceptSection(_ concept: RoomAIConceptItem) -> some View {
        section("CONCEPT / \(concept.name.uppercased())", detail: concept.provenance) {
            VStack(alignment: .leading, spacing: 12) {
                factRail(label: "SOURCE REVISION", value: concept.sourceRevision)
                if let provider = concept.providerDisclosure {
                    factRail(label: "PROVIDER DISCLOSURE", value: provider)
                }
                mappingControls(concept)
                Toggle("Approved for comparison", isOn: Binding(
                    get: { concept.approved },
                    set: { _ in model.toggleConceptApproval(concept.id) }
                ))
                .tint(AppPalette.primaryAction)
                .accessibilityIdentifier("concept.\(concept.id).approved")
                HStack {
                    Text("ORIGINAL ↔ CONCEPT").font(AppTypography.measurement).foregroundStyle(AppPalette.mutedInk)
                    Spacer()
                    Button("Compare") {
                        model.compareConcept(concept.id)
                    }
                        .buttonStyle(InstrumentButtonStyle(role: .quiet))
                        .accessibilityIdentifier("concept.\(concept.id).compare")
                        .accessibilityHint("Shows original room evidence beside this Concept Set; it does not replace room truth.")
                }
                Text("The original scan remains the source of measurement and geometry. Concept media is visual reference only.")
                    .font(AppTypography.callout).foregroundStyle(AppPalette.mutedInk)
                AdaptiveActionRow {
                    Button(concept.archived ? "Unarchive" : "Archive") {
                        concept.archived ? model.unarchiveConcept(concept.id) : model.archiveConcept(concept.id)
                    }
                    .buttonStyle(InstrumentButtonStyle(role: .secondary))
                    .accessibilityIdentifier("concept.\(concept.id).archive")
                    Button("Delete", role: .destructive) {
                        model.selectedConceptID = concept.id
                        showingDeleteConfirmation = true
                    }
                    .buttonStyle(InstrumentButtonStyle(role: .destructive))
                    .accessibilityIdentifier("concept.\(concept.id).delete")
                }
            }
        }
    }

    private func mappingControls(_ concept: RoomAIConceptItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(mappingLabel(concept.mapping), systemImage: mappingIcon(concept.mapping))
                .font(AppTypography.bodyEmphasized)
                .foregroundStyle(concept.mapping == .unmatched ? AppPalette.amber : AppPalette.blueprint)
                .accessibilityIdentifier("concept.\(concept.id).mapping")
            Text(concept.mappingDetail).font(AppTypography.callout).foregroundStyle(AppPalette.mutedInk)
            if concept.mapping != .manual {
                Picker("Canonical room view", selection: $model.selectedCanonicalView) {
                    ForEach(model.canonicalViewChoices, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("concept.\(concept.id).canonicalView")
                Button("Map manually") {
                    model.selectedConceptID = concept.id
                    model.applyManualMapping()
                }
                .buttonStyle(InstrumentButtonStyle(role: .secondary))
                .accessibilityIdentifier("concept.\(concept.id).mapManual")
            }
        }
    }

    private var comparisonBinding: Binding<RoomAIConceptComparisonPresentation?> {
        Binding(
            get: { model.comparisonPresentation },
            set: { value in
                if value == nil { model.dismissComparison() }
            }
        )
    }

    private func comparisonView(
        _ comparison: RoomAIConceptComparisonPresentation
    ) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("ORIGINAL ROOM ↔ CONCEPT")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.blueprint)
                    Text("The original scan remains authoritative for geometry and measurement. The Concept Set is a visual reference only.")
                        .font(AppTypography.body)
                        .foregroundStyle(AppPalette.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            comparisonCard(
                                title: "Original room",
                                data: comparison.originalPreviewData,
                                fallback: "A local original-room preview is unavailable; the sealed revision remains authoritative."
                            )
                            comparisonCard(
                                title: comparison.conceptName,
                                data: comparison.conceptAttachmentData,
                                fallback: "The sanitized Concept attachment could not be displayed."
                            )
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            comparisonCard(
                                title: "Original room",
                                data: comparison.originalPreviewData,
                                fallback: "A local original-room preview is unavailable; the sealed revision remains authoritative."
                            )
                            comparisonCard(
                                title: comparison.conceptName,
                                data: comparison.conceptAttachmentData,
                                fallback: "The sanitized Concept attachment could not be displayed."
                            )
                        }
                    }
                    factRail(
                        label: "SOURCE REVISION",
                        value: comparison.sourceRevisionID
                    )
                    factRail(label: "MAPPING", value: comparison.mappingDetail)
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("Compare Concept")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.dismissComparison() }
                        .accessibilityIdentifier("concept.comparison.done")
                }
            }
            .accessibilityIdentifier("concept.comparison")
        }
    }

    private func comparisonCard(
        title: String,
        data: Data?,
        fallback: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppTypography.section)
                .foregroundStyle(AppPalette.ink)
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("\(title) image")
            } else {
                Label(fallback, systemImage: "photo.on.rectangle.angled")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppPalette.mutedInk)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.raisedSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppTypography.section).foregroundStyle(AppPalette.ink)
                Text(detail).font(AppTypography.callout).foregroundStyle(AppPalette.mutedInk).fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    private func factRail(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(AppTypography.measurement).foregroundStyle(AppPalette.mutedInk)
            Text(value).font(AppTypography.measurement).foregroundStyle(AppPalette.ink).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func binding(for feature: String) -> Binding<RoomAIChangeRequest> {
        Binding(get: { model.featureChoices[feature] ?? .preserve }, set: { model.featureChoices[feature] = $0 })
    }
    private func stableID(_ value: String) -> String { value.lowercased().replacingOccurrences(of: " ", with: "-") }
    private func mappingLabel(_ value: RoomAIConceptMapping) -> String { value == .automatic ? "Automatic mapping" : value == .manual ? "Manual mapping" : "Unmatched reference" }
    private func mappingIcon(_ value: RoomAIConceptMapping) -> String { value == .automatic ? "wand.and.stars" : value == .manual ? "link" : "questionmark.diamond" }
    private var reviewIcon: String { model.reviewState == .stale || model.reviewState == .cleanupFailed ? "exclamationmark.triangle" : "checkmark.seal" }
    private var reviewColor: Color { model.reviewState == .stale || model.reviewState == .cleanupFailed ? AppPalette.amber : AppPalette.blueprint }
    private var reviewTitle: String {
        switch model.reviewState {
        case .drafting: "Review has not been prepared"
        case .readyForReview: "Review ready — changes will make this review stale"
        case .approved: "Disclosure approved — finalizing local archive"
        case .stale: "Review is stale — refresh before approval"
        case .archiveReady: "Approved archive is ready"
        case .cleanupFailed: "Share cleanup needs attention"
        }
    }
    private var approvalTitle: String { model.reviewState == .stale ? "Review is stale" : "Approve disclosure" }
}

// MARK: - Deterministic launch fixture

/// Root launch integration should instantiate this model when the process is
/// launched with `--slice3-ui-fixture`. It intentionally contains no picker,
/// file-system, or network dependency, so UI tests exercise the information
/// architecture deterministically.
@MainActor
final class RoomAIRedesignScreenFixtureModel: RoomAIRedesignScreenModel {
    @Published var selectedProfile: RoomAIRedesignProfile = .aiReady {
        didSet {
            guard oldValue != selectedProfile else { return }
            updateFixtureProfile()
            reviewState = .stale
        }
    }
    @Published var brief = "Keep the north window clear; stage a calm reading and dining zone."
    @Published var intent = "Stage"
    @Published var featureChoices: [String : RoomAIChangeRequest] = ["Windows": .preserve, "Floor": .mayChange, "Storage wall": .requestedChange]
    @Published private(set) var readiness: [RoomAIReadinessItem] = [
        .init(id: "revision", title: "Exact room revision", detail: "revision-fixture-003 / sealed manifest", isReady: true),
        .init(id: "orientation", title: "Orientation contract", detail: "confirmed canonical view set", isReady: true),
        .init(id: "brief", title: "Brief", detail: "non-empty local request", isReady: true),
    ]
    @Published private(set) var images: [RoomAIImageReviewItem] = [
        .init(
            id: "north-window",
            title: "North window",
            metadata: "JPEG · 3024×4032 · derived 1.8 MB",
            advisory: "Sensitive-content advisory: reflection may show a person.",
            previewData: RoomAIRedesignScreenFixtureModel.fixtureImage(
                foreground: UIColor(red: 0.15, green: 0.48, blue: 0.52, alpha: 1),
                background: UIColor(red: 0.91, green: 0.87, blue: 0.73, alpha: 1)
            ),
            isIncluded: true
        ),
        .init(
            id: "entry",
            title: "Entry elevation",
            metadata: "JPEG · 3024×4032 · derived 1.5 MB",
            advisory: "Text advisory: inspect labels before sharing.",
            previewData: RoomAIRedesignScreenFixtureModel.fixtureImage(
                foreground: UIColor(red: 0.45, green: 0.28, blue: 0.20, alpha: 1),
                background: UIColor(red: 0.92, green: 0.89, blue: 0.82, alpha: 1)
            ),
            isIncluded: true
        ),
    ]
    @Published private(set) var inventory: [RoomAIArtifactInventoryItem] = [
        .init(id: "brief", title: "Brief and constraints", detail: "provider-neutral JSON", included: true, reason: "requested package context"),
        .init(id: "views", title: "Canonical derived views", detail: "sanitized JPEG set", included: true, reason: "selected evidence"),
        .init(id: "raw", title: "Original capture media", detail: "not selected", included: false, reason: "AI-ready profile excludes raw media"),
        .init(id: "worldmap", title: "World map / precise GPS", detail: "not eligible", included: false, reason: "always excluded"),
    ]
    let qualityAdvisories = ["One view has modest sharpness; inspect before external use."]
    let estimatedSize = "6.2 MB EST."
    @Published private(set) var reviewState: RoomAIReviewState = .readyForReview
    let reviewInputsLocked = false
    var includesRawEvidence: Bool { selectedProfile == .complete }
    @Published var externalProviderNoticeAccepted = false
    @Published var completeRawConsent = false
    @Published private(set) var reviewMessage: String? = "Plan digest and selected evidence are ready for inspection."
    @Published private(set) var concepts: [RoomAIConceptItem] = [
        .init(id: "linen-study", name: "Linen study", provenance: "Loose local JPEG · sanitized on import", sourceRevision: "revision-fixture-003", providerDisclosure: nil, mapping: .automatic, mappingDetail: "Matched north-window canonical view.", approved: false, archived: false),
        .init(id: "gallery-reference", name: "Gallery reference", provenance: "Verified Concept Set package · reopened from local store", sourceRevision: "revision-fixture-003", providerDisclosure: "Provider source disclosed by package author.", mapping: .unmatched, mappingDetail: "No confidence match; choose a canonical view manually.", approved: true, archived: false),
    ]
    @Published var selectedConceptID: String?
    let canonicalViewChoices = ["North window", "Entry elevation", "Storage wall"]
    @Published var selectedCanonicalView = "North window"
    @Published private(set) var comparisonPresentation: RoomAIConceptComparisonPresentation?

    init(readinessFailure: Bool = false) {
        guard readinessFailure else { return }
        readiness[1] = .init(
            id: "orientation",
            title: "Orientation contract",
            detail: "suggested only — confirm or set it manually before export",
            isReady: false
        )
        reviewState = .drafting
        reviewMessage = "The sealed room needs confirmed or manual orientation before a review can be prepared."
    }

    func prepareReview() {
        externalProviderNoticeAccepted = false
        completeRawConsent = false
        reviewState = .readyForReview
        reviewMessage = "Fresh local review prepared from the current plan."
    }
    func excludeImage(_ id: String) {
        guard images.contains(where: { $0.id == id && $0.allowsSelectionChanges }) else { return }
        updateImage(id) { $0.isIncluded.toggle() }
        reviewState = .stale
        reviewMessage = "Selection changed; approve a fresh review."
    }
    func replaceImage(_ id: String) {
        guard images.contains(where: { $0.id == id && $0.allowsSelectionChanges }) else { return }
        reviewState = .stale
        reviewMessage = "Replacement selected locally; review is stale."
    }
    func approveReview() {
        guard externalProviderNoticeAccepted,
              !RoomAIDisclosurePresentationPolicy.requiresRawEvidenceConsent(
                profile: selectedProfile,
                includesRawEvidence: includesRawEvidence
              ) || completeRawConsent else { return }
        reviewState = .archiveReady
        reviewMessage = "Disclosure recorded for this exact selection."
    }
    func shareArchive() { reviewMessage = "System share sheet requested; temporary archive lease remains active." }
    func retryCleanup() { reviewState = .archiveReady; reviewMessage = "Temporary archive cleanup succeeded." }
    func importLooseConcept() { appendConcept(name: "Imported local reference", provenance: "Loose local JPEG · sanitized on import") }
    func importPackageConcept() { appendConcept(name: "Imported package reference", provenance: "Verified Concept Set package · sanitized on import") }
    func applyManualMapping() {
        guard let id = selectedConceptID, let index = concepts.firstIndex(where: { $0.id == id }) else { return }
        let value = concepts[index]
        concepts[index] = .init(id: value.id, name: value.name, provenance: value.provenance, sourceRevision: value.sourceRevision, providerDisclosure: value.providerDisclosure, mapping: .manual, mappingDetail: "Manually mapped to \(selectedCanonicalView).", approved: value.approved, archived: value.archived)
    }
    func toggleConceptApproval(_ id: String) { mutateConcept(id) { item in item.approved.toggle() } }
    func archiveConcept(_ id: String) { mutateConcept(id) { item in item.archived = true } }
    func unarchiveConcept(_ id: String) { mutateConcept(id) { item in item.archived = false } }
    func deleteConcept(_ id: String) { concepts.removeAll { $0.id == id }; if selectedConceptID == id { selectedConceptID = nil } }
    func compareConcept(_ id: String) {
        guard let concept = concepts.first(where: { $0.id == id }) else { return }
        comparisonPresentation = .init(
            conceptID: concept.id,
            conceptName: concept.name,
            sourceRevisionID: concept.sourceRevision,
            mappingDetail: concept.mappingDetail,
            conceptAttachmentData: Self.fixtureImage(
                foreground: UIColor(red: 0.15, green: 0.48, blue: 0.52, alpha: 1),
                background: UIColor(red: 0.91, green: 0.87, blue: 0.73, alpha: 1)
            ),
            originalPreviewData: Self.fixtureImage(
                foreground: UIColor(red: 0.19, green: 0.20, blue: 0.18, alpha: 1),
                background: UIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1)
            )
        )
    }
    func dismissComparison() { comparisonPresentation = nil }

    private func updateFixtureProfile() {
        let rawID = "raw-rgb-0001"
        if selectedProfile == .complete {
            if !images.contains(where: { $0.id == rawID }) {
                images.append(.init(
                    id: rawID,
                    title: "Original capture frame 0001",
                    metadata: "JPEG · 3024×4032 · raw 2.1 MB",
                    advisory: "Complete raw evidence: inspect visible screens, photographs, text, and reflections.",
                    previewData: Self.fixtureImage(
                        foreground: UIColor(red: 0.19, green: 0.20, blue: 0.18, alpha: 1),
                        background: UIColor(red: 0.82, green: 0.79, blue: 0.72, alpha: 1)
                    ),
                    isIncluded: true,
                    allowsSelectionChanges: false
                ))
            }
            if let rawIndex = inventory.firstIndex(where: { $0.id == "raw" }) {
                inventory[rawIndex] = .init(
                    id: "raw",
                    title: "Original capture media",
                    detail: "one reviewed sanitized RGB frame",
                    included: true,
                    reason: "Complete profile with explicit raw consent"
                )
            }
        } else {
            images.removeAll { $0.id == rawID }
            if let rawIndex = inventory.firstIndex(where: { $0.id == "raw" }) {
                inventory[rawIndex] = .init(
                    id: "raw",
                    title: "Original capture media",
                    detail: "not selected",
                    included: false,
                    reason: "AI-ready profile excludes raw media"
                )
            }
        }
    }

    private func updateImage(_ id: String, _ mutate: (inout RoomAIImageReviewItem) -> Void) { guard let index = images.firstIndex(where: { $0.id == id }) else { return }; mutate(&images[index]) }
    private func mutateConcept(_ id: String, _ mutate: (inout RoomAIConceptItem) -> Void) { guard let index = concepts.firstIndex(where: { $0.id == id }) else { return }; var value = concepts[index]; mutate(&value); concepts[index] = value }
    private func appendConcept(name: String, provenance: String) { concepts.append(.init(id: "imported-\(concepts.count + 1)", name: name, provenance: provenance, sourceRevision: "revision-fixture-003", providerDisclosure: nil, mapping: .unmatched, mappingDetail: "Choose a canonical view after inspection.", approved: false, archived: false)) }
    private static func fixtureImage(
        foreground: UIColor,
        background: UIColor
    ) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 640, height: 420)).pngData { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 420))
            foreground.setStroke()
            context.cgContext.setLineWidth(18)
            context.cgContext.stroke(
                CGRect(x: 70, y: 70, width: 500, height: 280)
            )
            foreground.withAlphaComponent(0.18).setFill()
            context.fill(CGRect(x: 120, y: 235, width: 210, height: 80))
            context.fill(CGRect(x: 380, y: 135, width: 130, height: 180))
        }
    }
}

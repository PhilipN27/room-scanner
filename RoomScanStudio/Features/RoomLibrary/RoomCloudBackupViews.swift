import Foundation
import SwiftUI
import RoomScanCore

/// Explicit opt-in backup controls. Opening this view never checks an account,
/// lists records, creates a zone, or uploads a package.
struct RoomCloudBackupSettingsView: View {
    @ObservedObject var coordinator: RoomCloudBackupCoordinator
    let projectID: String?
    let expectedHeadRevisionID: String?
    let privacyPolicyURL: URL?
    @Environment(\.dismiss) private var dismiss

    init(
        coordinator: RoomCloudBackupCoordinator,
        projectID: String? = nil,
        expectedHeadRevisionID: String? = nil,
        privacyPolicyURL: URL? = nil
    ) {
        self.coordinator = coordinator
        self.projectID = projectID
        self.expectedHeadRevisionID = expectedHeadRevisionID
        self.privacyPolicyURL = privacyPolicyURL
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("PRIVATE BACKUP")
                        .font(AppTypography.measurement)
                        .tracking(1.8)
                        .foregroundStyle(AppPalette.blueprint)
                    Text("Manual iCloud recovery")
                        .font(AppTypography.editorial)
                        .foregroundStyle(AppPalette.ink)
                    Text("Backups are immutable full-project snapshots in your private CloudKit database. Local room packages remain authoritative and available offline.")
                        .font(AppTypography.body)
                        .foregroundStyle(AppPalette.mutedInk)

                    privacyPolicy
                    configuration
                    explicitOperations
                    backupRecords
                    if let result = coordinator.lastRecoveryResult {
                        Label(recoveryOutcomeCopy(result), systemImage: "checkmark.seal")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.blueprint)
                            .accessibilityIdentifier("cloudBackup.recoveryOutcome")
                    }
                    if let errorMessage = coordinator.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(AppTypography.measurement)
                            .foregroundStyle(AppPalette.amber)
                            .accessibilityIdentifier("cloudBackup.error")
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .accessibilityIdentifier("cloudBackup.scroll")
            .background(AppPalette.paper.ignoresSafeArea())
            .navigationTitle("Settings & privacy")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task {
                            if coordinator.preparedRecovery != nil {
                                await coordinator.cancelPreparedRecovery()
                                guard coordinator.preparedRecovery == nil else { return }
                            }
                            guard coordinator.state == .idle || coordinator.state == .failed else { return }
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("cloudBackup.close")
                }
            }
        }
        .accessibilityIdentifier("cloudBackup.settings")
        .interactiveDismissDisabled(preventsDismissal)
    }

    @ViewBuilder
    private var privacyPolicy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PRIVACY POLICY")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.blueprint)
            if let privacyPolicyURL {
                Link(destination: privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                        .font(AppTypography.bodyEmphasized)
                }
                .accessibilityLabel("Privacy Policy")
                .accessibilityHint("Opens the operator-supplied Privacy Policy.")
                .accessibilityIdentifier("settings.privacyPolicyLink")
            } else {
                Label("Privacy Policy not configured for this build.", systemImage: "hand.raised.slash")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amber)
                    .accessibilityIdentifier("settings.privacyPolicyNotConfigured")
                Text("Distribution remains blocked until the release owner supplies and approves a policy URL.")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
            }
        }
        .padding(16)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("settings.privacyPolicy")
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "Enable private iCloud backup on this device",
                isOn: Binding(
                    get: { coordinator.preferences.isEnabled },
                    set: { coordinator.setEnabled($0) }
                )
            )
            .tint(AppPalette.blueprint)
            .accessibilityIdentifier("cloudBackup.enable")

            Text("Enable stores only a local preference. It does not contact iCloud.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)

            Text(coordinator.preferences.resolvedContainerIdentifier() ?? "No operator-supplied container is configured for this build.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityIdentifier("cloudBackup.container")

            Text(availabilityCopy)
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
        }
        .padding(16)
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .disabled(coordinator.state != .idle && coordinator.state != .failed && coordinator.state != .cleanupFailed)
    }

    private var explicitOperations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EXPLICIT OPERATIONS")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.blueprint)
            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                Button("Check account") { Task { await coordinator.checkAccount() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cloudBackup.check")
                Button("List backups") { Task { await coordinator.listBackups() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cloudBackup.list")
            }
            if let accountStatus = coordinator.accountStatus {
                Text(accountStatusCopy(accountStatus))
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
                    .accessibilityIdentifier("cloudBackup.accountStatus")
            }
            if let listStatusMessage = coordinator.listStatusMessage {
                Text(listStatusMessage)
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
                    .accessibilityIdentifier("cloudBackup.listStatus")
            }
            if let projectID, let expectedHeadRevisionID {
                Button("Back up this full project") {
                    Task {
                        await coordinator.backUp(
                            projectID: projectID,
                            expectedHeadRevisionID: expectedHeadRevisionID
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.primaryAction)
                .accessibilityIdentifier("cloudBackup.backup")
            }
            Text("No automatic upload, background sync, or simultaneous editing is implemented.")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedInk)
        }
    }

    @ViewBuilder
    private var backupRecords: some View {
        if let preparation = coordinator.preparedRecovery {
            VStack(alignment: .leading, spacing: 10) {
                Text("RECOVERY READY")
                    .font(AppTypography.section)
                Text("The archive passed strict validation in an isolated local stage. Recovery is still an explicit choice.")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
                AdaptiveActionRow(alignment: .leading, spacing: 10) {
                    Button("Recover exact") {
                        Task { await coordinator.commitPreparedRecovery(asCopy: false) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("cloudBackup.recover")
                    Button("Recover as copy") {
                        Task { await coordinator.commitPreparedRecovery(asCopy: true) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cloudBackup.recoverCopy")
                    Button("Cancel") {
                        Task { await coordinator.cancelPreparedRecovery() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("cloudBackup.cancelRecovery")
                }
                Text(preparation.record.descriptor.displayName)
                    .font(AppTypography.measurement)
            }
            .padding(16)
            .background(AppPalette.paperShadow.opacity(0.4), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }

        if coordinator.state == .cleanupFailed {
            Button("Retry workspace cleanup") {
                Task { await coordinator.retryCleanup() }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.amber)
            .accessibilityIdentifier("cloudBackup.retryCleanup")
        } else if coordinator.state == .failed, coordinator.preparedRecovery != nil {
            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                Button("Retry recovery action") {
                    Task { await coordinator.retryPreparedRecoveryAction() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cloudBackup.retryRecovery")
                Button("Choose recovery action") {
                    coordinator.clearError()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cloudBackup.chooseRecoveryAction")
            }
        } else if coordinator.state == .failed {
            Button("Acknowledge error") {
                coordinator.clearError()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("cloudBackup.clearError")
        }

        if coordinator.backupsAreTruncated || coordinator.skippedMalformedBackupRecordCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                if coordinator.backupsAreTruncated {
                    Text("Showing 200 records. Additional records were not loaded; no record was changed.")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedInk)
                        .accessibilityIdentifier("cloudBackup.listTruncated")
                }
                if coordinator.skippedMalformedBackupRecordCount > 0 {
                    Text(malformedRecordCopy)
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.amber)
                        .accessibilityIdentifier("cloudBackup.listMalformed")
                }
            }
        }

        if !coordinator.backups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("PRIVATE BACKUP RECORDS")
                    .font(AppTypography.section)
                ForEach(coordinator.backups) { record in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.descriptor.displayName)
                                .font(AppTypography.bodyEmphasized)
                            Text("HEAD / \(record.descriptor.headRevisionID)")
                                .font(AppTypography.measurement)
                                .foregroundStyle(AppPalette.blueprint)
                            Text(record.descriptor.sourceUpdatedAt, format: .dateTime.year().month().day().hour().minute())
                                .font(AppTypography.measurement)
                                .foregroundStyle(AppPalette.mutedInk)
                        }
                        Spacer()
                        Button("Prepare recovery") {
                            Task { await coordinator.prepareRecovery(record: record) }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("cloudBackup.prepare")
                    }
                    .padding(14)
                    .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private var availabilityCopy: String {
        switch coordinator.availability {
        case .disabled:
            return "Disabled locally. No CloudKit operation can start."
        case .notConfigured:
            return "Enter a resolved, operator-supplied container ID. Build-setting placeholders are rejected."
        case let .ready(identifier):
            return "Ready for explicit operations only: \(identifier)"
        }
    }

    private var preventsDismissal: Bool {
        coordinator.preparedRecovery != nil
            || coordinator.state == .checking
            || coordinator.state == .listing
            || coordinator.state == .backingUp
            || coordinator.state == .preparingRecovery
            || coordinator.state == .recovering
            || coordinator.state == .cleanupFailed
    }

    private func accountStatusCopy(_ status: RoomCloudBackupAccountStatus) -> String {
        switch status {
        case .available: return "Private iCloud account is available for an explicit operation."
        case .noAccount: return "No iCloud account is signed in."
        case .restricted: return "Private iCloud backup is restricted on this device."
        case let .unavailable(message): return message
        }
    }

    private var malformedRecordCopy: String {
        let count = coordinator.skippedMalformedBackupRecordCount
        let noun = count == 1 ? "record" : "records"
        return "Skipped \(count) malformed backup \(noun). They cannot be recovered."
    }

    private func recoveryOutcomeCopy(_ result: RoomBackupRecoveryResult) -> String {
        switch result {
        case let .restored(summary):
            return "Recovered \(summary.customName) as the missing local project."
        case .noOp:
            return "This snapshot already matches the local project. No package changed."
        case let .recoveredCopy(summary):
            return "Recovered a separate local copy named \(summary.customName)."
        }
    }
}

import SwiftUI

struct ProfessionalAccessView: View {
    @ObservedObject var factory: ProfessionalEnvironmentFactory
    @Environment(\.dismiss) private var dismiss
    @State private var authenticationMessage: String?
    @State private var signInMessage: String?
    @State private var email = ""
    @State private var transferCode = ""
    @State private var awaitingTransferCode = false
    @State private var pendingItemMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Professional workspace")
                        .font(AppTypography.section)
                        .foregroundStyle(AppPalette.ink)

#if DEBUG
                    if isPhysicalEvidenceHarness {
                        physicalEvidenceBanner
                    }
#endif
                    content

                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppPalette.paper.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(factory.state == .checkingAvailability)
        .task(id: factory.state) {
            while !Task.isCancelled {
                factory.refreshProtectedState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch factory.state {
        case .notEntered:
            Text("Professional dependencies stay off until you choose to continue.")
                .foregroundStyle(AppPalette.mutedInk)
            Button("Check professional availability") {
                Task { await factory.enterProfessionalWorkspace() }
            }
            .buttonStyle(.borderedProminent)
        case .checkingAvailability:
            ProgressView("Checking professional availability…")
        case let .unavailable(message):
            Label(message, systemImage: "lock.slash")
                .font(AppTypography.bodyEmphasized)
                .foregroundStyle(AppPalette.ink)
            Text("Guest capture, saved rooms, local editing, exports, AI packages, Concept Sets, and Share Sheet preparation remain available.")
                .font(AppTypography.body)
                .foregroundStyle(AppPalette.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        case .available:
            availableContent

            if let authenticationMessage {
                Text(authenticationMessage)
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
            }
            if let signInMessage {
                Text(signInMessage)
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
            }
            if let pendingItemMessage {
                Text(pendingItemMessage)
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedInk)
            }
        }
    }

    @ViewBuilder
    private var availableContent: some View {
#if DEBUG
        if isPhysicalEvidenceHarness {
            physicalEvidenceAvailableContent
        } else {
            standardAvailableContent
        }
#else
        standardAvailableContent
#endif
    }

    @ViewBuilder
    private var standardAvailableContent: some View {
        if factory.isProtectedUIObscured {
            Label(
                "Unlock with Face ID or device passcode to reveal professional content.",
                systemImage: "faceid"
            )
            .font(AppTypography.bodyEmphasized)
            Button("Use Face ID or device passcode") {
                Task {
                    let outcome = await factory.requestLocalUnlock()
                    authenticationMessage = message(for: outcome)
                }
            }
            .buttonStyle(.borderedProminent)
        } else {
            Label("Local unlock confirmed.", systemImage: "lock.open")
                .foregroundStyle(AppPalette.ink)
            if awaitingTransferCode {
                TextField("8-character confirmation code", text: $transferCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("professional.magicLink.code")
                Button("Confirm sign-in") {
                    Task {
                        let result = await factory.redeemMagicLink(
                            transferCode: transferCode
                        )
                        signInMessage = message(for: result)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                TextField("Verified work email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("professional.magicLink.email")
                Button("Email me a sign-in link") {
                    Task {
                        let result = await factory.requestMagicLink(email: email)
                        signInMessage = message(for: result)
                        awaitingTransferCode = result == .requested
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

#if DEBUG
    private var isPhysicalEvidenceHarness: Bool {
        PhysicalProfessionalEvidenceHarness.isEnabledForCurrentBuild(
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    private var physicalEvidenceBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Local synthetic DEBUG evidence — zero network",
                systemImage: "wrench.and.screwdriver"
            )
            .font(AppTypography.bodyEmphasized)
            Text(
                "Synthetic professional state only. Device authentication is local proof, never server identity or server recent authentication."
            )
            .font(AppTypography.measurement)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(AppPalette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier(
            PhysicalProfessionalEvidenceHarness.artifactMarker
        )
    }

    @ViewBuilder
    private var physicalEvidenceAvailableContent: some View {
        if factory.isProtectedUIObscured {
            Label("Protected professional UI is obscured.", systemImage: "lock")
                .font(AppTypography.bodyEmphasized)
        } else {
            Label("Protected professional UI is revealed.", systemImage: "lock.open")
                .font(AppTypography.bodyEmphasized)
        }

        if let snapshot = factory.physicalEvidenceSnapshot {
            physicalEvidenceStateRow(
                "Local proof active",
                value: snapshot.hasValidLocalProof
            )
            physicalEvidenceStateRow(
                "Synthetic session installed",
                value: snapshot.hasSyntheticSessionMaterial
            )
            physicalEvidenceStateRow(
                "Coordinator pending item",
                value: snapshot.hasPendingCompletion
            )
            HStack {
                Text("Last Keychain load")
                Spacer()
                Text(snapshot.lastPendingItemInspectionFound.map {
                    $0 ? "Found" : "Item not found"
                } ?? "Not checked")
            }
            .font(AppTypography.measurement)
        }

        Button("Unlock workspace with Face ID or device passcode") {
            Task {
                let outcome = await factory.requestLocalUnlock()
                authenticationMessage = message(for: outcome)
            }
        }
        .buttonStyle(.borderedProminent)

        Button("Confirm fresh sensitive action") {
            Task {
                let outcome = await factory.requestLocalUnlock(
                    purpose: .sensitiveAction
                )
                authenticationMessage = sensitiveEvidenceMessage(for: outcome)
            }
        }
        .buttonStyle(.bordered)
        .disabled(factory.isProtectedUIObscured)

        Button("Install local synthetic session") {
            Task {
                let result = await factory.beginSignIn()
                signInMessage = result == .started
                    ? "Local synthetic session installed. No server state was created."
                    : message(for: result)
            }
        }
        .buttonStyle(.bordered)
        .disabled(factory.isProtectedUIObscured)

        Divider()
        Text("Protected Keychain pending-item evidence")
            .font(AppTypography.bodyEmphasized)
        Text(
            "The local synthetic redemption code is \(PhysicalProfessionalEvidenceHarness.syntheticTransferCode). It is evidence input, not credential material."
        )
        .font(AppTypography.measurement)
        .fixedSize(horizontal: false, vertical: true)

        Button("Create pending Keychain item") {
            Task {
                let result = await factory.requestMagicLink(
                    email: PhysicalProfessionalEvidenceHarness.syntheticEmail
                )
                pendingItemMessage = result == .requested
                    ? "Synthetic pending item created with user-presence protection."
                    : message(for: result)
            }
        }
        .buttonStyle(.bordered)
        .disabled(factory.isProtectedUIObscured)

        Button("Load pending Keychain item") {
            Task {
                pendingItemMessage = message(
                    for: factory.inspectPhysicalEvidencePendingItem()
                )
            }
        }
        .buttonStyle(.bordered)

        Button("Clear pending Keychain item") {
            pendingItemMessage = message(
                for: factory.clearPhysicalEvidencePendingItem()
            )
        }
        .buttonStyle(.bordered)

        Button("Redeem synthetic code and clear pending item") {
            Task {
                let result = await factory.redeemMagicLink(
                    transferCode:
                        PhysicalProfessionalEvidenceHarness.syntheticTransferCode
                )
                signInMessage = result == .completed
                    ? "Synthetic redemption completed and the pending item was cleared."
                    : message(for: result)
            }
        }
        .buttonStyle(.bordered)
        .disabled(factory.isProtectedUIObscured)
    }

    private func physicalEvidenceStateRow(
        _ label: String,
        value: Bool
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ? "Yes" : "No")
        }
        .font(AppTypography.measurement)
    }

    private func sensitiveEvidenceMessage(
        for outcome: DeviceAuthenticationOutcome
    ) -> String {
        switch outcome {
        case .success(.freshEvaluation):
            "Fresh local device evaluation completed. No server recent-authentication state was created."
        case .success(.recentLocalProof):
            "Sensitive-action evidence did not perform the required fresh evaluation."
        default:
            message(for: outcome)
        }
    }

    private func message(
        for result: PhysicalProfessionalEvidencePendingItemResult
    ) -> String {
        switch result {
        case .found:
            "Pending Keychain item found after user-presence evaluation."
        case .itemNotFound:
            "Pending Keychain item was not found."
        case .cleared:
            "Pending Keychain item cleared."
        case .failed:
            "Keychain operation failed or was cancelled; no value was shown."
        case .unavailable:
            "Local physical evidence diagnostics are unavailable."
        }
    }
#endif

    private func message(for outcome: DeviceAuthenticationOutcome) -> String {
        switch outcome {
        case .success:
            return "Unlocked with Face ID or device passcode."
        case .userCancellation:
            return "Face ID or device passcode was cancelled."
        case .appCancellation, .systemCancellation:
            return "The unlock stopped when the app became inactive. Try again."
        case .authenticationFailed:
            return "Face ID or device passcode did not verify. Try again."
        case .passcodeFallbackRequired:
            return "Continue with the device passcode shown by iOS."
        case .unavailable:
            return "Face ID or device passcode is unavailable on this device."
        case .notEnrolled:
            return "Set up Face ID or use the configured device passcode, then try again."
        case .noPasscode:
            return "Set a device passcode before unlocking professional workspaces. Guest and local workflows remain available."
        case .domainStateChanged:
            return "Local authentication settings changed. Professional material was locked; authenticate again to re-establish local trust."
        }
    }

    private func message(for result: ProfessionalMagicLinkSignInResult) -> String {
        switch result {
        case .requested:
            return "Check your email, then enter the 8-character confirmation code."
        case .completed:
            return "Professional sign-in confirmed."
        case let .unavailable(message), let .failed(message):
            return message
        }
    }

    private func message(for result: ProfessionalSignInResult) -> String {
        switch result {
        case .started:
            return "Professional sign-in started."
        case let .unavailable(message), let .failed(message):
            return message
        }
    }
}

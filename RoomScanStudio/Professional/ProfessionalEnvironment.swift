import Combine
import Foundation

enum ProfessionalAvailability: Equatable, Sendable {
    case enabled
    case disabled(message: String)
}

@MainActor
protocol ProfessionalAvailabilityClient: AnyObject {
    func fetchAvailability() async throws -> ProfessionalAvailability
}

@MainActor
protocol ProfessionalSessionClient: AnyObject {
    /// Produces operation-scoped candidate material without installing it as
    /// the process-wide committed session. Only the factory may commit after
    /// validating the operation ID and lifecycle generation.
    func prepareSignIn(operationID: UUID) async throws -> ProfessionalPreparedSession
    func commitPreparedSession(_ preparedSession: ProfessionalPreparedSession)
    func discardPreparedSession(operationID: UUID)
    func clearCommittedSessionMaterial()
}

/// A configured provider-neutral adapter may turn the locally derived magic
/// completion material into staged app-session material. The coordinator never
/// installs a session itself.
@MainActor
protocol MagicLinkSessionMaterialInstalling: AnyObject {
    func prepareMagicLinkSignIn(
        access: Data,
        refresh: Data,
        operationID: UUID
    ) async throws -> ProfessionalPreparedSession
}

struct ProfessionalPreparedSession: Equatable, Sendable {
    let operationID: UUID
    let plaintextMaterial: Data
    let wrappedMaterial: Data?
}

@MainActor
protocol ProfessionalEntitlementClient: AnyObject {
    func refreshEntitlements() async throws
}

@MainActor
protocol ProfessionalTelemetryClient: AnyObject {
    func recordProfessionalEvent(_ event: String)
}

@MainActor
protocol ProfessionalRemoteConfigurationClient: AnyObject {
    func refreshProfessionalConfiguration() async throws
}

struct ProfessionalLocalConfiguration: Equatable, Sendable {
    fileprivate let permitsProfessionalEntry: Bool

    static let defaultOff = ProfessionalLocalConfiguration(
        permitsProfessionalEntry: false
    )
    static let enabled = ProfessionalLocalConfiguration(
        permitsProfessionalEntry: true
    )
}

enum ProfessionalEntryState: Equatable, Sendable {
    case notEntered
    case checkingAvailability
    case available
    case unavailable(String)
}

enum ProfessionalSignInResult: Equatable, Sendable {
    case started
    case unavailable(String)
    case failed(String)
}

/// Provider-neutral dependencies for the professional surface. A configured
/// builder may create hosted/auth implementations, but the app does not call
/// that builder until the user explicitly enters the professional surface.
@MainActor
final class ProfessionalEnvironment {
    let availabilityClient: any ProfessionalAvailabilityClient
    let sessionClient: any ProfessionalSessionClient
    let deviceAuthentication: DeviceAuthenticationCoordinator
    let entitlementClient: (any ProfessionalEntitlementClient)?
    let telemetryClient: (any ProfessionalTelemetryClient)?
    let remoteConfigurationClient: (any ProfessionalRemoteConfigurationClient)?
    let magicLinkCompletion: MagicLinkCompletionCoordinator?

    init(
        availabilityClient: any ProfessionalAvailabilityClient,
        sessionClient: any ProfessionalSessionClient,
        deviceAuthentication: DeviceAuthenticationCoordinator,
        entitlementClient: (any ProfessionalEntitlementClient)? = nil,
        telemetryClient: (any ProfessionalTelemetryClient)? = nil,
        remoteConfigurationClient: (any ProfessionalRemoteConfigurationClient)? = nil,
        magicLinkCompletion: MagicLinkCompletionCoordinator? = nil
    ) {
        self.availabilityClient = availabilityClient
        self.sessionClient = sessionClient
        self.deviceAuthentication = deviceAuthentication
        self.entitlementClient = entitlementClient
        self.telemetryClient = telemetryClient
        self.remoteConfigurationClient = remoteConfigurationClient
        self.magicLinkCompletion = magicLinkCompletion
    }

    func handleLifecycle(_ event: ProfessionalLifecycleEvent) {
        deviceAuthentication.handleLifecycle(event)
        magicLinkCompletion?.handleLifecycle(event)
    }
}

enum ProfessionalMagicLinkSignInResult: Equatable, Sendable {
    case requested
    case completed
    case unavailable(String)
    case failed(String)
}

/// The guest composition owns only this inert factory. Hosted, entitlement,
/// telemetry, remote-configuration, and authentication dependencies remain
/// absent until `enterProfessionalWorkspace()` follows an explicit user action.
@MainActor
final class ProfessionalEnvironmentFactory: ObservableObject {
    static let locallyUnavailableMessage =
        "Professional workspaces are not configured in this build."

    @Published private(set) var state: ProfessionalEntryState = .notEntered
    @Published private(set) var isProtectedUIObscured = true

    private let localConfiguration: ProfessionalLocalConfiguration
    private let makeEnvironment: (@MainActor () -> ProfessionalEnvironment)?
    private var environment: ProfessionalEnvironment?
    private var lifecycleEpoch: UInt64 = 0
    private var activeSignInID: UUID?
    private var activeSignInTask: Task<ProfessionalPreparedSession, Error>?
    private var activeMagicOperationID: UUID?

    init(
        localConfiguration: ProfessionalLocalConfiguration,
        makeEnvironment: @escaping @MainActor () -> ProfessionalEnvironment
    ) {
        self.localConfiguration = localConfiguration
        self.makeEnvironment = makeEnvironment
    }

    private init(
        localConfiguration: ProfessionalLocalConfiguration,
        makeEnvironment: (@MainActor () -> ProfessionalEnvironment)?
    ) {
        self.localConfiguration = localConfiguration
        self.makeEnvironment = makeEnvironment
    }

    static func defaultOff() -> ProfessionalEnvironmentFactory {
        ProfessionalEnvironmentFactory(
            localConfiguration: .defaultOff,
            makeEnvironment: nil
        )
    }

    var hasConstructedEnvironment: Bool {
        environment != nil
    }

    func enterProfessionalWorkspace() async {
        guard state != .checkingAvailability else { return }
        guard localConfiguration.permitsProfessionalEntry,
              let makeEnvironment
        else {
            state = .unavailable(Self.locallyUnavailableMessage)
            return
        }

        state = .checkingAvailability
        let environment: ProfessionalEnvironment
        if let existing = self.environment {
            environment = existing
        } else {
            let created = makeEnvironment()
            self.environment = created
            environment = created
        }

        do {
            switch try await environment.availabilityClient.fetchAvailability() {
            case .enabled:
                state = .available
            case let .disabled(message):
                state = .unavailable(message)
            }
        } catch {
            state = .unavailable(
                "Professional availability could not be checked. Guest and local rooms remain available."
            )
        }
    }

    func requestLocalUnlock(
        purpose: DeviceAuthenticationPurpose = .workspaceUnlock
    ) async -> DeviceAuthenticationOutcome {
        guard state == .available, let environment else {
            return .unavailable
        }
        switch environment.deviceAuthentication.refreshLocalProof() {
        case .valid, .requiresUnlock:
            break
        case .revoked:
            // Expiry or a backwards clock transition has already invalidated
            // coordinator-owned trust. Revoke the external session and every
            // staged sign-in before a fresh local evaluation can succeed.
            relockProfessionalState(in: environment, advanceEpoch: true)
        }
        let outcome = await environment.deviceAuthentication.authenticate(
            reason: purpose == .sensitiveAction
                ? "Confirm this sensitive action with Face ID or device passcode."
                : "Unlock the professional workspace with Face ID or device passcode.",
            purpose: purpose
        )
        if Self.revokesLocalTrust(outcome) {
            relockProfessionalState(in: environment, advanceEpoch: true)
        } else if case .success = outcome {
            isProtectedUIObscured = environment.deviceAuthentication
                .isProtectedUIObscured
        } else {
            isProtectedUIObscured = true
        }
        return outcome
    }

    /// Re-evaluates the time-bounded local proof and synchronizes the published
    /// view state. Callers use this before revealing or acting on protected UI.
    @discardableResult
    func refreshProtectedState() -> Bool {
        guard case .available = state, let environment else {
            isProtectedUIObscured = true
            return false
        }
        switch environment.deviceAuthentication.refreshLocalProof() {
        case .valid:
            isProtectedUIObscured = environment.deviceAuthentication
                .isProtectedUIObscured
            return true
        case .revoked:
            relockProfessionalState(in: environment, advanceEpoch: true)
            return false
        case .requiresUnlock:
            // The transition that required the unlock has already cleared
            // material. Keep repeated view refreshes idempotent.
            isProtectedUIObscured = true
            return false
        }
    }

    func beginSignIn() async -> ProfessionalSignInResult {
        guard case .available = state, let environment else {
            let message: String
            if case let .unavailable(reason) = state {
                message = reason
            } else {
                message = "Professional access is unavailable."
            }
            return .unavailable(message)
        }
        guard refreshProtectedState() else {
            return .unavailable(
                "Unlock the professional workspace with Face ID or device passcode before signing in."
            )
        }

        guard activeSignInTask == nil else {
            return .failed("Professional sign-in is already in progress.")
        }
        let operationID = UUID()
        let operationEpoch = lifecycleEpoch
        let operation = Task { @MainActor in
            try await environment.sessionClient.prepareSignIn(
                operationID: operationID
            )
        }
        activeSignInID = operationID
        activeSignInTask = operation
        defer {
            if activeSignInID == operationID {
                activeSignInID = nil
                activeSignInTask = nil
            }
        }

        do {
            let preparedSession = try await operation.value
            guard preparedSession.operationID == operationID else {
                environment.sessionClient.discardPreparedSession(
                    operationID: preparedSession.operationID
                )
                environment.sessionClient.discardPreparedSession(
                    operationID: operationID
                )
                return .failed("Professional sign-in returned material for the wrong operation.")
            }
            guard lifecycleEpoch == operationEpoch,
                  activeSignInID == operationID,
                  !operation.isCancelled
            else {
                environment.sessionClient.discardPreparedSession(
                    operationID: operationID
                )
                return .failed(
                    "Professional sign-in was cancelled when the app moved to the background."
                )
            }
            guard refreshProtectedState() else {
                environment.sessionClient.discardPreparedSession(
                    operationID: operationID
                )
                return .unavailable(
                    "Unlock the professional workspace with Face ID or device passcode before signing in."
                )
            }
            environment.sessionClient.commitPreparedSession(preparedSession)
            environment.deviceAuthentication.replaceProfessionalSessionMaterial(
                plaintext: preparedSession.plaintextMaterial,
                wrapped: preparedSession.wrappedMaterial
            )
            return .started
        } catch {
            environment.sessionClient.discardPreparedSession(
                operationID: operationID
            )
            if lifecycleEpoch != operationEpoch || operation.isCancelled {
                return .failed(
                    "Professional sign-in was cancelled when the app moved to the background."
                )
            }
            return .failed("Professional sign-in could not start.")
        }
    }

    func requestMagicLink(email: String) async -> ProfessionalMagicLinkSignInResult {
        guard case .available = state, let environment,
              refreshProtectedState(), let completion = environment.magicLinkCompletion
        else { return .unavailable("Professional magic-link sign-in is unavailable.") }
        do {
            try await completion.request(email: email)
            return .requested
        } catch {
            return .failed("A sign-in link could not be requested. Check the address and try again.")
        }
    }

    func redeemMagicLink(transferCode: String) async -> ProfessionalMagicLinkSignInResult {
        guard case .available = state, let environment,
              refreshProtectedState(), let completion = environment.magicLinkCompletion
        else { return .unavailable("Professional magic-link sign-in is unavailable.") }
        guard let installer = environment.sessionClient as? any MagicLinkSessionMaterialInstalling else {
            return .unavailable("Professional magic-link sign-in is unavailable.")
        }
        let operationID = UUID()
        let operationEpoch = lifecycleEpoch
        activeMagicOperationID = operationID
        defer {
            if activeMagicOperationID == operationID { activeMagicOperationID = nil }
        }
        do {
            guard case let .session(access, refresh) = try await completion.redeem(
                transferCode: transferCode,
                expectedPurpose: .signIn
            ) else { return .failed("Professional sign-in could not be confirmed.") }
            let prepared = try await installer.prepareMagicLinkSignIn(
                access: access,
                refresh: refresh,
                operationID: operationID
            )
            guard prepared.operationID == operationID,
                  activeMagicOperationID == operationID,
                  lifecycleEpoch == operationEpoch,
                  refreshProtectedState()
            else {
                environment.sessionClient.discardPreparedSession(operationID: prepared.operationID)
                return .failed("Professional sign-in could not be confirmed.")
            }
            environment.sessionClient.commitPreparedSession(prepared)
            environment.deviceAuthentication.replaceProfessionalSessionMaterial(
                plaintext: prepared.plaintextMaterial,
                wrapped: prepared.wrappedMaterial
            )
            do {
                try completion.acknowledgeCommittedCompletion()
            } catch {
                relockProfessionalState(in: environment, advanceEpoch: true)
                return .failed("Professional sign-in could not be confirmed.")
            }
            return .completed
        } catch MagicLinkCompletionError.expired {
            return .failed("That sign-in link has expired. Request a new one.")
        } catch {
            return .failed("That code could not be confirmed. Try again or request a new link.")
        }
    }

    func handleLifecycle(_ event: ProfessionalLifecycleEvent) {
        switch event {
        case .inactive:
            // Forwarding to an existing environment never constructs one.
            environment?.handleLifecycle(event)
            isProtectedUIObscured = true
        case .background:
            if let environment {
                relockProfessionalState(in: environment, advanceEpoch: true)
                environment.handleLifecycle(event)
            } else {
                invalidateActiveSignIn(in: nil, advanceEpoch: true)
            }
            isProtectedUIObscured = true
        case .foreground:
            environment?.handleLifecycle(event)
            isProtectedUIObscured = true
        }
    }

    private func relockProfessionalState(
        in environment: ProfessionalEnvironment,
        advanceEpoch: Bool
    ) {
        invalidateActiveSignIn(in: environment, advanceEpoch: advanceEpoch)
        environment.sessionClient.clearCommittedSessionMaterial()
        environment.deviceAuthentication.clearProfessionalMaterialAndRequireUnlock()
        isProtectedUIObscured = true
    }

    private func invalidateActiveSignIn(
        in environment: ProfessionalEnvironment?,
        advanceEpoch: Bool
    ) {
        if advanceEpoch {
            lifecycleEpoch &+= 1
        }
        if let activeSignInID, let environment {
            environment.sessionClient.discardPreparedSession(
                operationID: activeSignInID
            )
        }
        self.activeSignInID = nil
        activeSignInTask?.cancel()
        activeSignInTask = nil
        activeMagicOperationID = nil
    }

    private static func revokesLocalTrust(
        _ outcome: DeviceAuthenticationOutcome
    ) -> Bool {
        switch outcome {
        case .noPasscode, .notEnrolled, .unavailable, .domainStateChanged:
            true
        case .success,
             .userCancellation,
             .appCancellation,
             .systemCancellation,
             .authenticationFailed,
             .passcodeFallbackRequired:
            false
        }
    }
}

#if DEBUG
extension ProfessionalEnvironmentFactory {
    var physicalEvidenceSnapshot: PhysicalProfessionalEvidenceSnapshot? {
        physicalEvidenceDiagnostics?.physicalEvidenceSnapshot
    }

    var physicalEvidenceExternalDependencyCount: Int? {
        guard physicalEvidenceDiagnostics != nil, let environment else {
            return nil
        }
        return [
            environment.entitlementClient != nil,
            environment.telemetryClient != nil,
            environment.remoteConfigurationClient != nil,
        ].filter { $0 }.count
    }

    func inspectPhysicalEvidencePendingItem()
        -> PhysicalProfessionalEvidencePendingItemResult
    {
        physicalEvidenceDiagnostics?.inspectPendingItem() ?? .unavailable
    }

    func clearPhysicalEvidencePendingItem()
        -> PhysicalProfessionalEvidencePendingItemResult
    {
        physicalEvidenceDiagnostics?.clearPendingItem() ?? .unavailable
    }

    private var physicalEvidenceDiagnostics:
        (any PhysicalProfessionalEvidenceDiagnosing)?
    {
        environment?.sessionClient
            as? any PhysicalProfessionalEvidenceDiagnosing
    }
}
#endif

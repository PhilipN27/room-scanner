#if DEBUG
import Foundation

enum PhysicalProfessionalEvidencePendingItemResult: Equatable {
    case found
    case itemNotFound
    case cleared
    case failed
    case unavailable
}

/// Boolean-only evidence exposed to the DEBUG view. Credential material and
/// LocalAuthentication domain-state bytes never cross this boundary.
struct PhysicalProfessionalEvidenceSnapshot: Equatable {
    let isProtectedUIObscured: Bool
    let hasValidLocalProof: Bool
    let hasSyntheticSessionMaterial: Bool
    let hasPendingCompletion: Bool
    let lastPendingItemInspectionFound: Bool?
}

@MainActor
protocol PhysicalProfessionalEvidenceDiagnosing: AnyObject {
    var physicalEvidenceSnapshot: PhysicalProfessionalEvidenceSnapshot { get }
    func inspectPendingItem() -> PhysicalProfessionalEvidencePendingItemResult
    func clearPendingItem() -> PhysicalProfessionalEvidencePendingItemResult
}

/// A DEBUG-only, physical-device-only composition for executing the retained
/// Face ID/passcode and Keychain protocol with local synthetic data. The type
/// accepts no transport, provider, account, room, or server-auth dependency.
@MainActor
enum PhysicalProfessionalEvidenceHarness {
    static let artifactMarker =
        "ROOMSCAN_PHYSICAL_PROFESSIONAL_EVIDENCE_LOCAL_SYNTHETIC_ZERO_NETWORK"
    static let launchArgument = "--physical-professional-evidence"
    static let syntheticEmail = "synthetic-professional@example.invalid"
    static let syntheticTransferCode = "TEST1234"

    struct Dependencies {
        let makeAuthenticationContextFactory:
            @MainActor () -> any DeviceAuthenticationContextFactory
        let makeTransientStateStore:
            @MainActor () -> any MagicLinkTransientStateStore
        let randomBytes: (Int) throws -> Data

        static var live: Dependencies {
            Dependencies(
                makeAuthenticationContextFactory: {
                    AppleDeviceAuthenticationContextFactory()
                },
                makeTransientStateStore: {
                    KeychainMagicLinkTransientStateStore(
                        policy: ProfessionalKeychainAccessPolicy()
                    )
                },
                randomBytes: ProfessionalMagicLinkSecureRandom.bytes(count:)
            )
        }
    }

    static func isEnabled(
        arguments: [String],
        isDebugBuild: Bool,
        isPhysicalDevice: Bool
    ) -> Bool {
        isDebugBuild
            && isPhysicalDevice
            && arguments.contains("--ui-testing")
            && arguments.contains(launchArgument)
    }

    static func isEnabledForCurrentBuild(arguments: [String]) -> Bool {
        isEnabled(
            arguments: arguments,
            isDebugBuild: true,
            isPhysicalDevice: currentBuildIsPhysicalDevice
        )
    }

    static func factoryForCurrentBuild(
        arguments: [String]
    ) -> ProfessionalEnvironmentFactory {
        factory(
            arguments: arguments,
            isDebugBuild: true,
            isPhysicalDevice: currentBuildIsPhysicalDevice,
            dependencies: .live
        )
    }

    static func factory(
        arguments: [String],
        isDebugBuild: Bool,
        isPhysicalDevice: Bool,
        dependencies: Dependencies = .live
    ) -> ProfessionalEnvironmentFactory {
        guard isEnabled(
            arguments: arguments,
            isDebugBuild: isDebugBuild,
            isPhysicalDevice: isPhysicalDevice
        ) else {
            return .defaultOff()
        }

        return ProfessionalEnvironmentFactory(
            localConfiguration: .enabled,
            makeEnvironment: {
                let authentication = DeviceAuthenticationCoordinator(
                    contextFactory: dependencies.makeAuthenticationContextFactory(),
                    maximumLocalProofAge: 300
                )
                let store = dependencies.makeTransientStateStore()
                let localMagicClient = PhysicalProfessionalEvidenceMagicClient(
                    randomBytes: dependencies.randomBytes
                )
                let completion = MagicLinkCompletionCoordinator(
                    client: localMagicClient,
                    store: store,
                    randomBytes: dependencies.randomBytes
                )
                let session = PhysicalProfessionalEvidenceSessionClient(
                    authentication: authentication,
                    completion: completion,
                    store: store,
                    randomBytes: dependencies.randomBytes
                )
                return ProfessionalEnvironment(
                    availabilityClient: PhysicalProfessionalEvidenceAvailabilityClient(),
                    sessionClient: session,
                    deviceAuthentication: authentication,
                    magicLinkCompletion: completion
                )
            }
        )
    }

    private static var currentBuildIsPhysicalDevice: Bool {
#if targetEnvironment(simulator)
        false
#else
        true
#endif
    }
}

@MainActor
private final class PhysicalProfessionalEvidenceAvailabilityClient:
    ProfessionalAvailabilityClient
{
    func fetchAvailability() async throws -> ProfessionalAvailability {
        .enabled
    }
}

@MainActor
private final class PhysicalProfessionalEvidenceMagicClient:
    MagicLinkCompletionClient
{
    private struct PendingCompletion {
        let completionIDBase64URL: String
        let purpose: MagicLinkCompletionPurpose
        let expiresAt: Date
    }

    private let randomBytes: (Int) throws -> Data
    private var pending: PendingCompletion?

    init(randomBytes: @escaping (Int) throws -> Data) {
        self.randomBytes = randomBytes
    }

    func requestCompletion(
        _ request: MagicLinkCompletionRequest
    ) async throws -> MagicLinkCompletionResponse {
        guard request.email == PhysicalProfessionalEvidenceHarness.syntheticEmail,
              request.pkceChallenge.count == 43
        else {
            throw MagicLinkCompletionError.invalidPendingState
        }
        let completionID = try randomBytes(32)
        guard completionID.count == 32 else {
            throw MagicLinkCompletionError.randomnessFailure
        }
        let response = MagicLinkCompletionResponse(
            completionID: completionID,
            expiresAt: Date().addingTimeInterval(600)
        )
        pending = PendingCompletion(
            completionIDBase64URL: response.completionIDBase64URL,
            purpose: request.purpose,
            expiresAt: response.expiresAt
        )
        return response
    }

    func redeemCompletion(
        _ request: MagicLinkRedemptionRequest
    ) async throws -> MagicLinkRedemptionResponse {
        guard let pending,
              pending.expiresAt > Date(),
              request.completionIDBase64URL == pending.completionIDBase64URL,
              request.purpose == pending.purpose,
              request.verifier.count == 32,
              request.transferCode
                == PhysicalProfessionalEvidenceHarness.syntheticTransferCode
        else {
            throw MagicLinkCompletionError.invalidPendingState
        }
        return MagicLinkRedemptionResponse(
            purpose: pending.purpose,
            expiresAt: pending.expiresAt,
            consumed: true
        )
    }
}

@MainActor
private final class PhysicalProfessionalEvidenceSessionClient:
    ProfessionalSessionClient,
    MagicLinkSessionMaterialInstalling,
    PhysicalProfessionalEvidenceDiagnosing
{
    private let authentication: DeviceAuthenticationCoordinator
    private let completion: MagicLinkCompletionCoordinator
    private let store: any MagicLinkTransientStateStore
    private let randomBytes: (Int) throws -> Data
    private var staged: [UUID: ProfessionalPreparedSession] = [:]
    private var committedPlaintextMaterial: Data?
    private var committedWrappedMaterial: Data?
    private var lastPendingItemInspectionFound: Bool?

    init(
        authentication: DeviceAuthenticationCoordinator,
        completion: MagicLinkCompletionCoordinator,
        store: any MagicLinkTransientStateStore,
        randomBytes: @escaping (Int) throws -> Data
    ) {
        self.authentication = authentication
        self.completion = completion
        self.store = store
        self.randomBytes = randomBytes
    }

    var physicalEvidenceSnapshot: PhysicalProfessionalEvidenceSnapshot {
        PhysicalProfessionalEvidenceSnapshot(
            isProtectedUIObscured: authentication.isProtectedUIObscured,
            hasValidLocalProof: !authentication.requiresLocalUnlock,
            hasSyntheticSessionMaterial:
                committedPlaintextMaterial != nil
                    || committedWrappedMaterial != nil,
            hasPendingCompletion: completion.hasPendingCompletion,
            lastPendingItemInspectionFound: lastPendingItemInspectionFound
        )
    }

    func prepareSignIn(
        operationID: UUID
    ) async throws -> ProfessionalPreparedSession {
        try stageSyntheticSession(operationID: operationID)
    }

    func prepareMagicLinkSignIn(
        access: Data,
        refresh: Data,
        operationID: UUID
    ) async throws -> ProfessionalPreparedSession {
        guard access.count == 32, refresh.count == 32 else {
            throw MagicLinkCompletionError.invalidPendingState
        }
        return try stageSyntheticSession(operationID: operationID)
    }

    func commitPreparedSession(_ preparedSession: ProfessionalPreparedSession) {
        guard staged.removeValue(forKey: preparedSession.operationID)
            == preparedSession
        else { return }
        committedPlaintextMaterial = preparedSession.plaintextMaterial
        committedWrappedMaterial = preparedSession.wrappedMaterial
    }

    func discardPreparedSession(operationID: UUID) {
        staged.removeValue(forKey: operationID)
    }

    func clearCommittedSessionMaterial() {
        staged.removeAll()
        committedPlaintextMaterial = nil
        committedWrappedMaterial = nil
    }

    func inspectPendingItem() -> PhysicalProfessionalEvidencePendingItemResult {
        do {
            let found = try store.load() != nil
            lastPendingItemInspectionFound = found
            return found ? .found : .itemNotFound
        } catch {
            return .failed
        }
    }

    func clearPendingItem() -> PhysicalProfessionalEvidencePendingItemResult {
        completion.cancel()
        guard !completion.hasPendingCompletion else { return .failed }
        lastPendingItemInspectionFound = false
        return .cleared
    }

    private func stageSyntheticSession(
        operationID: UUID
    ) throws -> ProfessionalPreparedSession {
        let plaintext = try randomBytes(32)
        let wrapped = try randomBytes(32)
        guard plaintext.count == 32, wrapped.count == 32 else {
            throw MagicLinkCompletionError.randomnessFailure
        }
        let prepared = ProfessionalPreparedSession(
            operationID: operationID,
            plaintextMaterial: plaintext,
            wrappedMaterial: wrapped
        )
        staged[operationID] = prepared
        return prepared
    }
}
#endif

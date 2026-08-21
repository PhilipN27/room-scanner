import CryptoKit
import Foundation

/// Provider-neutral request issued only after an explicit professional entry.
/// The email is never persisted or logged by this client-side foundation.
struct MagicLinkCompletionRequest: Equatable, Sendable {
    let email: String
    let purpose: MagicLinkCompletionPurpose
    let pkceChallenge: String

    init(
        email: String,
        purpose: MagicLinkCompletionPurpose = .signIn,
        verifier: Data
    ) throws {
        guard verifier.count == 32 else { throw MagicLinkCompletionError.invalidVerifier }
        self.email = email
        self.purpose = purpose
        pkceChallenge = Data(SHA256.hash(data: verifier)).base64URLEncodedString()
    }
}

enum MagicLinkCompletionPurpose: String, Equatable, Sendable, Codable {
    case signIn = "sign-in"
    case reauthenticate = "reauthenticate"
    case linkIdentity = "link-identity"
    case unlinkIdentity = "unlink-identity"
}

struct MagicLinkCompletionResponse: Equatable, Sendable {
    let completionIDBase64URL: String
    let expiresAt: Date

    init(completionID: Data, expiresAt: Date) {
        completionIDBase64URL = completionID.base64URLEncodedString()
        self.expiresAt = expiresAt
    }

    var completionID: Data? { Data(base64URLEncoded: completionIDBase64URL) }
}

struct MagicLinkTransferCode: Equatable, Sendable {
    static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    let canonical: String

    init(normalizing input: String) throws {
        let normalized = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard normalized.count == 8,
              normalized.allSatisfy({ Self.alphabet.contains($0) })
        else { throw MagicLinkCompletionError.invalidTransferCode }
        canonical = normalized
    }
}

struct MagicLinkRedemptionRequest: Equatable, Sendable {
    let completionIDBase64URL: String
    let verifier: Data
    let transferCode: String
    let purpose: MagicLinkCompletionPurpose
}

struct MagicLinkRedemptionResponse: Equatable, Sendable {
    let purpose: MagicLinkCompletionPurpose
    let expiresAt: Date
    let consumed: Bool
}

enum MagicLinkCompletionResult: Equatable, Sendable {
    case session(access: Data, refresh: Data)
    case receipt(Data)
}

enum MagicLinkCompletionDerivation {
    static func access(verifier: Data, completionID: Data) throws -> Data { try deriveOne(verifier: verifier, completionID: completionID, label: "access") }
    static func refresh(verifier: Data, completionID: Data) throws -> Data { try deriveOne(verifier: verifier, completionID: completionID, label: "refresh") }
    static func receipt(verifier: Data, completionID: Data) throws -> Data { try deriveOne(verifier: verifier, completionID: completionID, label: "receipt") }

    private static func deriveOne(verifier: Data, completionID: Data, label: String) throws -> Data {
        guard verifier.count == 32, completionID.count == 32 else { throw MagicLinkCompletionError.invalidPendingState }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: verifier),
            salt: completionID,
            info: Data("roomscan.slice4.magic-completion.v3/\(label)".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

enum MagicLinkCompletionError: Error, Equatable, Sendable {
    case invalidVerifier
    case invalidTransferCode
    case invalidPendingState
    case expired
    case storageFailure
    case randomnessFailure
}

protocol MagicLinkCompletionClient: AnyObject {
    func requestCompletion(_ request: MagicLinkCompletionRequest) async throws -> MagicLinkCompletionResponse
    func redeemCompletion(_ request: MagicLinkRedemptionRequest) async throws -> MagicLinkRedemptionResponse
}

struct MagicLinkPendingState: Equatable, Sendable, Codable {
    let completionID: Data
    let verifier: Data
    let expiresAt: Date
    let purpose: MagicLinkCompletionPurpose
}

protocol MagicLinkTransientStateStore: AnyObject {
    func save(_ state: MagicLinkPendingState) throws
    func load() throws -> MagicLinkPendingState?
    func clear() throws
}

@MainActor
final class MagicLinkCompletionCoordinator: ObservableObject {
    @Published private(set) var hasPendingCompletion = false
    private let client: any MagicLinkCompletionClient
    private let store: any MagicLinkTransientStateStore
    private let randomBytes: (Int) throws -> Data
    private let now: () -> Date

    // Test-only diagnostic surface deliberately proves no verifier remains in
    // coordinator memory between actions. Do not replace with a logger.
    var pendingPlaintextVerifierForDiagnostics: Data? { nil }

    init(
        client: any MagicLinkCompletionClient,
        store: any MagicLinkTransientStateStore,
        randomBytes: @escaping (Int) throws -> Data,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.store = store
        self.randomBytes = randomBytes
        self.now = now
    }

    func request(email: String, purpose: MagicLinkCompletionPurpose = .signIn) async throws {
        let verifier = try randomBytes(32)
        let request = try MagicLinkCompletionRequest(email: email, purpose: purpose, verifier: verifier)
        let response = try await client.requestCompletion(request)
        guard let completionID = response.completionID, completionID.count == 32,
              response.completionIDBase64URL == completionID.base64URLEncodedString(),
              response.expiresAt > now() else {
            throw MagicLinkCompletionError.invalidPendingState
        }
        do {
            try store.save(MagicLinkPendingState(
                completionID: completionID,
                verifier: verifier,
                expiresAt: response.expiresAt,
                purpose: purpose
            ))
            hasPendingCompletion = true
        } catch { throw MagicLinkCompletionError.storageFailure }
    }

    func redeem(
        transferCode: String,
        expectedPurpose: MagicLinkCompletionPurpose = .signIn
    ) async throws -> MagicLinkCompletionResult {
        let pending: MagicLinkPendingState
        do {
            guard let loaded = try store.load() else { throw MagicLinkCompletionError.invalidPendingState }
            pending = loaded
        } catch let error as MagicLinkCompletionError { throw error }
        catch { throw MagicLinkCompletionError.storageFailure }
        guard pending.completionID.count == 32, pending.verifier.count == 32,
              pending.purpose == expectedPurpose else {
            try clearPending()
            throw MagicLinkCompletionError.invalidPendingState
        }
        guard pending.expiresAt > now() else {
            try clearPending()
            throw MagicLinkCompletionError.expired
        }
        let code = try MagicLinkTransferCode(normalizing: transferCode)
        let response = try await client.redeemCompletion(MagicLinkRedemptionRequest(
            completionIDBase64URL: pending.completionID.base64URLEncodedString(),
            verifier: pending.verifier,
            transferCode: code.canonical,
            purpose: pending.purpose
        ))
        guard response.consumed, response.purpose == pending.purpose,
              response.expiresAt > now() else { throw MagicLinkCompletionError.invalidPendingState }
        switch pending.purpose {
        case .signIn, .reauthenticate:
            return .session(
                access: try MagicLinkCompletionDerivation.access(verifier: pending.verifier, completionID: pending.completionID),
                refresh: try MagicLinkCompletionDerivation.refresh(verifier: pending.verifier, completionID: pending.completionID)
            )
        case .linkIdentity, .unlinkIdentity:
            return .receipt(try MagicLinkCompletionDerivation.receipt(verifier: pending.verifier, completionID: pending.completionID))
        }
    }

    /// The factory acknowledges only after it has committed the corresponding
    /// staged app session. Until then the protected verifier remains available
    /// for an idempotent lost-response retry.
    func acknowledgeCommittedCompletion() throws {
        try clearPending()
    }

    func cancel() {
        do { try clearPending() }
        catch { hasPendingCompletion = true }
    }

    func handleLifecycle(_ event: ProfessionalLifecycleEvent) {
        // The protected store survives a background transition, but no
        // Keychain lookup occurs here: lifecycle handling must never trigger
        // authentication UI or materialize the verifier in memory.
        if event == .background { return }
    }

    private func clearPending() throws {
        do {
            try store.clear()
            hasPendingCompletion = false
        } catch {
            hasPendingCompletion = true
            throw MagicLinkCompletionError.storageFailure
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Data {
    init?(base64URLEncoded source: String) {
        guard source.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { return nil }
        var padded = source.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded.append("=")
        self.init(base64Encoded: padded)
    }
}

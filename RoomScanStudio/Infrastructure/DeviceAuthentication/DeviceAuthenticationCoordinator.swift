import Combine
import Foundation

enum DeviceAuthenticationFailure: Equatable, Sendable {
    case userCancellation
    case appCancellation
    case systemCancellation
    case authenticationFailed
    case passcodeFallbackRequired
    case unavailable
    case notEnrolled
    case noPasscode
}

enum DeviceAuthenticationPreflight: Equatable, Sendable {
    case available
    case failure(DeviceAuthenticationFailure)
}

enum DeviceAuthenticationEvaluation: Equatable, Sendable {
    case success
    case failure(DeviceAuthenticationFailure)
}

protocol DeviceAuthenticationContext: AnyObject, Sendable {
    var evaluatedDomainState: Data? { get }
    func preflight() -> DeviceAuthenticationPreflight
    func evaluate(
        reason: String,
        completion: @escaping @Sendable (DeviceAuthenticationEvaluation) -> Void
    )
    func invalidate()
}

protocol DeviceAuthenticationContextFactory: Sendable {
    func makeContext() -> any DeviceAuthenticationContext
}

enum DeviceAuthenticationPurpose: Equatable, Sendable {
    case workspaceUnlock
    case sensitiveAction
}

enum DeviceAuthenticationSuccessEvidence: Equatable, Sendable {
    case freshEvaluation
    case recentLocalProof
}

enum DeviceAuthenticationLocalProofRevocation: Equatable, Sendable {
    case expired
    case clockMovedBackward
}

enum DeviceAuthenticationLocalProofRefresh: Equatable, Sendable {
    case valid
    case requiresUnlock
    case revoked(DeviceAuthenticationLocalProofRevocation)
}

enum DeviceAuthenticationOutcome: Equatable, Sendable {
    case success(DeviceAuthenticationSuccessEvidence)
    case userCancellation
    case appCancellation
    case systemCancellation
    case authenticationFailed
    case passcodeFallbackRequired
    case unavailable
    case notEnrolled
    case noPasscode
    case domainStateChanged
}

enum ProfessionalLifecycleEvent: Equatable, Sendable {
    case inactive
    case background
    case foreground
}

/// Main-actor owner of local device authentication and professional plaintext
/// lifetime. Domain-state bytes never leave this object, are not logged or
/// serialized, and are used only to invalidate local trust/wrapped material.
@MainActor
final class DeviceAuthenticationCoordinator: ObservableObject {
    private struct PendingAttempt {
        let id: UUID
        let context: any DeviceAuthenticationContext
        let purpose: DeviceAuthenticationPurpose
        let continuation: CheckedContinuation<DeviceAuthenticationOutcome, Never>
    }

    private enum ObservedDomainState {
        case unobserved
        case observed(Data?)
    }

    @Published private(set) var isProtectedUIObscured = true
    @Published private(set) var requiresLocalUnlock = true
    @Published private(set) var lastOutcome: DeviceAuthenticationOutcome?

    private let contextFactory: any DeviceAuthenticationContextFactory
    private let now: @Sendable () -> Date
    private let maximumLocalProofAge: TimeInterval
    private var currentContext: (any DeviceAuthenticationContext)?
    private var pendingAttempt: PendingAttempt?
    private var lastUnlockDate: Date?
    private var observedDomainState: ObservedDomainState = .unobserved
    private var plaintextProfessionalSessionMaterial: Data?
    private var wrappedProfessionalMaterial: Data?

    init(
        contextFactory: any DeviceAuthenticationContextFactory,
        now: @escaping @Sendable () -> Date = { Date() },
        maximumLocalProofAge: TimeInterval = 300
    ) {
        self.contextFactory = contextFactory
        self.now = now
        self.maximumLocalProofAge = min(max(maximumLocalProofAge, 0), 300)
    }

    var hasPlaintextProfessionalSessionMaterial: Bool {
        plaintextProfessionalSessionMaterial != nil
    }

    var hasWrappedProfessionalMaterial: Bool {
        wrappedProfessionalMaterial != nil
    }

    @discardableResult
    func refreshLocalProof(
        at date: Date? = nil
    ) -> DeviceAuthenticationLocalProofRefresh {
        guard !requiresLocalUnlock, let lastUnlockDate else {
            return .requiresUnlock
        }
        let age = (date ?? now()).timeIntervalSince(lastUnlockDate)
        guard age >= 0 else {
            invalidateLocalTrust()
            return .revoked(.clockMovedBackward)
        }
        guard age <= maximumLocalProofAge else {
            invalidateLocalTrust()
            return .revoked(.expired)
        }
        return .valid
    }

    func hasValidLocalProof(at date: Date? = nil) -> Bool {
        refreshLocalProof(at: date) == .valid
    }

    func authenticate(
        reason: String,
        purpose: DeviceAuthenticationPurpose
    ) async -> DeviceAuthenticationOutcome {
        if purpose == .workspaceUnlock, refreshLocalProof() == .valid {
            return publish(.success(.recentLocalProof))
        }

        cancelPendingEvaluation(outcome: .appCancellation)
        currentContext?.invalidate()

        let context = contextFactory.makeContext()
        currentContext = context
        switch context.preflight() {
        case .available:
            break
        case let .failure(failure):
            let outcome = Self.outcome(for: failure)
            if Self.revokesLocalTrust(failure) {
                invalidateLocalTrust()
            }
            currentContext?.invalidate()
            currentContext = nil
            return publish(outcome)
        }

        return await withCheckedContinuation { continuation in
            let attemptID = UUID()
            pendingAttempt = PendingAttempt(
                id: attemptID,
                context: context,
                purpose: purpose,
                continuation: continuation
            )
            context.evaluate(reason: reason) { [weak self] evaluation in
                Task { @MainActor in
                    self?.completeEvaluation(
                        attemptID: attemptID,
                        evaluation: evaluation
                    )
                }
            }
        }
    }

    func recordPlaintextProfessionalSessionMaterial(_ material: Data) {
        plaintextProfessionalSessionMaterial = material
    }

    func recordWrappedProfessionalMaterial(_ material: Data) {
        wrappedProfessionalMaterial = material
    }

    func replaceProfessionalSessionMaterial(
        plaintext: Data,
        wrapped: Data?
    ) {
        plaintextProfessionalSessionMaterial = plaintext
        wrappedProfessionalMaterial = wrapped
    }

    func handleLifecycle(_ event: ProfessionalLifecycleEvent) {
        switch event {
        case .inactive:
            isProtectedUIObscured = true
            cancelPendingEvaluation(outcome: .appCancellation)
            currentContext?.invalidate()
            currentContext = nil
        case .background:
            invalidateLocalTrust()
            cancelPendingEvaluation(outcome: .appCancellation)
            currentContext?.invalidate()
            currentContext = nil
        case .foreground:
            isProtectedUIObscured = true
            requiresLocalUnlock = true
        }
    }

    private func completeEvaluation(
        attemptID: UUID,
        evaluation: DeviceAuthenticationEvaluation
    ) {
        guard let attempt = pendingAttempt, attempt.id == attemptID else {
            return
        }
        pendingAttempt = nil

        let outcome: DeviceAuthenticationOutcome
        switch evaluation {
        case .success:
            outcome = successfulEvaluation(
                domainState: attempt.context.evaluatedDomainState,
                purpose: attempt.purpose
            )
        case let .failure(failure):
            outcome = Self.outcome(for: failure)
            if Self.revokesLocalTrust(failure) {
                invalidateLocalTrust()
            } else {
                isProtectedUIObscured = true
            }
        }
        attempt.continuation.resume(returning: publish(outcome))
    }

    private func successfulEvaluation(
        domainState: Data?,
        purpose: DeviceAuthenticationPurpose
    ) -> DeviceAuthenticationOutcome {
        switch observedDomainState {
        case .unobserved:
            observedDomainState = .observed(domainState)
        case let .observed(previous) where previous != domainState:
            observedDomainState = .observed(domainState)
            invalidateLocalTrust()
            return .domainStateChanged
        case .observed:
            break
        }

        if purpose == .workspaceUnlock {
            lastUnlockDate = now()
            requiresLocalUnlock = false
            isProtectedUIObscured = false
        }
        return .success(.freshEvaluation)
    }

    private func invalidateLocalTrust() {
        lastUnlockDate = nil
        requiresLocalUnlock = true
        isProtectedUIObscured = true
        plaintextProfessionalSessionMaterial = nil
        wrappedProfessionalMaterial = nil
    }

    func clearProfessionalMaterialAndRequireUnlock() {
        invalidateLocalTrust()
    }

    private func cancelPendingEvaluation(outcome: DeviceAuthenticationOutcome) {
        guard let pendingAttempt else { return }
        self.pendingAttempt = nil
        pendingAttempt.context.invalidate()
        pendingAttempt.continuation.resume(returning: publish(outcome))
    }

    @discardableResult
    private func publish(_ outcome: DeviceAuthenticationOutcome) -> DeviceAuthenticationOutcome {
        lastOutcome = outcome
        return outcome
    }

    private static func outcome(
        for failure: DeviceAuthenticationFailure
    ) -> DeviceAuthenticationOutcome {
        switch failure {
        case .userCancellation: .userCancellation
        case .appCancellation: .appCancellation
        case .systemCancellation: .systemCancellation
        case .authenticationFailed: .authenticationFailed
        case .passcodeFallbackRequired: .passcodeFallbackRequired
        case .unavailable: .unavailable
        case .notEnrolled: .notEnrolled
        case .noPasscode: .noPasscode
        }
    }

    private static func revokesLocalTrust(
        _ failure: DeviceAuthenticationFailure
    ) -> Bool {
        switch failure {
        case .noPasscode, .notEnrolled, .unavailable:
            true
        case .userCancellation,
             .appCancellation,
             .systemCancellation,
             .authenticationFailed,
             .passcodeFallbackRequired:
            false
        }
    }
}

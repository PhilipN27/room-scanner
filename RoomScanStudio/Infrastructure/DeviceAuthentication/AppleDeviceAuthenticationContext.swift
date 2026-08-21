import Foundation
import LocalAuthentication

enum AppleDeviceAuthenticationErrorMapper {
    static func failure(from error: Error?) -> DeviceAuthenticationFailure {
        guard let nsError = error as NSError?,
              nsError.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: nsError.code)
        else {
            return .authenticationFailed
        }
        switch code {
        case .userCancel:
            return .userCancellation
        case .appCancel:
            return .appCancellation
        case .systemCancel:
            return .systemCancellation
        case .authenticationFailed:
            return .authenticationFailed
        case .userFallback, .biometryLockout:
            return .passcodeFallbackRequired
        case .biometryNotAvailable:
            return .unavailable
        case .biometryNotEnrolled:
            return .notEnrolled
        case .passcodeNotSet:
            return .noPasscode
        default:
            return .unavailable
        }
    }
}

final class AppleDeviceAuthenticationContextFactory:
    DeviceAuthenticationContextFactory,
    @unchecked Sendable
{
    func makeContext() -> any DeviceAuthenticationContext {
        // A new LAContext is created for every attempt; contexts are never
        // reused across workspace unlocks or sensitive confirmations.
        AppleDeviceAuthenticationContext(context: LAContext())
    }
}

private final class AppleDeviceAuthenticationContext:
    DeviceAuthenticationContext,
    @unchecked Sendable
{
    private let context: LAContext

    init(context: LAContext) {
        self.context = context
    }

    var evaluatedDomainState: Data? {
        context.domainState.biometry.stateHash
    }

    func preflight() -> DeviceAuthenticationPreflight {
        var error: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        ) else {
            return .failure(
                AppleDeviceAuthenticationErrorMapper.failure(from: error)
            )
        }
        // Preflight means only that evaluation can begin. Success is emitted
        // exclusively from evaluatePolicy's completion callback.
        return .available
    }

    func evaluate(
        reason: String,
        completion: @escaping @Sendable (DeviceAuthenticationEvaluation) -> Void
    ) {
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        ) { success, error in
            if success {
                completion(.success)
            } else {
                completion(.failure(
                    AppleDeviceAuthenticationErrorMapper.failure(from: error)
                ))
            }
        }
    }

    func invalidate() {
        context.invalidate()
    }
}

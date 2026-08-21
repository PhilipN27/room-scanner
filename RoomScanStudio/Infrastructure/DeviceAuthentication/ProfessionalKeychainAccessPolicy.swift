import Foundation
import Security

enum ProfessionalKeychainPolicyError: Error {
    case cannotCreateAccessControl
}

/// Policy only: callers can test the exact local protection without placing a
/// credential in Keychain. A storage adapter remains a separately reviewed,
/// externally configured professional dependency.
struct ProfessionalKeychainAccessPolicy {
    let accessibility: CFString
    let accessControlFlags: SecAccessControlCreateFlags

    init(
        accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        accessControlFlags: SecAccessControlCreateFlags = .userPresence
    ) {
        self.accessibility = accessibility
        self.accessControlFlags = accessControlFlags
    }

    func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            accessibility,
            accessControlFlags,
            &error
        ) else {
            throw ProfessionalKeychainPolicyError.cannotCreateAccessControl
        }
        return accessControl
    }
}

import Foundation
import Security

/// Concrete local adapter for explicitly configured professional composition.
/// Guest composition does not reference or construct this type.
final class KeychainMagicLinkTransientStateStore: MagicLinkTransientStateStore {
    private let service = "com.roomscanstudio.professional.magic-link"
    private let account = "pending-v3"
    private let policy: ProfessionalKeychainAccessPolicy

    init(policy: ProfessionalKeychainAccessPolicy = .init()) {
        self.policy = policy
    }

    func save(_ state: MagicLinkPendingState) throws {
        let encoded = try JSONEncoder().encode(state)
        try clear()
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessControl: try policy.makeAccessControl(),
            kSecValueData: encoded
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MagicLinkCompletionError.storageFailure
        }
    }

    func load() throws -> MagicLinkPendingState? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true
        ] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MagicLinkCompletionError.storageFailure
        }
        do {
            return try JSONDecoder().decode(MagicLinkPendingState.self, from: data)
        } catch {
            try? clear()
            throw MagicLinkCompletionError.invalidPendingState
        }
    }

    func clear() throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MagicLinkCompletionError.storageFailure
        }
    }
}

enum ProfessionalMagicLinkSecureRandom {
    static func bytes(count: Int) throws -> Data {
        guard count > 0 else { throw MagicLinkCompletionError.randomnessFailure }
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw MagicLinkCompletionError.randomnessFailure
        }
        return Data(bytes)
    }
}

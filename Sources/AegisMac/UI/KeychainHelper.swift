import Foundation
import LocalAuthentication
import Security

/// Optional, best-effort Touch ID support: stores the vault password in the login keychain
/// behind biometric access control (`.biometryCurrentSet`). On unlock the password is read
/// out after a successful biometric prompt and fed to the normal password-unlock path, so no
/// biometric vault slot is needed. If anything fails (no Secure Enclave / no biometrics / user
/// cancels), the caller falls back to typing the password. macOS-only convenience.
enum KeychainHelper {
    static let service = "org.myl7.aegis-mac"
    static let account = "vault-unlock-secret"

    /// Whether Touch ID (or Watch/other biometrics) is available on this Mac.
    static func biometricsAvailable() -> Bool {
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    /// True if a biometric-protected master key has been stored.
    static func hasStoredKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecReturnData as String: false
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Store the secret bytes behind biometric access control. Overwrites any existing item.
    @discardableResult
    static func store(secret: Data) -> Bool {
        deleteKey()
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrAccessControl as String: access
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Prompt for biometrics and return the stored secret bytes, or nil on failure/cancel.
    static func retrieveSecret(reason: String = "Unlock your Aegis vault") -> Data? {
        let ctx = LAContext()
        ctx.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: ctx
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    @discardableResult
    static func deleteKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

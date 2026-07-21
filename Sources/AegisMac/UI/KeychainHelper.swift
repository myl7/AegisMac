import Foundation
import LocalAuthentication
import Security

/// Optional, best-effort Touch ID support for unlocking the vault.
///
/// The vault password is stored in the login keychain as an ordinary device-only
/// generic-password item (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), and
/// access is gated by an explicit `LAContext` biometric evaluation on retrieval.
///
/// Why not a Secure-Enclave / `.biometryCurrentSet` access-control item? On macOS
/// those live in the data-protection keychain, which requires a `keychain-access-
/// groups` entitlement backed by a real signing identity. An ad-hoc-signed build
/// (how AegisMac is distributed) gets `errSecMissingEntitlement` (-34018) when it
/// tries to add such an item, and is killed by AMFI if it declares the entitlement.
/// So the biometric check here is enforced by the app, not bound to the key in
/// hardware — a deliberate trade-off for a self-signed, non-App-Store app. If the
/// vault password is unknown, the user simply types it instead.
enum KeychainHelper {
    static let service = "org.myl7.aegis-mac"
    static let account = "vault-unlock-secret"

    /// Whether Touch ID (or Watch/other biometrics) is available on this Mac.
    static func biometricsAvailable() -> Bool {
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    /// True if the vault password has been stored for Touch ID unlock.
    static func hasStoredKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Store the secret bytes as a device-only keychain item. Overwrites any
    /// existing item. Returns false on failure (retrievable via `lastStoreStatus`).
    @discardableResult
    static func store(secret: Data) -> Bool {
        deleteKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        lastStoreStatus = status
        return status == errSecSuccess
    }

    /// The raw `OSStatus` of the most recent `store` call, for diagnostics.
    private(set) static var lastStoreStatus: OSStatus = errSecSuccess

    /// A human-readable description of the most recent `store` failure.
    static func lastStoreErrorMessage() -> String {
        let msg = SecCopyErrorMessageString(lastStoreStatus, nil) as String? ?? "unknown error"
        return "\(msg) (\(lastStoreStatus))"
    }

    /// Prompt for biometrics and, on success, return the stored secret bytes.
    /// Returns nil if biometrics are unavailable, the prompt is cancelled/failed,
    /// or no secret is stored.
    static func retrieveSecret(reason: String = "Unlock your Aegis vault") async -> Data? {
        guard await evaluateBiometrics(reason: reason) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Presents the system Touch ID prompt and resolves to whether it succeeded.
    private static func evaluateBiometrics(reason: String) async -> Bool {
        guard biometricsAvailable() else { return false }
        let ctx = LAContext()
        return await withCheckedContinuation { continuation in
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
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

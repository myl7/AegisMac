import Foundation
import Security
import CryptoKit
import CryptoSwift

/// Low-level cryptographic primitives for the Aegis vault format.
///
/// - scrypt KDF via CryptoSwift (the only third-party dependency).
/// - AES-256-GCM via Apple CryptoKit, with the ciphertext and 16-byte tag kept
///   **separate** (Aegis persists them in different JSON fields; never `.combined`).
/// - No AAD is ever used. Nonce is always 12 bytes, tag always 16 bytes, key 32 bytes.
///
/// All functions here are pure/synchronous with no actor isolation; scrypt
/// derivation is CPU-bound and callers are responsible for moving it off the main
/// thread.
enum CryptoUtils {
    /// AES-256 key size in bytes.
    static let keySize = 32
    /// GCM tag size in bytes (128-bit).
    static let tagSize = 16
    /// GCM nonce/IV size in bytes (96-bit).
    static let nonceSize = 12

    // MARK: - scrypt

    /// Derives a 32-byte key from `password` bytes using scrypt with the given
    /// parameters (RFC 7914; PBKDF2 core is HMAC-SHA256, 1 iteration).
    ///
    /// `password` should be the exact-length UTF-8 encoding of the password
    /// (`Array(password.utf8)`), with no trailing NUL.
    static func deriveKey(password: [UInt8], params: ScryptParameters) throws -> Data {
        do {
            let derived = try Scrypt(
                password: password,
                salt: Array(params.salt),
                dkLen: keySize,
                N: params.n,
                r: params.r,
                p: params.p
            ).calculate()
            return Data(derived)
        } catch {
            throw AegisError.crypto("scrypt key derivation failed: \(error)")
        }
    }

    // MARK: - AES-256-GCM

    /// Encrypts `plain` with AES-256-GCM using a freshly generated random 12-byte
    /// nonce. Returns the ciphertext (same length as `plain`) plus the nonce/tag,
    /// stored separately (as Aegis does on disk).
    static func encrypt(_ plain: Data, key: Data) throws -> (cipherText: Data, params: CryptParameters) {
        guard key.count == keySize else {
            throw AegisError.crypto("invalid AES key length: \(key.count)")
        }
        do {
            let symmetricKey = SymmetricKey(data: key)
            // No nonce supplied -> CryptoKit generates a random 12-byte nonce.
            let box = try AES.GCM.seal(plain, using: symmetricKey)
            // Deliberately read the members separately; never use box.combined.
            let params = CryptParameters(nonce: Data(box.nonce), tag: box.tag)
            return (box.ciphertext, params)
        } catch {
            throw AegisError.crypto("AES-GCM encryption failed: \(error)")
        }
    }

    /// Decrypts `cipherText` with AES-256-GCM, rebuilding the sealed box from the
    /// separately-stored nonce, ciphertext and tag. Throws `AegisError.crypto` on
    /// authentication failure (wrong key/tampered data) or malformed parameters.
    static func decrypt(_ cipherText: Data, key: Data, params: CryptParameters) throws -> Data {
        guard key.count == keySize else {
            throw AegisError.crypto("invalid AES key length: \(key.count)")
        }
        do {
            let symmetricKey = SymmetricKey(data: key)
            let nonce = try AES.GCM.Nonce(data: params.nonce)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherText, tag: params.tag)
            return try AES.GCM.open(box, using: symmetricKey)
        } catch {
            throw AegisError.crypto("AES-GCM decryption failed: \(error)")
        }
    }

    // MARK: - Randomness

    /// Cryptographically-secure random bytes.
    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            // Fallback to the system RNG (still CSPRNG-backed on Apple platforms).
            var rng = SystemRandomNumberGenerator()
            for i in 0..<count {
                bytes[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng)
            }
        }
        return Data(bytes)
    }
}

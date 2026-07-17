import Foundation

/// Wraps the 32-byte vault master key. There is exactly one master key per vault;
/// every slot stores its own AES-GCM-wrapped copy, and the master key encrypts the
/// db payload.
final class MasterKey {
    let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
    }

    /// Generates a new random 32-byte (AES-256) master key.
    static func generate() -> MasterKey {
        return MasterKey(bytes: CryptoUtils.randomBytes(CryptoUtils.keySize))
    }

    /// Encrypts `plain` with this master key (AES-256-GCM, fresh random nonce).
    func encrypt(_ plain: Data) throws -> (cipherText: Data, params: CryptParameters) {
        return try CryptoUtils.encrypt(plain, key: bytes)
    }

    /// Decrypts `cipherText` produced by `encrypt(_:)`.
    func decrypt(_ cipherText: Data, params: CryptParameters) throws -> Data {
        return try CryptoUtils.decrypt(cipherText, key: bytes, params: params)
    }
}

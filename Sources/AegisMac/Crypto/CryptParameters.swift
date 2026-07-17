import Foundation

/// AES-GCM nonce + tag pair, stored separately from the ciphertext (Aegis splits
/// the 16-byte tag off the end of `Cipher.doFinal()` and persists it on its own).
///
/// JSON shape: `{ "nonce": <hex, 12 bytes>, "tag": <hex, 16 bytes> }`.
struct CryptParameters {
    /// 12-byte GCM nonce (IV).
    var nonce: Data
    /// 16-byte GCM authentication tag.
    var tag: Data

    init(nonce: Data, tag: Data) {
        // Rebase to zero-based storage: CryptoKit's `box.tag`/`box.nonce` (and Data
        // slices in general) can have a non-zero `startIndex`, which makes callers
        // that index with `tag[0]` trap. Copying normalizes the indices to 0.
        self.nonce = Data(nonce)
        self.tag = Data(tag)
    }

    func toJson() -> JSONObject {
        return [
            "nonce": HexCodec.encode(nonce),
            "tag": HexCodec.encode(tag)
        ]
    }

    static func fromJson(_ obj: JSONObject) throws -> CryptParameters {
        guard let nonceHex = obj["nonce"] as? String else {
            throw AegisError.crypto("crypt params missing 'nonce'")
        }
        guard let tagHex = obj["tag"] as? String else {
            throw AegisError.crypto("crypt params missing 'tag'")
        }
        let nonce = try HexCodec.decode(nonceHex)
        let tag = try HexCodec.decode(tagHex)
        return CryptParameters(nonce: nonce, tag: tag)
    }
}

import Foundation

/// scrypt KDF parameters. Aegis defaults for a newly-created password slot are
/// `N = 32768 (1 << 15)`, `r = 8`, `p = 1`, with a random 32-byte salt.
///
/// On read, the per-slot stored `n`/`r`/`p`/`salt` are always honored rather than
/// assuming the defaults.
struct ScryptParameters {
    /// Default scrypt parameters (constants from `CryptoUtils`).
    static let defaultN = 32768   // 1 << 15
    static let defaultR = 8
    static let defaultP = 1
    /// Salt length used for newly-generated slots (= AES-256 key size).
    static let saltLength = 32

    var n: Int
    var r: Int
    var p: Int
    var salt: Data

    init(n: Int = ScryptParameters.defaultN,
         r: Int = ScryptParameters.defaultR,
         p: Int = ScryptParameters.defaultP,
         salt: Data) {
        self.n = n
        self.r = r
        self.p = p
        self.salt = salt
    }

    /// Fresh parameters with default N/r/p and a random 32-byte salt.
    static func generate() -> ScryptParameters {
        return ScryptParameters(salt: CryptoUtils.randomBytes(saltLength))
    }
}

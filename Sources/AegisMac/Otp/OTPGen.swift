import Foundation
import CryptoKit

/// Pure OTP algorithm functions, ported byte-for-byte from the Aegis Android
/// sources under `crypto/otp/` (HOTP, TOTP, OTP, MOTP, YAOTP).
///
/// All truncation, masking, integer-saturation and encoding edge cases are
/// reproduced exactly so generated codes are cross-compatible with Android Aegis.
enum OTPGen {

    // MARK: - HOTP (RFC 4226)

    /// `algo` is the bare HMAC name ("SHA1"/"SHA256"/"SHA512"/"MD5"); a leading
    /// "Hmac" prefix is tolerated and stripped.
    static func hotp(secret: Data, algo: String, digits: Int, counter: Int64) throws -> String {
        let code = try hotpTruncate(secret: secret, algo: algo, counter: counter)
        return formatDecimal(code: code, digits: digits)
    }

    // MARK: - TOTP (RFC 6238)

    static func totp(secret: Data, algo: String, digits: Int, period: Int, time: Int64) throws -> String {
        let counter = timeStepCounter(seconds: time, period: Int64(period))
        return try hotp(secret: secret, algo: algo, digits: digits, counter: counter)
    }

    // MARK: - Steam (TOTP variant, 5-char alphabet)

    static func steam(secret: Data, algo: String, digits: Int, period: Int, time: Int64) throws -> String {
        let counter = timeStepCounter(seconds: time, period: Int64(period))
        let code = try hotpTruncate(secret: secret, algo: algo, counter: counter)
        return steamFormat(code: code, digits: digits)
    }

    // MARK: - MOTP (Mobile-OTP)

    /// MOTP always uses a raw MD5 message digest (not HMAC). `toDigest` is the
    /// decimal time counter, the LOWERCASE hex of the secret, and the pin, all
    /// concatenated as UTF-8; the output is the first `digits` lowercase hex chars.
    static func motp(secret: Data, digits: Int, period: Int, pin: String, time: Int64) throws -> String {
        // NOTE: Java uses plain long/int division here (truncation toward zero),
        // NOT Math.floor over a double as TOTP does. For positive time they agree.
        let timeBasedCounter = time / Int64(period)
        let secretAsString = HexCodec.encode(secret) // lowercase hex
        let toDigest = String(timeBasedCounter) + secretAsString + pin
        let digest = Insecure.MD5.hash(data: Data(toDigest.utf8))
        let code = HexCodec.encode(Data(digest)) // lowercase hex, 32 chars
        guard digits >= 0, digits <= code.count else {
            throw AegisError.otp("bad number of MOTP digits: \(digits)")
        }
        return String(code.prefix(digits))
    }

    // MARK: - Yandex (YAOTP)

    /// Yandex OTP: SHA-256(pin || secret) keyed HMAC-SHA256, with a leading 0x00
    /// byte dropped from the key hash, an in-place 0x7f mask, a big-endian int64
    /// read at the truncation offset, and a base-26 ('a'..'z') encoding.
    static func yandex(secret: Data, pin: String, digits: Int, period: Int, time: Int64) throws -> String {
        var pinWithHash = Data(pin.utf8)
        pinWithHash.append(secret)
        var keyHash = Data(SHA256.hash(data: pinWithHash)) // 32 bytes

        // Drop a leading zero byte (signed-byte == 0x00) if present.
        if keyHash.first == 0 {
            keyHash = keyHash.subdata(in: 1..<keyHash.count) // now 31 bytes
        }

        let counter = timeStepCounter(seconds: time, period: Int64(period))
        var periodHash = try hmacBytes(algo: "SHA256", key: keyHash, message: counterBytes(counter))

        let offset = Int(periodHash[periodHash.count - 1] & 0x0f)
        periodHash[offset] &= 0x7f

        // Big-endian signed int64 read starting at `offset`. The top-bit mask
        // above guarantees a non-negative value.
        var raw: UInt64 = 0
        for i in 0..<8 {
            raw = (raw << 8) | UInt64(periodHash[offset + i])
        }
        let code = Int64(bitPattern: raw)
        return yandexFormat(code: code, digits: digits)
    }

    // MARK: - Truncation & formatting internals

    /// RFC 4226 dynamic truncation. Returns a non-negative 31-bit integer.
    private static func hotpTruncate(secret: Data, algo: String, counter: Int64) throws -> Int {
        let hash = try hmacBytes(algo: algo, key: secret, message: counterBytes(counter))
        let offset = Int(hash[hash.count - 1] & 0x0f)
        let otp = (Int(hash[offset] & 0x7f) << 24)
                | (Int(hash[offset + 1] & 0xff) << 16)
                | (Int(hash[offset + 2] & 0xff) << 8)
                |  Int(hash[offset + 3] & 0xff)
        return otp
    }

    /// `OTP.toString()`: `code % (int)Math.pow(10, digits)`, left-padded with '0'.
    private static func formatDecimal(code: Int, digits: Int) -> String {
        let divisor = javaIntPow10(digits)
        let value = divisor == 0 ? code : code % divisor
        var s = String(value)
        if s.count < digits {
            s = String(repeating: "0", count: digits - s.count) + s
        }
        return s
    }

    private static let steamAlphabet = Array("23456789BCDFGHJKMNPQRTVWXY")

    /// `OTP.toSteamString()`: append `alphabet[code % 26]` then `code /= 26`,
    /// `digits` times — least-significant char FIRST (not reversed).
    private static func steamFormat(code: Int, digits: Int) -> String {
        var c = code
        let n = steamAlphabet.count // 26
        var res = ""
        res.reserveCapacity(digits)
        for _ in 0..<digits {
            res.append(steamAlphabet[c % n])
            c /= n
        }
        return res
    }

    /// `YAOTP.toString()`: `code % (long)Math.pow(26, digits)`, then fill an
    /// array of `digits` chars from the LAST index down using 'a' + (code % 26).
    private static func yandexFormat(code: Int64, digits: Int) -> String {
        let divisor = javaLongPow26(digits)
        var value = divisor == 0 ? code : code % divisor
        var chars = [Character](repeating: "a", count: digits)
        var i = digits - 1
        while i >= 0 {
            let scalar = UInt8(97 + Int(value % 26)) // 'a' == 97
            chars[i] = Character(UnicodeScalar(scalar))
            value /= 26
            i -= 1
        }
        return String(chars)
    }

    // MARK: - HMAC via CryptoKit

    private static func hmacBytes(algo: String, key: Data, message: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        switch normalizeAlgo(algo) {
        case "SHA1":
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: symKey))
        case "SHA256":
            return Data(HMAC<SHA256>.authenticationCode(for: message, using: symKey))
        case "SHA512":
            return Data(HMAC<SHA512>.authenticationCode(for: message, using: symKey))
        case "MD5":
            return Data(HMAC<Insecure.MD5>.authenticationCode(for: message, using: symKey))
        default:
            throw AegisError.otp("unsupported algorithm: \(algo)")
        }
    }

    private static func normalizeAlgo(_ algo: String) -> String {
        var a = algo
        if a.hasPrefix("Hmac") {
            a = String(a.dropFirst(4))
        }
        return a.uppercased()
    }

    // MARK: - Numeric helpers

    /// Counter → 8-byte big-endian, matching Java's `ByteBuffer.putLong`.
    private static func counterBytes(_ counter: Int64) -> Data {
        var be = counter.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    /// `(long) Math.floor((double) seconds / period)`. Reproduced with the same
    /// double arithmetic as the Java source for bit-exact counters.
    private static func timeStepCounter(seconds: Int64, period: Int64) -> Int64 {
        let quotient = (Double(seconds) / Double(period)).rounded(.down)
        return javaDoubleToLong(quotient)
    }

    /// Java `(int) Math.pow(10, digits)`. For digits 1–9 this is the exact power
    /// of ten; for digits == 10, `1e10` saturates on the double→int cast to
    /// Integer.MAX_VALUE (2147483647).
    private static func javaIntPow10(_ digits: Int) -> Int {
        return javaDoubleToInt(pow(10.0, Double(digits)))
    }

    /// Java `(long) Math.pow(26, digits)`.
    private static func javaLongPow26(_ digits: Int) -> Int64 {
        return javaLongFromDouble(pow(26.0, Double(digits)))
    }

    /// Java narrowing double→int: truncate toward zero, saturating to the Int32
    /// range. Returned widened to `Int`.
    private static func javaDoubleToInt(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        if d >= Double(Int32.max) { return Int(Int32.max) }
        if d <= Double(Int32.min) { return Int(Int32.min) }
        return Int(Int32(d.rounded(.towardZero)))
    }

    /// Java narrowing double→long: truncate toward zero, saturating to Int64.
    private static func javaLongFromDouble(_ d: Double) -> Int64 {
        return javaDoubleToLong(d.rounded(.towardZero))
    }

    /// Java `(long) doubleValue`: assumes `d` already truncated toward zero
    /// (or an integral floor), saturating to the Int64 range.
    private static func javaDoubleToLong(_ d: Double) -> Int64 {
        if d.isNaN { return 0 }
        if d >= Double(Int64.max) { return Int64.max }
        if d <= Double(Int64.min) { return Int64.min }
        return Int64(d)
    }
}

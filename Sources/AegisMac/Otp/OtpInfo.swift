import Foundation

/// Abstract base for all OTP entry metadata, mirroring `OtpInfo.java`.
///
/// Holds the shared `secret`, bare `algorithm` name and `digits`, plus the JSON
/// (de)serialization contract used by vault entries. Concrete subclasses
/// (`TotpInfo`, `HotpInfo`, `SteamInfo`, `MotpInfo`, `YandexInfo`) supply the
/// generation logic and any extra fields.
class OtpInfo {
    static let defaultDigits = 6
    static let defaultAlgorithm = "SHA1"

    var secret: Data
    /// Bare, validated HMAC name: "SHA1" / "SHA256" / "SHA512" / "MD5".
    private(set) var algorithm: String
    private(set) var digits: Int

    init(secret: Data, algorithm: String = OtpInfo.defaultAlgorithm, digits: Int = OtpInfo.defaultDigits) throws {
        self.secret = secret
        self.algorithm = OtpInfo.defaultAlgorithm
        self.digits = OtpInfo.defaultDigits
        try setAlgorithm(algorithm)
        try setDigits(digits)
    }

    // MARK: Type identity

    /// e.g. "totp" / "hotp" / "steam" / "motp" / "yandex". Overridden per subclass.
    var typeId: String { fatalError("OtpInfo is abstract; use a concrete subclass") }

    /// Display name (Java `getType()`): default is the upper-cased type id.
    var typeName: String { typeId.uppercased() }

    // MARK: Generation

    /// Abstract in Java; concrete subclasses override.
    func getOtp(time: Int64) throws -> String {
        throw AegisError.otp("getOtp is not implemented on the abstract OtpInfo")
    }

    func checkSecret() throws {
        if secret.isEmpty {
            throw AegisError.otp("Secret is empty")
        }
    }

    // MARK: Algorithm / digits

    /// Java `getAlgorithm(boolean)`: `true` → "Hmac"+name (Mac name), `false` → bare name.
    func getAlgorithm(_ java: Bool) -> String {
        return java ? "Hmac" + algorithm : algorithm
    }

    static func isAlgorithmValid(_ algorithm: String) -> Bool {
        return algorithm == "SHA1" || algorithm == "SHA256"
            || algorithm == "SHA512" || algorithm == "MD5"
    }

    /// Strips a leading "Hmac" prefix, upper-cases, then validates.
    func setAlgorithm(_ algorithm: String) throws {
        var algo = algorithm
        if algo.hasPrefix("Hmac") {
            algo = String(algo.dropFirst(4))
        }
        algo = algo.uppercased()
        guard OtpInfo.isAlgorithmValid(algo) else {
            throw AegisError.otp("unsupported algorithm: \(algo)")
        }
        self.algorithm = algo
    }

    static func isDigitsValid(_ digits: Int) -> Bool {
        // A max of 10 digits, as truncation only extracts 31 bits.
        return digits > 0 && digits <= 10
    }

    func setDigits(_ digits: Int) throws {
        guard OtpInfo.isDigitsValid(digits) else {
            throw AegisError.otp("unsupported amount of digits: \(digits)")
        }
        self.digits = digits
    }

    // MARK: JSON

    func toJson() -> JSONObject {
        var obj: JSONObject = [:]
        obj["secret"] = Base32.encode(secret)
        obj["algo"] = getAlgorithm(false)
        obj["digits"] = digits
        return obj
    }

    static func fromJson(type: String, obj: JSONObject) throws -> OtpInfo {
        let secret = try Base32.decode(OtpJSON.string(obj, "secret"))
        var algo = try OtpJSON.string(obj, "algo")
        let digits = try OtpJSON.int(obj, "digits")

        // Work around a bug where a user could accidentally set the hash
        // algorithm of a non-mOTP entry to MD5.
        if type != "motp" && algo == "MD5" {
            algo = OtpInfo.defaultAlgorithm
        }

        switch type {
        case "totp":
            return try TotpInfo(secret: secret, algorithm: algo, digits: digits, period: OtpJSON.int(obj, "period"))
        case "steam":
            return try SteamInfo(secret: secret, algorithm: algo, digits: digits, period: OtpJSON.int(obj, "period"))
        case "hotp":
            return try HotpInfo(secret: secret, algorithm: algo, digits: digits, counter: OtpJSON.int64(obj, "counter"))
        case "yandex":
            return try YandexInfo(secret: secret, pin: OtpJSON.string(obj, "pin"))
        case "motp":
            return try MotpInfo(secret: secret, pin: OtpJSON.string(obj, "pin"))
        default:
            throw AegisError.otp("unsupported otp type: \(type)")
        }
    }

    // MARK: Equality

    /// Java `equals`: same type id, secret bytes, bare algorithm and digits.
    /// Subclasses tighten this with their extra fields.
    func isEqual(to other: OtpInfo) -> Bool {
        return typeId == other.typeId
            && secret == other.secret
            && algorithm == other.algorithm
            && digits == other.digits
    }
}

// MARK: - TOTP

class TotpInfo: OtpInfo {
    static let defaultPeriod = 30

    private(set) var period: Int = TotpInfo.defaultPeriod

    init(secret: Data) throws {
        try super.init(secret: secret)
        try setPeriod(TotpInfo.defaultPeriod)
    }

    init(secret: Data, algorithm: String, digits: Int, period: Int) throws {
        try super.init(secret: secret, algorithm: algorithm, digits: digits)
        try setPeriod(period)
    }

    override var typeId: String { "totp" }

    override func getOtp(time: Int64) throws -> String {
        try checkSecret()
        return try OTPGen.totp(secret: secret, algo: algorithm, digits: digits, period: period, time: time)
    }

    static func isPeriodValid(_ period: Int) -> Bool {
        // > 0 and no overflow when converting to milliseconds.
        return period > 0 && period <= Int(Int32.max) / 1000
    }

    func setPeriod(_ period: Int) throws {
        guard TotpInfo.isPeriodValid(period) else {
            throw AegisError.otp("bad period: \(period)")
        }
        self.period = period
    }

    /// `now` is the current time in milliseconds.
    func millisTillNextRotation(now: Int64) -> Int64 {
        let p = Int64(period) * 1000
        return p - (now % p)
    }

    override func toJson() -> JSONObject {
        var obj = super.toJson()
        obj["period"] = period
        return obj
    }

    override func isEqual(to other: OtpInfo) -> Bool {
        guard let o = other as? TotpInfo else { return false }
        return super.isEqual(to: other) && period == o.period
    }
}

// MARK: - HOTP

final class HotpInfo: OtpInfo {
    static let defaultCounter: Int64 = 0

    private(set) var counter: Int64 = HotpInfo.defaultCounter

    init(secret: Data, counter: Int64 = HotpInfo.defaultCounter) throws {
        try super.init(secret: secret)
        try setCounter(counter)
    }

    init(secret: Data, algorithm: String, digits: Int, counter: Int64) throws {
        try super.init(secret: secret, algorithm: algorithm, digits: digits)
        try setCounter(counter)
    }

    override var typeId: String { "hotp" }

    override func getOtp(time: Int64) throws -> String {
        // HOTP ignores the supplied time; it is counter-based.
        try checkSecret()
        return try OTPGen.hotp(secret: secret, algo: algorithm, digits: digits, counter: counter)
    }

    static func isCounterValid(_ counter: Int64) -> Bool {
        return counter >= 0
    }

    func setCounter(_ counter: Int64) throws {
        guard HotpInfo.isCounterValid(counter) else {
            throw AegisError.otp("bad counter: \(counter)")
        }
        self.counter = counter
    }

    func incrementCounter() {
        counter += 1
    }

    override func toJson() -> JSONObject {
        var obj = super.toJson()
        obj["counter"] = counter
        return obj
    }

    override func isEqual(to other: OtpInfo) -> Bool {
        guard let o = other as? HotpInfo else { return false }
        return super.isEqual(to: other) && counter == o.counter
    }
}

// MARK: - Steam

final class SteamInfo: TotpInfo {
    static let steamDigits = 5

    override init(secret: Data) throws {
        try super.init(secret: secret,
                       algorithm: OtpInfo.defaultAlgorithm,
                       digits: SteamInfo.steamDigits,
                       period: TotpInfo.defaultPeriod)
    }

    override init(secret: Data, algorithm: String, digits: Int, period: Int) throws {
        try super.init(secret: secret, algorithm: algorithm, digits: digits, period: period)
    }

    override var typeId: String { "steam" }

    override var typeName: String { "Steam" }

    override func getOtp(time: Int64) throws -> String {
        try checkSecret()
        return try OTPGen.steam(secret: secret, algo: algorithm, digits: digits, period: period, time: time)
    }
}

// MARK: - MOTP

final class MotpInfo: TotpInfo {
    static let motpAlgorithm = "MD5"
    static let motpPeriod = 10
    static let motpDigits = 6

    var pin: String?

    init(secret: Data, pin: String? = nil) throws {
        try super.init(secret: secret,
                       algorithm: MotpInfo.motpAlgorithm,
                       digits: MotpInfo.motpDigits,
                       period: MotpInfo.motpPeriod)
        self.pin = pin
    }

    override var typeId: String { "motp" }

    override func getOtp(time: Int64) throws -> String {
        guard let pin = pin else {
            throw AegisError.otp("PIN must be set before generating an OTP")
        }
        return try OTPGen.motp(secret: secret, digits: digits, period: period, pin: pin, time: time)
    }

    func setPin(_ pin: String) {
        self.pin = pin
    }

    override func toJson() -> JSONObject {
        var obj = super.toJson()
        if let pin = pin {
            obj["pin"] = pin
        }
        return obj
    }

    override func isEqual(to other: OtpInfo) -> Bool {
        guard let o = other as? MotpInfo else { return false }
        return super.isEqual(to: other) && pin == o.pin
    }
}

// MARK: - Yandex

final class YandexInfo: TotpInfo {
    static let yandexAlgorithm = "SHA256"
    static let yandexDigits = 8
    static let secretLength = 16
    static let secretFullLength = 26

    var pin: String?

    init(secret: Data, pin: String? = nil) throws {
        try super.init(secret: secret,
                       algorithm: YandexInfo.yandexAlgorithm,
                       digits: YandexInfo.yandexDigits,
                       period: TotpInfo.defaultPeriod)
        self.secret = try YandexInfo.parseSecret(secret)
        self.pin = pin
    }

    override var typeId: String { "yandex" }

    override var typeName: String { "Yandex" }

    override func getOtp(time: Int64) throws -> String {
        guard let pin = pin else {
            throw AegisError.otp("PIN must be set before generating an OTP")
        }
        return try OTPGen.yandex(secret: secret, pin: pin, digits: digits, period: period, time: time)
    }

    func setPin(_ pin: String) {
        self.pin = pin
    }

    override func toJson() -> JSONObject {
        var obj = super.toJson()
        if let pin = pin {
            obj["pin"] = pin
        }
        return obj
    }

    override func isEqual(to other: OtpInfo) -> Bool {
        guard let o = other as? YandexInfo else { return false }
        return super.isEqual(to: other) && pin == o.pin
    }

    // MARK: Secret parsing / checksum validation

    /// Validates the secret then truncates to the first 16 bytes.
    static func parseSecret(_ secret: Data) throws -> Data {
        try validateSecret(secret)
        if secret.count != secretLength {
            return Data(secret.prefix(secretLength))
        }
        return secret
    }

    /// Ported from KeeYaOtp's `ChecksumIsValid` via `YandexInfo.validateSecret`.
    /// 16-byte (QR) secrets carry no checksum and are always accepted.
    static func validateSecret(_ secret: Data) throws {
        let bytes = [UInt8](secret)
        guard bytes.count == secretLength || bytes.count == secretFullLength else {
            throw AegisError.otp("Invalid Yandex secret length: \(bytes.count) bytes")
        }
        if bytes.count == secretLength {
            return
        }

        let originalChecksum = UInt16((UInt16(bytes[bytes.count - 2] & 0x0F) << 8)
                                      | UInt16(bytes[bytes.count - 1]))

        var accum: UInt16 = 0
        var accumBits = 0

        var inputTotalBitsAvailable = bytes.count * 8 - 12
        var inputIndex = 0
        var inputBitsAvailable = 8

        while inputTotalBitsAvailable > 0 {
            var requiredBits = 13 - accumBits
            if inputTotalBitsAvailable < requiredBits {
                requiredBits = inputTotalBitsAvailable
            }

            while requiredBits > 0 {
                var curInput = Int(bytes[inputIndex]) & ((1 << inputBitsAvailable) - 1) & 0xFF
                let bitsToRead = min(requiredBits, inputBitsAvailable)

                curInput >>= (inputBitsAvailable - bitsToRead)
                accum = UInt16(truncatingIfNeeded: (Int(accum) << bitsToRead) | curInput)

                inputTotalBitsAvailable -= bitsToRead
                requiredBits -= bitsToRead
                inputBitsAvailable -= bitsToRead
                accumBits += bitsToRead

                if inputBitsAvailable == 0 {
                    inputIndex += 1
                    inputBitsAvailable = 8
                }
            }

            if accumBits == 13 {
                accum ^= 0b1_1000_1111_0011 // 0x18F3
            }
            accumBits = 16 - numberOfLeadingZeros16(accum)
        }

        if accum != originalChecksum {
            throw AegisError.otp("Yandex secret checksum invalid")
        }
    }

    /// Leading-zero count over a 16-bit value (0 → 16).
    private static func numberOfLeadingZeros16(_ value: UInt16) -> Int {
        if value == 0 {
            return 16
        }
        var v = value
        var n = 0
        if (v & 0xFF00) == 0 { n += 8; v <<= 8 }
        if (v & 0xF000) == 0 { n += 4; v <<= 4 }
        if (v & 0xC000) == 0 { n += 2; v <<= 2 }
        if (v & 0x8000) == 0 { n += 1 }
        return n
    }
}

// MARK: - JSON coercion helpers

/// Robust readers for the dynamic `[String: Any]` OTP JSON, accepting both the
/// native Swift values produced by `toJson()` and the `NSNumber`/`String`
/// values that come back through `JSONSerialization`.
private enum OtpJSON {
    static func string(_ obj: JSONObject, _ key: String) throws -> String {
        guard let value = obj[key] else {
            throw AegisError.otp("missing OTP field: \(key)")
        }
        if let s = value as? String {
            return s
        }
        throw AegisError.otp("OTP field \(key) is not a string")
    }

    static func int(_ obj: JSONObject, _ key: String) throws -> Int {
        guard let value = obj[key] else {
            throw AegisError.otp("missing OTP field: \(key)")
        }
        if let n = value as? Int { return n }
        if let n = value as? Int64 { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let n = Int(s) { return n }
        throw AegisError.otp("OTP field \(key) is not an integer")
    }

    static func int64(_ obj: JSONObject, _ key: String) throws -> Int64 {
        guard let value = obj[key] else {
            throw AegisError.otp("missing OTP field: \(key)")
        }
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String, let n = Int64(s) { return n }
        throw AegisError.otp("OTP field \(key) is not a long")
    }
}

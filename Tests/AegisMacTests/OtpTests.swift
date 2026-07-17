import XCTest
import CryptoKit
@testable import AegisMac

/// OTP algorithm + model tests. Vectors are transcribed verbatim from the Aegis
/// Android test suite (`crypto/otp/*Test.java`, `otp/*Test.java`) and the
/// otp-algorithms spec §8.
final class OtpTests: XCTestCase {

    // MARK: - Shared seeds

    /// RFC 4226 / 6238 SHA1 seed: ASCII "12345678901234567890" (20 bytes).
    private let seedSHA1 = Data("12345678901234567890".utf8)
    /// RFC 6238 SHA256 seed (32 bytes).
    private let seedSHA256 = Data("12345678901234567890123456789012".utf8)
    /// RFC 6238 SHA512 seed (64 bytes).
    private let seedSHA512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    // MARK: - HOTP (RFC 4226)

    func testHOTP_RFC4226Vectors() throws {
        let expected = ["755224", "287082", "359152", "969429", "338314",
                        "254676", "287922", "162583", "399871", "520489"]
        for (counter, want) in expected.enumerated() {
            let got = try OTPGen.hotp(secret: seedSHA1, algo: "SHA1", digits: 6, counter: Int64(counter))
            XCTAssertEqual(got, want, "HOTP counter \(counter)")
        }
    }

    func testHOTP_viaHotpInfo() throws {
        let expected = ["755224", "287082", "359152", "969429", "338314",
                        "254676", "287922", "162583", "399871", "520489"]
        for (counter, want) in expected.enumerated() {
            let info = try HotpInfo(secret: seedSHA1, algorithm: "SHA1", digits: 6, counter: Int64(counter))
            XCTAssertEqual(try info.getOtp(time: 0), want, "HotpInfo counter \(counter)")
        }
    }

    // MARK: - TOTP (RFC 6238), 8 digits, period 30

    func testTOTP_RFC6238Vectors() throws {
        struct V { let time: Int64; let algo: String; let otp: String }
        let vectors: [V] = [
            V(time: 59, algo: "SHA1", otp: "94287082"),
            V(time: 59, algo: "SHA256", otp: "46119246"),
            V(time: 59, algo: "SHA512", otp: "90693936"),
            V(time: 1111111109, algo: "SHA1", otp: "07081804"),
            V(time: 1111111109, algo: "SHA256", otp: "68084774"),
            V(time: 1111111109, algo: "SHA512", otp: "25091201"),
            V(time: 1111111111, algo: "SHA1", otp: "14050471"),
            V(time: 1111111111, algo: "SHA256", otp: "67062674"),
            V(time: 1111111111, algo: "SHA512", otp: "99943326"),
            V(time: 1234567890, algo: "SHA1", otp: "89005924"),
            V(time: 1234567890, algo: "SHA256", otp: "91819424"),
            V(time: 1234567890, algo: "SHA512", otp: "93441116"),
            V(time: 2000000000, algo: "SHA1", otp: "69279037"),
            V(time: 2000000000, algo: "SHA256", otp: "90698825"),
            V(time: 2000000000, algo: "SHA512", otp: "38618901"),
            V(time: 20000000000, algo: "SHA1", otp: "65353130"),
            V(time: 20000000000, algo: "SHA256", otp: "77737706"),
            V(time: 20000000000, algo: "SHA512", otp: "47863826"),
        ]
        for v in vectors {
            let seed = seed(for: v.algo)
            let got = try OTPGen.totp(secret: seed, algo: v.algo, digits: 8, period: 30, time: v.time)
            XCTAssertEqual(got, v.otp, "TOTP time \(v.time) \(v.algo)")

            // Same result through the TotpInfo model.
            let info = try TotpInfo(secret: seed, algorithm: v.algo, digits: 8, period: 30)
            XCTAssertEqual(try info.getOtp(time: v.time), v.otp, "TotpInfo time \(v.time) \(v.algo)")
        }
    }

    private func seed(for algo: String) -> Data {
        switch algo {
        case "SHA1": return seedSHA1
        case "SHA256": return seedSHA256
        case "SHA512": return seedSHA512
        default: fatalError("no seed for \(algo)")
        }
    }

    // MARK: - MOTP

    func testMOTP_Vectors() throws {
        struct V { let time: Int64; let otp: String; let pin: String; let secretHex: String }
        let vectors: [V] = [
            V(time: 165892298, otp: "e7d8b6", pin: "1234", secretHex: "e3152afee62599c8"),
            V(time: 123456789, otp: "4ebfb2", pin: "1234", secretHex: "e3152afee62599c8"),
            V(time: 165954002 * 10, otp: "ced7b1", pin: "9999", secretHex: "bbb1912bb5c515be"),
            V(time: 165954002 * 10 + 2, otp: "ced7b1", pin: "9999", secretHex: "bbb1912bb5c515be"),
            V(time: 165953987 * 10, otp: "1a14f8", pin: "9999", secretHex: "bbb1912bb5c515be"),
            V(time: 165953987 * 10 + 8, otp: "1a14f8", pin: "9999", secretHex: "bbb1912bb5c515be"),
        ]
        for v in vectors {
            let secret = try HexCodec.decode(v.secretHex)
            let got = try OTPGen.motp(secret: secret, digits: 6, period: 10, pin: v.pin, time: v.time)
            XCTAssertEqual(got, v.otp, "MOTP time \(v.time)")

            // Same result through the MotpInfo model (forces MD5/6/10).
            let info = try MotpInfo(secret: secret, pin: v.pin)
            XCTAssertEqual(try info.getOtp(time: v.time), v.otp, "MotpInfo time \(v.time)")
        }
    }

    /// Raw MD5 digest checks — the exact digest+lowercase-hex pipeline MOTP uses.
    func testMOTP_RawDigest() throws {
        XCTAssertEqual(HexCodec.encode(Data(Insecure.MD5.hash(data: Data("BOB".utf8)))),
                       "355938cfe3b73a624297591972d27c01")
        XCTAssertEqual(HexCodec.encode(Data(Insecure.MD5.hash(data: Data("test1234".utf8)))),
                       "16d7a4fca7442dda3ad93c9a726597e4")
    }

    // MARK: - Yandex (YAOTP), 8 digits, HmacSHA256, period 30

    func testYandex_Vectors() throws {
        struct V { let pin: String; let b32: String; let ts: Int64; let otp: String }
        let vectors: [V] = [
            V(pin: "5239", b32: "6SB2IKNM6OBZPAVBVTOHDKS4FAAAAAAADFUTQMBTRY", ts: 1641559648, otp: "umozdicq"),
            V(pin: "7586", b32: "LA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI", ts: 1581064020, otp: "oactmacq"),
            V(pin: "7586", b32: "LA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI", ts: 1581090810, otp: "wemdwrix"),
            V(pin: "5210481216086702", b32: "JBGSAU4G7IEZG6OY4UAXX62JU4AAAAAAHTSG4HXU3M", ts: 1581091469, otp: "dfrpywob"),
            V(pin: "5210481216086702", b32: "JBGSAU4G7IEZG6OY4UAXX62JU4AAAAAAHTSG4HXU3M", ts: 1581093059, otp: "vunyprpd"),
        ]
        for v in vectors {
            let secret = try YandexInfo.parseSecret(Base32.decode(v.b32))
            XCTAssertEqual(secret.count, 16, "Yandex parsed secret must be 16 bytes")
            let got = try OTPGen.yandex(secret: secret, pin: v.pin, digits: 8, period: 30, time: v.ts)
            XCTAssertEqual(got, v.otp, "Yandex ts \(v.ts)")

            // Same result through the YandexInfo model.
            let info = try YandexInfo(secret: try Base32.decode(v.b32), pin: v.pin)
            XCTAssertEqual(try info.getOtp(time: v.ts), v.otp, "YandexInfo ts \(v.ts)")
        }
    }

    func testYandex_SecretValidation() throws {
        let ok = [
            "LA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI", // 26 bytes, valid checksum
            "LA2V6KMCGYMWWVEW64RNP3JA3I",                 // 16 bytes, QR, no checksum
        ]
        for s in ok {
            XCTAssertNoThrow(try YandexInfo.validateSecret(Base32.decode(s)), "expected valid: \(s)")
        }

        let bad = [
            "AA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI", // 26 bytes, first char differs -> bad checksum
            "AA2V6KMCGJA3IAAAAAAHTSG4HRZPI",              // wrong length (17 bytes)
        ]
        for s in bad {
            XCTAssertThrowsError(try YandexInfo.validateSecret(Base32.decode(s)), "expected invalid: \(s)")
        }
    }

    // MARK: - Steam

    /// Steam formatting. Derived from RFC 4226/6238: SEED (SHA1) at counter 1
    /// (time 59, period 30) yields the 31-bit dynamic-truncation code 1094287082
    /// (its 6-digit HOTP is 287082, its 8-digit TOTP is 94287082). Base-26
    /// encoding of 1094287082 over "23456789BCDFGHJKMNPQRTVWXY" (LSB char first)
    /// gives "PV9M4".
    func testSteam_Formatting() throws {
        let got = try OTPGen.steam(secret: seedSHA1, algo: "SHA1", digits: 5, period: 30, time: 59)
        XCTAssertEqual(got, "PV9M4")

        // Same through SteamInfo (defaults: SHA1 / 5 digits / period 30).
        let info = try SteamInfo(secret: seedSHA1)
        XCTAssertEqual(try info.getOtp(time: 59), "PV9M4")
        XCTAssertEqual(info.digits, 5)
        XCTAssertEqual(info.period, 30)
        XCTAssertEqual(info.typeId, "steam")
        XCTAssertEqual(info.typeName, "Steam")

        // Output is always 5 chars drawn from the Steam alphabet.
        let alphabet = Set("23456789BCDFGHJKMNPQRTVWXY")
        for t: Int64 in [0, 30, 60, 12345678, 1_600_000_000] {
            let code = try info.getOtp(time: t)
            XCTAssertEqual(code.count, 5)
            XCTAssertTrue(code.allSatisfy { alphabet.contains($0) }, "Steam code \(code) uses only alphabet")
        }
    }

    // MARK: - digits = 10 saturation

    /// digits == 10 uses `(int)Math.pow(10,10)` which saturates to
    /// Integer.MAX_VALUE (2147483647). Since every truncated code is <= 2^31-1,
    /// a 10-digit code preserves the full code. SEED/SHA1/counter 0 truncates to
    /// 1284755224, whose 6/8/9/10-digit renderings verify the modulus per length.
    func testDigits_ModulusMatrix() throws {
        func hotp(_ digits: Int) throws -> String {
            try OTPGen.hotp(secret: seedSHA1, algo: "SHA1", digits: digits, counter: 0)
        }
        // code = 1284755224
        XCTAssertEqual(try hotp(6), "755224")      // % 10^6
        XCTAssertEqual(try hotp(7), "4755224")     // % 10^7
        XCTAssertEqual(try hotp(8), "84755224")    // % 10^8
        XCTAssertEqual(try hotp(9), "284755224")   // % 10^9
        XCTAssertEqual(try hotp(10), "1284755224") // % 2147483647 (saturated) -> full code
    }

    // MARK: - JSON round trips

    func testJson_TotpRoundTrip() throws {
        let info = try TotpInfo(secret: Data([0xDE, 0xAD, 0xBE, 0xEF]), algorithm: "SHA256", digits: 7, period: 45)
        let obj = info.toJson()
        XCTAssertEqual(obj["algo"] as? String, "SHA256")
        XCTAssertEqual(obj["digits"] as? Int, 7)
        XCTAssertEqual(obj["period"] as? Int, 45)
        XCTAssertEqual(obj["secret"] as? String, Base32.encode(Data([0xDE, 0xAD, 0xBE, 0xEF])))

        let back = try OtpInfo.fromJson(type: "totp", obj: obj)
        XCTAssertTrue(back.isEqual(to: info))
        XCTAssertEqual(back.typeId, "totp")
        XCTAssertEqual((back as? TotpInfo)?.period, 45)
    }

    func testJson_HotpRoundTrip() throws {
        let info = try HotpInfo(secret: Data([1, 2, 3, 4]), algorithm: "SHA512", digits: 8, counter: 987654321)
        let obj = info.toJson()
        XCTAssertEqual(obj["counter"] as? Int64, 987654321)
        let back = try OtpInfo.fromJson(type: "hotp", obj: obj)
        XCTAssertTrue(back.isEqual(to: info))
        XCTAssertEqual((back as? HotpInfo)?.counter, 987654321)
    }

    func testJson_SteamRoundTrip() throws {
        let info = try SteamInfo(secret: Data([9, 9, 9]))
        let obj = info.toJson()
        XCTAssertEqual(obj["digits"] as? Int, 5)
        XCTAssertEqual(obj["period"] as? Int, 30)
        let back = try OtpInfo.fromJson(type: "steam", obj: obj)
        XCTAssertEqual(back.typeId, "steam")
        XCTAssertTrue(back.isEqual(to: info))
    }

    func testJson_MotpRoundTrip() throws {
        let info = try MotpInfo(secret: Data([1, 2, 3, 4]), pin: "1234")
        let obj = info.toJson()
        XCTAssertEqual(obj["algo"] as? String, "MD5")
        XCTAssertEqual(obj["pin"] as? String, "1234")
        XCTAssertEqual(obj["period"] as? Int, 10)
        XCTAssertEqual(obj["digits"] as? Int, 6)
        let back = try OtpInfo.fromJson(type: "motp", obj: obj)
        XCTAssertEqual(back.typeId, "motp")
        XCTAssertEqual(back.getAlgorithm(false), "MD5")
        XCTAssertEqual((back as? MotpInfo)?.pin, "1234")
        XCTAssertTrue(back.isEqual(to: info))
    }

    func testJson_YandexRoundTrip() throws {
        let secret = try Base32.decode("LA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI")
        let info = try YandexInfo(secret: secret, pin: "7586")
        let obj = info.toJson()
        XCTAssertEqual(obj["algo"] as? String, "SHA256")
        XCTAssertEqual(obj["digits"] as? Int, 8)
        XCTAssertEqual(obj["period"] as? Int, 30)
        XCTAssertEqual(obj["pin"] as? String, "7586")
        let back = try OtpInfo.fromJson(type: "yandex", obj: obj)
        XCTAssertEqual(back.typeId, "yandex")
        XCTAssertEqual((back as? YandexInfo)?.pin, "7586")
        XCTAssertEqual((back as? YandexInfo)?.secret.count, 16)
        XCTAssertTrue(back.isEqual(to: info))
    }

    // MARK: - MD5 override behavior (§8.8)

    func testMd5Override_MotpKeepsMd5() throws {
        let info = try MotpInfo(secret: Data([1, 2, 3, 4]), pin: "1234")
        let back = try OtpInfo.fromJson(type: "motp", obj: info.toJson())
        XCTAssertEqual(back.getAlgorithm(false), "MD5")
    }

    func testMd5Override_HotpMd5BecomesSha1() throws {
        let info = try HotpInfo(secret: Data([1, 2, 3, 4]))
        try info.setAlgorithm("MD5")
        XCTAssertEqual(info.getAlgorithm(false), "MD5")

        let back = try OtpInfo.fromJson(type: "hotp", obj: info.toJson())
        XCTAssertEqual(back.getAlgorithm(false), "SHA1") // DEFAULT_ALGORITHM
    }

    func testMd5Override_HotpSha256RoundTrips() throws {
        let info = try HotpInfo(secret: Data([1, 2, 3, 4]))
        try info.setAlgorithm("SHA256")
        let back = try OtpInfo.fromJson(type: "hotp", obj: info.toJson())
        XCTAssertEqual(back.getAlgorithm(false), "SHA256")
    }

    // MARK: - Validation

    func testAlgorithm_Validation() throws {
        let info = try TotpInfo(secret: Data([1]))
        // "Hmac" prefix stripped, case-folded to bare name.
        try info.setAlgorithm("HmacSHA1")
        XCTAssertEqual(info.getAlgorithm(false), "SHA1")
        XCTAssertEqual(info.getAlgorithm(true), "HmacSHA1")
        try info.setAlgorithm("sha512")
        XCTAssertEqual(info.getAlgorithm(false), "SHA512")
        XCTAssertThrowsError(try info.setAlgorithm("SHA3"))
        // lowercase "hmac" is NOT stripped (case-sensitive), then invalid.
        XCTAssertThrowsError(try info.setAlgorithm("hmacsha1"))
    }

    func testDigits_Validation() throws {
        let info = try TotpInfo(secret: Data([1]))
        XCTAssertThrowsError(try info.setDigits(0))
        XCTAssertThrowsError(try info.setDigits(11))
        try info.setDigits(1)
        XCTAssertEqual(info.digits, 1)
        try info.setDigits(10)
        XCTAssertEqual(info.digits, 10)
    }

    func testPeriod_Validation() throws {
        let info = try TotpInfo(secret: Data([1]))
        XCTAssertThrowsError(try info.setPeriod(0))
        XCTAssertThrowsError(try info.setPeriod(-1))
        XCTAssertThrowsError(try info.setPeriod(2147484)) // > Integer.MAX_VALUE/1000
        try info.setPeriod(2147483)
        XCTAssertEqual(info.period, 2147483)
    }

    func testCounter_Validation() throws {
        let info = try HotpInfo(secret: Data([1]))
        XCTAssertThrowsError(try info.setCounter(-1))
        try info.setCounter(0)
        info.incrementCounter()
        XCTAssertEqual(info.counter, 1)
    }

    func testMillisTillNextRotation() throws {
        let info = try TotpInfo(secret: Data([1]), algorithm: "SHA1", digits: 6, period: 30)
        // p = 30000; 30000 - (1000 % 30000) = 29000
        XCTAssertEqual(info.millisTillNextRotation(now: 1000), 29000)
        // 30000 - (30000 % 30000) = 30000
        XCTAssertEqual(info.millisTillNextRotation(now: 30000), 30000)
    }

    // MARK: - Empty secret (§8.7)

    func testEmptySecret_Throws() throws {
        XCTAssertThrowsError(try TotpInfo(secret: Data()).getOtp(time: 0))
        XCTAssertThrowsError(try HotpInfo(secret: Data()).getOtp(time: 0))
        XCTAssertThrowsError(try SteamInfo(secret: Data()).getOtp(time: 0))
    }

    func testMissingPin_Throws() throws {
        let motp = try MotpInfo(secret: Data([1, 2, 3, 4]))
        XCTAssertThrowsError(try motp.getOtp(time: 0))
        let yandex = try YandexInfo(secret: Data(repeating: 7, count: 16))
        XCTAssertThrowsError(try yandex.getOtp(time: 0))
    }

    // MARK: - Equality semantics

    func testEquality() throws {
        let a = try TotpInfo(secret: Data([1, 2, 3]), algorithm: "SHA1", digits: 6, period: 30)
        let b = try TotpInfo(secret: Data([1, 2, 3]), algorithm: "SHA1", digits: 6, period: 30)
        XCTAssertTrue(a.isEqual(to: b))

        let differentPeriod = try TotpInfo(secret: Data([1, 2, 3]), algorithm: "SHA1", digits: 6, period: 60)
        XCTAssertFalse(a.isEqual(to: differentPeriod))

        // Same fields but a different type id -> not equal.
        let steam = try SteamInfo(secret: Data([1, 2, 3]), algorithm: "SHA1", digits: 6, period: 30)
        XCTAssertFalse(a.isEqual(to: steam))
        XCTAssertFalse(steam.isEqual(to: a))

        // HOTP counter distinguishes.
        let h1 = try HotpInfo(secret: Data([1]), algorithm: "SHA1", digits: 6, counter: 5)
        let h2 = try HotpInfo(secret: Data([1]), algorithm: "SHA1", digits: 6, counter: 6)
        XCTAssertFalse(h1.isEqual(to: h2))

        // MOTP pin distinguishes.
        let m1 = try MotpInfo(secret: Data([1]), pin: "1111")
        let m2 = try MotpInfo(secret: Data([1]), pin: "2222")
        XCTAssertFalse(m1.isEqual(to: m2))
        XCTAssertTrue(m1.isEqual(to: try MotpInfo(secret: Data([1]), pin: "1111")))
    }

    // MARK: - Type ids / names

    func testTypeIdsAndNames() throws {
        XCTAssertEqual(try TotpInfo(secret: Data([1])).typeId, "totp")
        XCTAssertEqual(try TotpInfo(secret: Data([1])).typeName, "TOTP")
        XCTAssertEqual(try HotpInfo(secret: Data([1])).typeId, "hotp")
        XCTAssertEqual(try HotpInfo(secret: Data([1])).typeName, "HOTP")
        XCTAssertEqual(try SteamInfo(secret: Data([1])).typeName, "Steam")
        XCTAssertEqual(try MotpInfo(secret: Data([1])).typeId, "motp")
        XCTAssertEqual(try MotpInfo(secret: Data([1])).typeName, "MOTP")
        XCTAssertEqual(try YandexInfo(secret: Data(repeating: 7, count: 16)).typeName, "Yandex")
    }
}

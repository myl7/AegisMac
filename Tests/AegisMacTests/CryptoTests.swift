import XCTest
@testable import AegisMac

final class CryptoTests: XCTestCase {

    // MARK: - Base32 (RFC 4648)

    // RFC 4648 §10 test vectors for "foobar".
    func testBase32EncodeNoPadding() {
        XCTAssertEqual(Base32.encode(Data("".utf8)), "")
        XCTAssertEqual(Base32.encode(Data("f".utf8)), "MY")
        XCTAssertEqual(Base32.encode(Data("fo".utf8)), "MZXQ")
        XCTAssertEqual(Base32.encode(Data("foo".utf8)), "MZXW6")
        XCTAssertEqual(Base32.encode(Data("foob".utf8)), "MZXW6YQ")
        XCTAssertEqual(Base32.encode(Data("fooba".utf8)), "MZXW6YTB")
        XCTAssertEqual(Base32.encode(Data("foobar".utf8)), "MZXW6YTBOI")
    }

    func testBase32DecodeUnpadded() throws {
        XCTAssertEqual(try Base32.decode("MY"), Data("f".utf8))
        XCTAssertEqual(try Base32.decode("MZXQ"), Data("fo".utf8))
        XCTAssertEqual(try Base32.decode("MZXW6"), Data("foo".utf8))
        XCTAssertEqual(try Base32.decode("MZXW6YQ"), Data("foob".utf8))
        XCTAssertEqual(try Base32.decode("MZXW6YTB"), Data("fooba".utf8))
        XCTAssertEqual(try Base32.decode("MZXW6YTBOI"), Data("foobar".utf8))
    }

    func testBase32DecodePadded() throws {
        // Same values, padded to 8-char groups.
        XCTAssertEqual(try Base32.decode("MY======"), Data("f".utf8))
        XCTAssertEqual(try Base32.decode("MZXQ===="), Data("fo".utf8))
        XCTAssertEqual(try Base32.decode("MZXW6==="), Data("foo".utf8))
        XCTAssertEqual(try Base32.decode("MZXW6YQ="), Data("foob".utf8))
        XCTAssertEqual(try Base32.decode("MZXW6YTBOI======"), Data("foobar".utf8))
    }

    func testBase32DecodeUppercasesInput() throws {
        // Lowercase input must be accepted (Aegis uppercases first).
        XCTAssertEqual(try Base32.decode("mzxw6ytboi"), Data("foobar".utf8))
        XCTAssertEqual(try Base32.decode("mzxw6==="), Data("foo".utf8))
    }

    func testBase32RealSecretRoundTrip() throws {
        // A real Aegis OTP secret (from the canonical vectors), 26 chars, unpadded.
        let secret = "4SJHB4GSD43FZBAI7C2HLRJGPQ"
        let decoded = try Base32.decode(secret)
        XCTAssertEqual(decoded.count, 16)
        XCTAssertEqual(Base32.encode(decoded), secret)
    }

    func testBase32InvalidCharacterThrows() {
        // '0', '1', '8', '9' are not in the RFC 4648 base32 alphabet.
        XCTAssertThrowsError(try Base32.decode("01890000")) { assertEncoding($0) }
        XCTAssertThrowsError(try Base32.decode("MZXW6YT@")) { assertEncoding($0) }
    }

    func testBase32InvalidLengthThrows() {
        // Lengths whose count % 8 is 1, 3, or 6 are impossible base32 quanta.
        XCTAssertThrowsError(try Base32.decode("A")) { assertEncoding($0) }       // 1
        XCTAssertThrowsError(try Base32.decode("MZX")) { assertEncoding($0) }     // 3
        XCTAssertThrowsError(try Base32.decode("MZXW6Y")) { assertEncoding($0) }  // 6
    }

    // MARK: - Hex / Base16

    func testHexEncodeLowercase() {
        XCTAssertEqual(HexCodec.encode(Data([0x00, 0xFF, 0xAB, 0x10])), "00ffab10")
        XCTAssertEqual(HexCodec.encode(Data()), "")
        XCTAssertEqual(HexCodec.encode(Data([0xDE, 0xAD, 0xBE, 0xEF])), "deadbeef")
    }

    func testHexDecodeCaseInsensitive() throws {
        XCTAssertEqual(try HexCodec.decode("00ffab10"), Data([0x00, 0xFF, 0xAB, 0x10]))
        XCTAssertEqual(try HexCodec.decode("00FFAB10"), Data([0x00, 0xFF, 0xAB, 0x10]))
        XCTAssertEqual(try HexCodec.decode("00FfAb10"), Data([0x00, 0xFF, 0xAB, 0x10]))
        XCTAssertEqual(try HexCodec.decode("DeAdBeEf"), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testHexOddLengthThrows() {
        XCTAssertThrowsError(try HexCodec.decode("abc")) { assertEncoding($0) }
        XCTAssertThrowsError(try HexCodec.decode("f")) { assertEncoding($0) }
    }

    func testHexInvalidCharacterThrows() {
        XCTAssertThrowsError(try HexCodec.decode("gg")) { assertEncoding($0) }
        XCTAssertThrowsError(try HexCodec.decode("00zz")) { assertEncoding($0) }
    }

    // MARK: - scrypt (RFC 7914)

    /// RFC 7914 §12: scrypt(P="pleaseletmein", S="SodiumChloride", N=16384, r=8, p=1,
    /// dkLen=64). Our `deriveKey` produces dkLen=32; since scrypt's final PBKDF2 step
    /// uses 1 iteration, the 32-byte output is exactly the first 32 bytes of the
    /// 64-byte reference output.
    func testScryptRFC7914Vector() throws {
        let params = ScryptParameters(n: 16384, r: 8, p: 1, salt: Data("SodiumChloride".utf8))
        let key = try CryptoUtils.deriveKey(password: Array("pleaseletmein".utf8), params: params)
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(HexCodec.encode(key),
                       "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2")
    }

    /// RFC 7914 §12 largest vector (N=1048576) is intentionally skipped: it needs
    /// ~1 GiB of memory and is far too slow for a unit test.
    func testScryptRFC7914LargeVectorSkipped() throws {
        throw XCTSkip("N=1048576 scrypt vector is too slow/memory-heavy for unit tests")
    }

    // MARK: - AES-256-GCM

    func testGCMRoundTrip() throws {
        let key = CryptoUtils.randomBytes(32)
        let plain = Data("the quick brown fox jumps over the lazy dog".utf8)

        let (cipherText, params) = try CryptoUtils.encrypt(plain, key: key)
        let decrypted = try CryptoUtils.decrypt(cipherText, key: key, params: params)
        XCTAssertEqual(decrypted, plain)
    }

    func testGCMTagAndCiphertextFormat() throws {
        let key = CryptoUtils.randomBytes(32)
        // Use an odd length to prove ciphertext length == plaintext length (stream cipher).
        let plain = CryptoUtils.randomBytes(37)

        let (cipherText, params) = try CryptoUtils.encrypt(plain, key: key)
        XCTAssertEqual(cipherText.count, plain.count, "GCM ciphertext length must equal plaintext length")
        XCTAssertEqual(params.tag.count, 16, "GCM tag must be 16 bytes")
        XCTAssertEqual(params.nonce.count, 12, "GCM nonce must be 12 bytes")
    }

    func testGCMEncryptGeneratesFreshNonce() throws {
        let key = CryptoUtils.randomBytes(32)
        let plain = Data("same plaintext".utf8)
        let (_, params1) = try CryptoUtils.encrypt(plain, key: key)
        let (_, params2) = try CryptoUtils.encrypt(plain, key: key)
        XCTAssertNotEqual(params1.nonce, params2.nonce, "each encryption must use a fresh nonce")
    }

    func testGCMWrongKeyFailsAuthentication() throws {
        let key = CryptoUtils.randomBytes(32)
        let wrongKey = CryptoUtils.randomBytes(32)
        let plain = Data("secret data".utf8)

        let (cipherText, params) = try CryptoUtils.encrypt(plain, key: key)
        XCTAssertThrowsError(try CryptoUtils.decrypt(cipherText, key: wrongKey, params: params)) {
            assertCrypto($0)
        }
    }

    func testGCMTamperedTagFailsAuthentication() throws {
        let key = CryptoUtils.randomBytes(32)
        let plain = Data("secret data".utf8)
        let (cipherText, params) = try CryptoUtils.encrypt(plain, key: key)

        var tag = params.tag
        tag[0] ^= 0xFF
        let tampered = CryptParameters(nonce: params.nonce, tag: tag)
        XCTAssertThrowsError(try CryptoUtils.decrypt(cipherText, key: key, params: tampered)) {
            assertCrypto($0)
        }
    }

    // MARK: - CryptParameters JSON

    func testCryptParametersRoundTrip() throws {
        let nonce = try HexCodec.decode("e9705513ba4951fa7a0608d2")
        let tag = try HexCodec.decode("931237af257b83c693ddb8f9a7eddaf0")
        let params = CryptParameters(nonce: nonce, tag: tag)

        let json = params.toJson()
        XCTAssertEqual(json["nonce"] as? String, "e9705513ba4951fa7a0608d2")
        XCTAssertEqual(json["tag"] as? String, "931237af257b83c693ddb8f9a7eddaf0")

        let reparsed = try CryptParameters.fromJson(json)
        XCTAssertEqual(reparsed.nonce, nonce)
        XCTAssertEqual(reparsed.tag, tag)
    }

    // MARK: - MasterKey

    func testMasterKeyRoundTrip() throws {
        let masterKey = MasterKey.generate()
        XCTAssertEqual(masterKey.bytes.count, 32)

        let plain = Data("db payload bytes".utf8)
        let (cipherText, params) = try masterKey.encrypt(plain)
        let decrypted = try masterKey.decrypt(cipherText, params: params)
        XCTAssertEqual(decrypted, plain)
    }

    // MARK: - Slots

    /// The real password slot from `aegis_encrypted.json` (password `test`).
    private func fixturePasswordSlotJson() -> JSONObject {
        return [
            "type": 1,
            "uuid": "a8325752-c1be-458a-9b3e-5e0a8154d9ec",
            "key": "491d44550430ba248986b904b8cffd3a6c5755d176ac877bd11b82c934225017",
            "key_params": [
                "nonce": "e9705513ba4951fa7a0608d2",
                "tag": "931237af257b83c693ddb8f9a7eddaf0"
            ],
            "n": 32768,
            "r": 8,
            "p": 1,
            "salt": "27ea9ae53fa2f08a8dcd201615a8229422647b3058f9f36b08f9457e62888be1",
            "repaired": true
        ]
    }

    func testPasswordSlotJsonRoundTrip() throws {
        let obj = fixturePasswordSlotJson()
        let slot = try Slot.fromJson(obj)

        guard let pw = slot as? PasswordSlot else {
            return XCTFail("expected a PasswordSlot, got \(slot.type)")
        }
        XCTAssertEqual(pw.type, .password)
        XCTAssertEqual(pw.uuid.uuidString.lowercased(), "a8325752-c1be-458a-9b3e-5e0a8154d9ec")
        XCTAssertEqual(HexCodec.encode(pw.encryptedMasterKey),
                       "491d44550430ba248986b904b8cffd3a6c5755d176ac877bd11b82c934225017")
        XCTAssertEqual(pw.encryptedMasterKey.count, 32)
        XCTAssertEqual(HexCodec.encode(pw.keyParams.nonce), "e9705513ba4951fa7a0608d2")
        XCTAssertEqual(HexCodec.encode(pw.keyParams.tag), "931237af257b83c693ddb8f9a7eddaf0")
        XCTAssertEqual(pw.scryptParams.n, 32768)
        XCTAssertEqual(pw.scryptParams.r, 8)
        XCTAssertEqual(pw.scryptParams.p, 1)
        XCTAssertEqual(HexCodec.encode(pw.scryptParams.salt),
                       "27ea9ae53fa2f08a8dcd201615a8229422647b3058f9f36b08f9457e62888be1")
        XCTAssertTrue(pw.repaired)
        XCTAssertFalse(pw.isBackup, "is_backup absent -> default false")

        // Re-serialize and verify every field is preserved exactly.
        let out = pw.toJson()
        XCTAssertEqual(out["type"] as? Int, 1)
        XCTAssertEqual(out["uuid"] as? String, "a8325752-c1be-458a-9b3e-5e0a8154d9ec")
        XCTAssertEqual(out["key"] as? String,
                       "491d44550430ba248986b904b8cffd3a6c5755d176ac877bd11b82c934225017")
        XCTAssertEqual(out["n"] as? Int, 32768)
        XCTAssertEqual(out["r"] as? Int, 8)
        XCTAssertEqual(out["p"] as? Int, 1)
        XCTAssertEqual(out["salt"] as? String,
                       "27ea9ae53fa2f08a8dcd201615a8229422647b3058f9f36b08f9457e62888be1")
        XCTAssertEqual(out["repaired"] as? Bool, true)
        XCTAssertEqual(out["is_backup"] as? Bool, false)
        let outParams = out["key_params"] as? JSONObject
        XCTAssertEqual(outParams?["nonce"] as? String, "e9705513ba4951fa7a0608d2")
        XCTAssertEqual(outParams?["tag"] as? String, "931237af257b83c693ddb8f9a7eddaf0")
    }

    func testUnknownSlotTypeThrows() {
        let obj: JSONObject = [
            "type": 7,
            "uuid": "a8325752-c1be-458a-9b3e-5e0a8154d9ec",
            "key": "491d44550430ba248986b904b8cffd3a6c5755d176ac877bd11b82c934225017",
            "key_params": [
                "nonce": "e9705513ba4951fa7a0608d2",
                "tag": "931237af257b83c693ddb8f9a7eddaf0"
            ]
        ]
        XCTAssertThrowsError(try Slot.fromJson(obj)) { error in
            assertCrypto(error)
            XCTAssertEqual((error as? AegisError)?.errorDescription, "unrecognized slot type")
        }
    }

    func testRawAndBiometricSlotRoundTrip() throws {
        let common: JSONObject = [
            "uuid": "c4d5e6f7-a8b9-4c0d-8e1f-2a3b4c5d6e7f",
            "key": "77aabb00112233445566778899aabbcc00112233445566778899aabbccddeeff",
            "key_params": [
                "nonce": "aabbccddeeff001122334455",
                "tag": "00ffeeddccbbaa998877665544332211"
            ]
        ]

        var rawObj = common
        rawObj["type"] = 0
        let raw = try Slot.fromJson(rawObj)
        XCTAssertTrue(raw is RawSlot)
        XCTAssertEqual(raw.type, .raw)
        XCTAssertEqual(raw.toJson()["type"] as? Int, 0)

        var bioObj = common
        bioObj["type"] = 2
        let bio = try Slot.fromJson(bioObj)
        XCTAssertTrue(bio is BiometricSlot)
        XCTAssertEqual(bio.type, .biometric)
        XCTAssertEqual(bio.toJson()["type"] as? Int, 2)
    }

    func testSlotUnlockRoundTrip() throws {
        // Create a master key, wrap it in a fresh password slot, unlock it back.
        let masterKey = MasterKey.generate()
        let slot = try PasswordSlot.create(password: "hunter2", masterKey: masterKey)
        XCTAssertTrue(slot.repaired)
        XCTAssertEqual(slot.encryptedMasterKey.count, 32)

        let list = SlotList(slots: [slot])
        let unlocked = try list.unlock(password: "hunter2")
        XCTAssertEqual(unlocked.bytes, masterKey.bytes)
    }

    func testSlotUnlockWrongPasswordThrows() throws {
        let masterKey = MasterKey.generate()
        let slot = try PasswordSlot.create(password: "correct horse", masterKey: masterKey)
        let list = SlotList(slots: [slot])
        XCTAssertThrowsError(try list.unlock(password: "wrong password")) { error in
            assertCrypto(error)
            XCTAssertEqual((error as? AegisError)?.errorDescription, "unlock failed")
        }
    }

    /// End-to-end validation against real Android output: derive the scrypt key from
    /// password `test` with the fixture slot's stored N=32768 params and confirm the
    /// GCM-wrapped master key unwraps (i.e. scrypt + GCM match the Java implementation).
    func testFixtureSlotUnlocksWithRealPassword() throws {
        let slot = try Slot.fromJson(fixturePasswordSlotJson())
        let list = SlotList(slots: [slot])

        let masterKey = try list.unlock(password: "test")
        XCTAssertEqual(masterKey.bytes.count, 32)

        XCTAssertThrowsError(try list.unlock(password: "wrong")) { assertCrypto($0) }
    }

    func testSlotListJsonRoundTripAndPasswordSlotLookup() throws {
        let arr: [Any] = [fixturePasswordSlotJson()]
        let list = try SlotList.fromJson(arr)
        XCTAssertEqual(list.slots.count, 1)
        XCTAssertEqual(list.findPasswordSlots().count, 1)

        let json = list.toJson()
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json[0]["type"] as? Int, 1)
    }

    // MARK: - SlotList.exportable

    func testExportableDropsBiometricSlots() throws {
        let mk = MasterKey.generate()
        let pw = try PasswordSlot.create(password: "pw", masterKey: mk)
        let bio = BiometricSlot(uuid: UUID(),
                                encryptedMasterKey: CryptoUtils.randomBytes(32),
                                keyParams: CryptParameters(nonce: CryptoUtils.randomBytes(12),
                                                           tag: CryptoUtils.randomBytes(16)))
        let list = SlotList(slots: [pw, bio])
        let exportable = list.exportable()
        XCTAssertEqual(exportable.slots.count, 1)
        XCTAssertTrue(exportable.slots.first is PasswordSlot)
    }

    func testExportableDropsRegularPasswordSlotsWhenBackupExists() throws {
        let mk = MasterKey.generate()
        let regular = try PasswordSlot.create(password: "pw", masterKey: mk, isBackup: false)
        let backup = try PasswordSlot.create(password: "backup", masterKey: mk, isBackup: true)
        let list = SlotList(slots: [regular, backup])

        let exportable = list.exportable()
        XCTAssertEqual(exportable.slots.count, 1)
        XCTAssertEqual((exportable.slots.first as? PasswordSlot)?.isBackup, true)
    }

    func testExportableKeepsRegularPasswordSlotsWhenNoBackup() throws {
        let mk = MasterKey.generate()
        let regular = try PasswordSlot.create(password: "pw", masterKey: mk, isBackup: false)
        let list = SlotList(slots: [regular])
        XCTAssertEqual(list.exportable().slots.count, 1)
    }

    // MARK: - Helpers

    private func assertEncoding(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case AegisError.encoding = error else {
            XCTFail("expected AegisError.encoding, got \(error)", file: file, line: line)
            return
        }
    }

    private func assertCrypto(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case AegisError.crypto = error else {
            XCTFail("expected AegisError.crypto, got \(error)", file: file, line: line)
            return
        }
    }
}

import XCTest
import CryptoKit
@testable import AegisMac

/// Import/export tests: `otpauth://` URI parse + serialize round-trips, Google
/// Authenticator `otpauth-migration://` protobuf decode, and Aegis vault-file
/// import (plaintext + encrypted). URIs and expected fields come from the
/// importer fixtures and otp-algorithms/import-export specs (§7, §8, §12).
final class ImportTests: XCTestCase {

    // MARK: - Fixtures

    private func fixtureText(_ name: String, ext: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            XCTFail("Missing fixture: \(name).\(ext)")
            throw AegisError.importError("missing fixture \(name).\(ext)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fixtureData(_ name: String, ext: String = "json") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            XCTFail("Missing fixture: \(name).\(ext)")
            throw AegisError.importError("missing fixture \(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Plain otpauth URI parsing (fixture uris_plain.txt)

    func testParseAllFixtureUris() throws {
        let text = try fixtureText("uris_plain", ext: "txt")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 7, "fixture has 7 URI lines")

        let infos = try lines.map { try GoogleAuthInfo.parseUri($0) }
        XCTAssertEqual(infos.count, 7)

        // §12 canonical vectors (the first 7).
        // 1. totp Deno / Mason
        XCTAssertEqual(infos[0].issuer, "Deno")
        XCTAssertEqual(infos[0].accountName, "Mason")
        XCTAssertEqual(infos[0].info.typeId, "totp")
        XCTAssertEqual(infos[0].info.getAlgorithm(false), "SHA1")
        XCTAssertEqual(infos[0].info.digits, 6)
        XCTAssertEqual((infos[0].info as? TotpInfo)?.period, 30)
        XCTAssertEqual(Base32.encode(infos[0].info.secret), "4SJHB4GSD43FZBAI7C2HLRJGPQ")

        // 2. totp SPDX / James — digits=7 accepted, SHA256, period 20
        XCTAssertEqual(infos[1].info.digits, 7)
        XCTAssertEqual(infos[1].info.getAlgorithm(false), "SHA256")
        XCTAssertEqual((infos[1].info as? TotpInfo)?.period, 20)

        // 3. totp Airbnb / Elijah — SHA512, digits 8, period 50
        XCTAssertEqual(infos[2].info.getAlgorithm(false), "SHA512")
        XCTAssertEqual(infos[2].info.digits, 8)
        XCTAssertEqual((infos[2].info as? TotpInfo)?.period, 50)

        // 4. hotp Issuu / James — counter 1
        XCTAssertEqual(infos[3].info.typeId, "hotp")
        XCTAssertEqual((infos[3].info as? HotpInfo)?.counter, 1)

        // 5. hotp Air Canada / Benjamin — %20 in label, '+' in query; counter 50, digits 7
        XCTAssertEqual(infos[4].issuer, "Air Canada", "percent-encoded label decodes to space")
        XCTAssertEqual(infos[4].accountName, "Benjamin")
        XCTAssertEqual((infos[4].info as? HotpInfo)?.counter, 50)
        XCTAssertEqual(infos[4].info.digits, 7)

        // 6. hotp WWE / Mason — counter 10300
        XCTAssertEqual((infos[5].info as? HotpInfo)?.counter, 10300)

        // 7. steam Boeing / Sophia — digits 5
        XCTAssertEqual(infos[6].info.typeId, "steam")
        XCTAssertEqual(infos[6].info.digits, 5)
        XCTAssertEqual(infos[6].issuer, "Boeing")
    }

    // MARK: - Query decoding quirks

    func testPlusDecodesToSpaceInQuery() throws {
        // No colon in the label, so the issuer comes from the (percent-decoded) query param.
        let info = try GoogleAuthInfo.parseUri(
            "otpauth://totp/Benjamin?secret=KUVJJOM753IHTNDSZVCNKL7GII&issuer=Air+Canada")
        XCTAssertEqual(info.issuer, "Air Canada", "'+' -> space in query params (Android convertPlus)")
        XCTAssertEqual(info.accountName, "Benjamin")
    }

    func testEncodedPlusDecodesToLiteralPlus() throws {
        let info = try GoogleAuthInfo.parseUri(
            "otpauth://totp/acct?secret=KUVJJOM753IHTNDSZVCNKL7GII&issuer=A%2BB")
        XCTAssertEqual(info.issuer, "A+B", "%2B -> literal '+'")
    }

    func testAlgorithmParamNameVsAlgo() throws {
        // 'algo=' is NOT a recognized override; the default (SHA1) stays.
        let wrong = try GoogleAuthInfo.parseUri(
            "otpauth://totp/x:y?secret=JBSWY3DPEHPK3PXP&algo=SHA256")
        XCTAssertEqual(wrong.info.getAlgorithm(false), "SHA1")

        // 'algorithm=' is recognized and uppercased.
        let right = try GoogleAuthInfo.parseUri(
            "otpauth://totp/x:y?secret=JBSWY3DPEHPK3PXP&algorithm=sha512")
        XCTAssertEqual(right.info.getAlgorithm(false), "SHA512")
    }

    func testLabelSplitSemantics() throws {
        // Trailing colon -> Java split drops it -> 1 part -> whole label as account name.
        XCTAssertEqual(
            try GoogleAuthInfo.parseUri("otpauth://totp/Issuer:?secret=JBSWY3DPEHPK3PXP").accountName,
            "Issuer:")
        // Leading colon -> ["", "Name"] -> empty issuer, account "Name".
        let leading = try GoogleAuthInfo.parseUri("otpauth://totp/:Name?secret=JBSWY3DPEHPK3PXP")
        XCTAssertEqual(leading.issuer, "")
        XCTAssertEqual(leading.accountName, "Name")
        // Two colons -> 3 parts -> whole label as account name.
        XCTAssertEqual(
            try GoogleAuthInfo.parseUri("otpauth://totp/a:b:c?secret=JBSWY3DPEHPK3PXP").accountName,
            "a:b:c")
    }

    // MARK: - URI round-trip

    func testUriRoundTrip() throws {
        let text = try fixtureText("uris_plain", ext: "txt")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            let orig = try GoogleAuthInfo.parseUri(line)
            let reparsed = try GoogleAuthInfo.parseUri(orig.getUri())
            XCTAssertTrue(orig.info.isEqual(to: reparsed.info),
                          "info round-trip for \(orig.getUri())")
            XCTAssertEqual(orig.accountName, reparsed.accountName)
            XCTAssertEqual(orig.issuer, reparsed.issuer)
        }
    }

    // MARK: - MOTP

    func testMotpUriHexSecret() throws {
        // motp scheme: secret is hex (not base32). "48656c6c6f21" == "Hello!".
        let info = try GoogleAuthInfo.parseUri("motp://host/GitHub:alice?secret=48656c6c6f21")
        XCTAssertEqual(info.info.typeId, "motp")
        XCTAssertEqual(info.info.secret, Data("Hello!".utf8))
        XCTAssertEqual(info.issuer, "GitHub")
        XCTAssertEqual(info.accountName, "alice")

        // getUri re-emits the secret as lowercase hex under the motp scheme.
        let out = info.getUri()
        XCTAssertTrue(out.hasPrefix("motp:"))
        XCTAssertTrue(out.contains("secret=48656c6c6f21"), "motp getUri hex secret: \(out)")
        let reparsed = try GoogleAuthInfo.parseUri(out)
        XCTAssertEqual(reparsed.info.secret, Data("Hello!".utf8))
        XCTAssertEqual(reparsed.issuer, "GitHub")
    }

    // MARK: - Yandex

    func testYandexPinAndSecret() throws {
        // 26-byte secret (valid checksum) is truncated to 16; pin param is base32(utf8(pin)).
        let secretB32 = "LA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI"
        let pinEncoded = Base32.encode(Data("7586".utf8))
        let uri = "otpauth://yaotp/myaccount?secret=\(secretB32)&pin=\(pinEncoded)"

        let info = try GoogleAuthInfo.parseUri(uri)
        XCTAssertEqual(info.info.typeId, "yandex")
        XCTAssertEqual(info.issuer, "Yandex", "yaotp presets issuer to Yandex")
        XCTAssertEqual(info.accountName, "myaccount")
        XCTAssertEqual((info.info as? YandexInfo)?.pin, "7586", "pin param base32-decoded to UTF-8")
        XCTAssertEqual(info.info.secret.count, 16, "26-byte Yandex secret truncated to 16")

        // End-to-end generation vector (spec §8.4).
        XCTAssertEqual(try info.info.getOtp(time: 1581064020), "oactmacq")

        // Round-trip preserves pin/secret/issuer/name.
        let reparsed = try GoogleAuthInfo.parseUri(info.getUri())
        XCTAssertTrue(info.info.isEqual(to: reparsed.info))
        XCTAssertEqual(reparsed.issuer, "Yandex")
        XCTAssertEqual(reparsed.accountName, "myaccount")
    }

    func testYandexLabelOverridesPresetIssuer() throws {
        // A two-part colon label overrides the Yandex-preset issuer.
        let secretB32 = "LA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI"
        let info = try GoogleAuthInfo.parseUri(
            "otpauth://yaotp/MyBank:alice?secret=\(secretB32)")
        XCTAssertEqual(info.issuer, "MyBank")
        XCTAssertEqual(info.accountName, "alice")
    }

    // MARK: - Google migration protobuf

    func testMigrationRoundTrip() throws {
        // Entry A: TOTP, SHA1, 6 digits, name "alice", issuer "Example".
        let otpA = ProtoBuilder.lenField(1, Array("Hello".utf8))
            + ProtoBuilder.strField(2, "alice")
            + ProtoBuilder.strField(3, "Example")
            + ProtoBuilder.varField(4, 1)   // ALGORITHM_SHA1
            + ProtoBuilder.varField(5, 1)   // DIGIT_COUNT_SIX
            + ProtoBuilder.varField(6, 2)   // OTP_TYPE_TOTP

        // Entry B: HOTP, SHA256, 8 digits, counter 42, name "Bob:bob@x.com", empty issuer.
        let otpB = ProtoBuilder.lenField(1, [1, 2, 3, 4])
            + ProtoBuilder.strField(2, "Bob:bob@x.com")
            + ProtoBuilder.strField(3, "")
            + ProtoBuilder.varField(4, 2)   // ALGORITHM_SHA256
            + ProtoBuilder.varField(5, 2)   // DIGIT_COUNT_EIGHT
            + ProtoBuilder.varField(6, 1)   // OTP_TYPE_HOTP
            + ProtoBuilder.varField(7, 42)  // counter

        let payload = ProtoBuilder.lenField(1, otpA)
            + ProtoBuilder.lenField(1, otpB)
            + ProtoBuilder.varField(2, 1)        // version
            + ProtoBuilder.varField(3, 1)        // batch_size
            + ProtoBuilder.varField(4, 0)        // batch_index
            + ProtoBuilder.varField(5, 12345)    // batch_id

        let uri = ProtoBuilder.migrationUri(payload)
        let infos = try GoogleAuthMigration.parse(uri: uri)
        XCTAssertEqual(infos.count, 2)

        XCTAssertEqual(infos[0].info.typeId, "totp")
        XCTAssertEqual(infos[0].info.secret, Data("Hello".utf8))
        XCTAssertEqual(infos[0].accountName, "alice")
        XCTAssertEqual(infos[0].issuer, "Example")
        XCTAssertEqual(infos[0].info.getAlgorithm(false), "SHA1")
        XCTAssertEqual(infos[0].info.digits, 6)
        XCTAssertEqual((infos[0].info as? TotpInfo)?.period, 30, "migration forces period 30")

        XCTAssertEqual(infos[1].info.typeId, "hotp")
        XCTAssertEqual(infos[1].info.secret, Data([1, 2, 3, 4]))
        XCTAssertEqual(infos[1].issuer, "Bob", "empty issuer + name colon -> split at first ':'")
        XCTAssertEqual(infos[1].accountName, "bob@x.com")
        XCTAssertEqual(infos[1].info.getAlgorithm(false), "SHA256")
        XCTAssertEqual(infos[1].info.digits, 8)
        XCTAssertEqual((infos[1].info as? HotpInfo)?.counter, 42)
    }

    func testMigrationUnspecifiedDefaults() throws {
        // Only secret + name set; algorithm/digits/type unspecified -> SHA1/6/TOTP.
        let otp = ProtoBuilder.lenField(1, Array("Hello".utf8))
            + ProtoBuilder.strField(2, "acct")
        let payload = ProtoBuilder.lenField(1, otp) + ProtoBuilder.varField(2, 1)
        let infos = try GoogleAuthMigration.parse(uri: ProtoBuilder.migrationUri(payload))
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].info.typeId, "totp")
        XCTAssertEqual(infos[0].info.getAlgorithm(false), "SHA1")
        XCTAssertEqual(infos[0].info.digits, 6)
    }

    func testMigrationErrors() throws {
        // MD5 (algorithm enum 4) is rejected on import.
        let md5 = ProtoBuilder.lenField(1, Array("Hello".utf8))
            + ProtoBuilder.strField(2, "x")
            + ProtoBuilder.varField(4, 4) + ProtoBuilder.varField(5, 1) + ProtoBuilder.varField(6, 2)
        XCTAssertThrowsError(try GoogleAuthMigration.parse(
            uri: ProtoBuilder.migrationUri(ProtoBuilder.lenField(1, md5))))

        // Empty secret is rejected.
        let empty = ProtoBuilder.lenField(1, [])
            + ProtoBuilder.strField(2, "x")
            + ProtoBuilder.varField(4, 1) + ProtoBuilder.varField(5, 1) + ProtoBuilder.varField(6, 2)
        XCTAssertThrowsError(try GoogleAuthMigration.parse(
            uri: ProtoBuilder.migrationUri(ProtoBuilder.lenField(1, empty))))

        // Wrong scheme / host / missing data.
        XCTAssertThrowsError(try GoogleAuthMigration.parse(uri: "otpauth://offline?data=AA"))
        XCTAssertThrowsError(try GoogleAuthMigration.parse(uri: "otpauth-migration://online?data=AA"))
        XCTAssertThrowsError(try GoogleAuthMigration.parse(uri: "otpauth-migration://offline"))
    }

    // MARK: - parseUri error cases

    func testParseUriErrors() {
        XCTAssertThrowsError(try GoogleAuthInfo.parseUri("otpauth://totp/x:y?issuer=z"),
                             "missing secret")
        XCTAssertThrowsError(try GoogleAuthInfo.parseUri("otpauth://totp/x:y?secret="),
                             "empty secret")
        XCTAssertThrowsError(try GoogleAuthInfo.parseUri("otpauth://hotp/x:y?secret=JBSWY3DPEHPK3PXP"),
                             "hotp missing counter")
        XCTAssertThrowsError(try GoogleAuthInfo.parseUri("http://totp/x:y?secret=JBSWY3DPEHPK3PXP"),
                             "bad scheme")
        XCTAssertThrowsError(try GoogleAuthInfo.parseUri("otpauth://frob/x:y?secret=JBSWY3DPEHPK3PXP"),
                             "unknown type")
    }

    func testSecretAAParsesToOneByte() throws {
        // §8.7: secret "AA" base32-decodes to a single byte; 'algo=' is ignored.
        let info = try GoogleAuthInfo.parseUri(
            "otpauth://totp/test:test?secret=AA&algo=SHA1&digits=6&period=30")
        XCTAssertEqual(info.info.secret.count, 1)
        XCTAssertEqual(info.info.getAlgorithm(false), "SHA1")
    }

    // MARK: - ImportExport (URI list)

    func testImportUriListFromFixture() throws {
        let text = try fixtureText("uris_plain", ext: "txt")
        let entries = try ImportExport.importUriList(text: text)
        XCTAssertEqual(entries.count, 7)
        XCTAssertEqual(entries[0].name, "Mason")
        XCTAssertEqual(entries[0].issuer, "Deno")
        XCTAssertEqual(entries[4].issuer, "Air Canada")
        XCTAssertEqual(entries[4].name, "Benjamin")
    }

    func testImportUriListSkipsBlankLinesAndThrowsOnBad() throws {
        let good = "otpauth://totp/A:a?secret=JBSWY3DPEHPK3PXP\n\n   \notpauth://totp/B:b?secret=JBSWY3DPEHPK3PXP\n"
        let entries = try ImportExport.importUriList(text: good)
        XCTAssertEqual(entries.count, 2)

        let bad = "otpauth://totp/A:a?secret=JBSWY3DPEHPK3PXP\nnot-a-uri"
        XCTAssertThrowsError(try ImportExport.importUriList(text: bad))
    }

    func testExportUriListRoundTrip() throws {
        let text = try fixtureText("uris_plain", ext: "txt")
        let entries = try ImportExport.importUriList(text: text)
        let exported = ImportExport.exportUriList(entries: entries)
        let reimported = try ImportExport.importUriList(text: exported)
        XCTAssertEqual(reimported.count, entries.count)
        for (a, b) in zip(entries, reimported) {
            XCTAssertEqual(a.name, b.name)
            XCTAssertEqual(a.issuer, b.issuer)
            XCTAssertTrue(a.info.isEqual(to: b.info), "exported entry info matches: \(a.issuer)/\(a.name)")
        }
    }

    func testToVaultEntry() throws {
        let info = try GoogleAuthInfo.parseUri(
            "otpauth://totp/Deno:Mason?secret=4SJHB4GSD43FZBAI7C2HLRJGPQ&period=30")
        let entry = info.toVaultEntry()
        XCTAssertEqual(entry.name, "Mason")
        XCTAssertEqual(entry.issuer, "Deno")
        XCTAssertEqual(entry.info.typeId, "totp")
        XCTAssertTrue(entry.groups.isEmpty)
    }

    // MARK: - Aegis vault file import

    func testImportPlainVaultFile() throws {
        let data = try fixtureData("aegis_plain")
        let vault = try ImportExport.importVaultFile(data: data, password: nil)
        XCTAssertEqual(vault.entries.count, 7)

        // Spot-check the first canonical entry.
        let mason = vault.entries.first { $0.name == "Mason" && $0.issuer == "Deno" }
        XCTAssertNotNil(mason)
        XCTAssertEqual(mason?.info.typeId, "totp")
        XCTAssertEqual(Base32.encode(mason?.info.secret ?? Data()), "4SJHB4GSD43FZBAI7C2HLRJGPQ")
    }

    func testImportEncryptedVaultFile() throws {
        let data = try fixtureData("aegis_encrypted")
        let vault = try ImportExport.importVaultFile(data: data, password: "test")
        XCTAssertEqual(vault.entries.count, 7)

        let boeing = vault.entries.first { $0.issuer == "Boeing" }
        XCTAssertNotNil(boeing)
        XCTAssertEqual(boeing?.info.typeId, "steam")
    }

    func testImportEncryptedVaultFileWrongPassword() throws {
        let data = try fixtureData("aegis_encrypted")
        XCTAssertThrowsError(try ImportExport.importVaultFile(data: data, password: "wrong"))
    }

    func testImportEncryptedVaultFileMissingPassword() throws {
        let data = try fixtureData("aegis_encrypted")
        XCTAssertThrowsError(try ImportExport.importVaultFile(data: data, password: nil))
    }
}

// MARK: - Protobuf builder (test helper)

/// Hand-rolls proto3 wire bytes so migration payloads can be constructed without
/// a proto runtime (import-export spec §8.2).
private enum ProtoBuilder {
    static func varint(_ v: UInt64) -> [UInt8] {
        var value = v
        var out = [UInt8]()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func tag(_ field: Int, _ wire: Int) -> [UInt8] { varint(UInt64(field << 3 | wire)) }
    static func lenField(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(payload.count)) + payload
    }
    static func strField(_ field: Int, _ s: String) -> [UInt8] { lenField(field, Array(s.utf8)) }
    static func varField(_ field: Int, _ v: UInt64) -> [UInt8] { tag(field, 0) + varint(v) }

    /// Base64 + percent-encode a payload into an `otpauth-migration://offline?data=…` URI.
    static func migrationUri(_ payload: [UInt8]) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let b64 = Data(payload).base64EncodedString()
        let encoded = b64.addingPercentEncoding(withAllowedCharacters: unreserved) ?? b64
        return "otpauth-migration://offline?data=\(encoded)"
    }
}

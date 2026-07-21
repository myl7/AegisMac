import XCTest
import CryptoKit
@testable import AegisMac

/// Vault model / file / repository tests. Fixtures and expected vectors are taken
/// from the Aegis Android test suite (`vectors/VaultEntries.java`, the importer
/// fixtures) and the model-store / vault-crypto / import-export specs.
final class VaultTests: XCTestCase {

    // MARK: - Fixtures & helpers

    private func fixtureData(_ name: String, ext: String = "json") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            XCTFail("Missing fixture: \(name).\(ext)")
            throw AegisError.vault("missing fixture \(name)")
        }
        return try Data(contentsOf: url)
    }

    private func jsonObject(_ data: Data) throws -> JSONObject {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw AegisError.vault("not a JSON object")
        }
        return obj
    }

    /// Serialize a vault to bytes and parse it back through JSONSerialization —
    /// exercising the exact read path the app uses.
    private func roundTrip(_ vault: Vault) throws -> Vault {
        let data = try VaultFile.prettyData(vault.toJson())
        return try Vault.fromJson(jsonObject(data))
    }

    /// One canonical expected entry (from `VaultEntries.get()`).
    private struct ExpectedEntry {
        let type: String
        let issuer: String
        let name: String
        let secret: String   // base32
        let algo: String
        let digits: Int
        let period: Int?     // for totp/steam
        let counter: Int64?  // for hotp
    }

    /// The first 7 canonical vectors, matching `aegis_plain.json` / `aegis_encrypted.json`.
    private let canonical: [ExpectedEntry] = [
        .init(type: "totp",  issuer: "Deno",       name: "Mason",    secret: "4SJHB4GSD43FZBAI7C2HLRJGPQ", algo: "SHA1",   digits: 6, period: 30, counter: nil),
        .init(type: "totp",  issuer: "SPDX",       name: "James",    secret: "5OM4WOOGPLQEF6UGN3CPEOOLWU", algo: "SHA256", digits: 7, period: 20, counter: nil),
        .init(type: "totp",  issuer: "Airbnb",     name: "Elijah",   secret: "7ELGJSGXNCCTV3O6LKJWYFV2RA", algo: "SHA512", digits: 8, period: 50, counter: nil),
        .init(type: "hotp",  issuer: "Issuu",      name: "James",    secret: "YOOMIXWS5GN6RTBPUFFWKTW5M4", algo: "SHA1",   digits: 6, period: nil, counter: 1),
        .init(type: "hotp",  issuer: "Air Canada", name: "Benjamin", secret: "KUVJJOM753IHTNDSZVCNKL7GII", algo: "SHA256", digits: 7, period: nil, counter: 50),
        .init(type: "hotp",  issuer: "WWE",        name: "Mason",    secret: "5VAML3X35THCEBVRLV24CGBKOY", algo: "SHA512", digits: 8, period: nil, counter: 10300),
        .init(type: "steam", issuer: "Boeing",     name: "Sophia",   secret: "JRZCL47CMXVOQMNPZR2F7J4RGI", algo: "SHA1",   digits: 5, period: 30, counter: nil),
    ]

    private func assertMatchesCanonical(_ entries: [VaultEntry], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(entries.count, canonical.count, "entry count", file: file, line: line)
        for (entry, want) in zip(entries, canonical) {
            XCTAssertEqual(entry.info.typeId, want.type, "type for \(want.issuer)", file: file, line: line)
            XCTAssertEqual(entry.issuer, want.issuer, "issuer", file: file, line: line)
            XCTAssertEqual(entry.name, want.name, "name for \(want.issuer)", file: file, line: line)
            XCTAssertEqual(Base32.encode(entry.info.secret), want.secret, "secret for \(want.issuer)", file: file, line: line)
            XCTAssertEqual(entry.info.algorithm, want.algo, "algo for \(want.issuer)", file: file, line: line)
            XCTAssertEqual(entry.info.digits, want.digits, "digits for \(want.issuer)", file: file, line: line)
            if let period = want.period {
                XCTAssertEqual((entry.info as? TotpInfo)?.period, period, "period for \(want.issuer)", file: file, line: line)
            }
            if let counter = want.counter {
                XCTAssertEqual((entry.info as? HotpInfo)?.counter, counter, "counter for \(want.issuer)", file: file, line: line)
            }
        }
    }

    // MARK: - Full round-trip (all 5 OTP types, icon, groups)

    func testVaultRoundTripAllTypesIconGroups() throws {
        let g1 = VaultGroup(name: "Work")
        let g2 = VaultGroup(name: "Personal")

        let iconBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
        let icon = VaultEntryIcon(bytes: iconBytes, type: .png)

        let totp = VaultEntry(
            name: "alice", issuer: "GitHub", note: "primary", favorite: true, icon: icon,
            info: try TotpInfo(secret: Base32.decode("4SJHB4GSD43FZBAI7C2HLRJGPQ"), algorithm: "SHA256", digits: 8, period: 45),
            groups: [g1.uuid, g2.uuid])

        let hotp = VaultEntry(
            name: "bob", issuer: "GitLab",
            info: try HotpInfo(secret: Base32.decode("YOOMIXWS5GN6RTBPUFFWKTW5M4"), algorithm: "SHA1", digits: 6, counter: 42),
            groups: [g1.uuid])

        let steam = VaultEntry(
            name: "carol", issuer: "Steam",
            info: try SteamInfo(secret: Base32.decode("JRZCL47CMXVOQMNPZR2F7J4RGI")))

        let yandex = VaultEntry(
            name: "dave", issuer: "Yandex",
            info: try YandexInfo(secret: Data(repeating: 0x2B, count: 16), pin: "1234"))

        let motp = VaultEntry(
            name: "erin", issuer: "MOTP",
            info: try MotpInfo(secret: Data([0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F]), pin: "5678"))

        let originals = [totp, hotp, steam, yandex, motp]
        let vault = Vault(entries: originals, groups: [g1, g2], iconsOptimized: true)

        let parsed = try roundTrip(vault)

        XCTAssertEqual(parsed.entries.count, 5)
        XCTAssertTrue(parsed.iconsOptimized)
        XCTAssertEqual(parsed.groups.map { $0.uuid }, [g1.uuid, g2.uuid])
        XCTAssertEqual(parsed.groups.map { $0.name }, ["Work", "Personal"])

        for original in originals {
            guard let match = parsed.entries.first(where: { $0.uuid == original.uuid }) else {
                XCTFail("entry \(original.issuer) not found after round-trip"); continue
            }
            XCTAssertTrue(match.equivalates(original), "entry \(original.issuer) did not round-trip")
        }

        // Icon preserved with its exact bytes, type and hash.
        let parsedTotp = try XCTUnwrap(parsed.entries.first { $0.uuid == totp.uuid })
        XCTAssertEqual(parsedTotp.icon?.bytes, iconBytes)
        XCTAssertEqual(parsedTotp.icon?.type, .png)
        XCTAssertEqual(parsedTotp.icon?.hash, VaultEntryIcon.generateHash(bytes: iconBytes, type: .png))
        XCTAssertEqual(parsedTotp.groups, [g1.uuid, g2.uuid])
        XCTAssertTrue(parsedTotp.favorite)
        XCTAssertEqual(parsedTotp.note, "primary")
    }

    // MARK: - Plaintext fixtures

    func testLoadPlainFixture() throws {
        let file = try VaultFile.fromData(fixtureData("aegis_plain"))
        XCTAssertFalse(file.isEncrypted)

        let repo = try VaultRepository.loadPlain(file: file)
        XCTAssertFalse(repo.isEncrypted)
        assertMatchesCanonical(repo.vault.entries)
        // The v1 fixture has no `icons_optimized` key -> read as false.
        XCTAssertFalse(repo.vault.iconsOptimized)
    }

    func testLegacyGroupMigration_groupedV2() throws {
        let file = try VaultFile.fromData(fixtureData("aegis_plain_grouped_v2"))
        let repo = try VaultRepository.loadPlain(file: file)
        let vault = repo.vault

        // Two groups created in first-seen order.
        XCTAssertEqual(vault.groups.map { $0.name }, ["group1", "group2"])
        XCTAssertTrue(vault.isGroupsMigrationFresh)

        let g1 = try XCTUnwrap(repo.findGroup(byName: "group1"))
        let g2 = try XCTUnwrap(repo.findGroup(byName: "group2"))

        func entry(_ issuer: String) throws -> VaultEntry {
            try XCTUnwrap(vault.entries.first { $0.issuer == issuer })
        }

        // group1: Deno/Mason and Airbnb/Elijah; group2: Issuu/James.
        XCTAssertEqual(try entry("Deno").groups, [g1.uuid])
        XCTAssertEqual(try entry("Airbnb").groups, [g1.uuid])
        XCTAssertEqual(try entry("Issuu").groups, [g2.uuid])
        // `"group": null` entries end up with no groups.
        XCTAssertTrue(try entry("SPDX").groups.isEmpty)
        XCTAssertTrue(try entry("Boeing").groups.isEmpty)

        // group1 used twice, group2 once (all groups still serialized in full).
        XCTAssertEqual(vault.usedGroups().count, 2)
    }

    // MARK: - Read-time reconciliation (dangling group refs)

    func testDanglingGroupRefDropped() throws {
        let realGroup = VaultGroup(name: "Real")
        let danglingUUID = UUID()

        let entryObj: JSONObject = [
            "type": "totp",
            "uuid": UUID().uuidString.lowercased(),
            "name": "n", "issuer": "i", "note": "", "favorite": false, "icon": NSNull(),
            "info": ["secret": "4SJHB4GSD43FZBAI7C2HLRJGPQ", "algo": "SHA1", "digits": 6, "period": 30],
            "groups": [realGroup.uuid.uuidString.lowercased(), danglingUUID.uuidString.lowercased()]
        ]
        let dbObj: JSONObject = [
            "version": 3,
            "entries": [entryObj],
            "groups": [realGroup.toJson()],
            "icons_optimized": true
        ]

        let vault = try Vault.fromJson(dbObj)
        XCTAssertEqual(vault.entries.count, 1)
        // The dangling ref is dropped; the real one survives.
        XCTAssertEqual(vault.entries[0].groups, [realGroup.uuid])
    }

    // MARK: - Encrypted fixture unlock (password "test")

    func testUnlockEncryptedFixture() throws {
        let file = try VaultFile.fromData(fixtureData("aegis_encrypted"))
        XCTAssertTrue(file.isEncrypted)

        let repo = try VaultRepository.unlock(file: file, password: "test")
        XCTAssertTrue(repo.isEncrypted)
        assertMatchesCanonical(repo.vault.entries)
    }

    func testWrongPasswordThrows() throws {
        let file = try VaultFile.fromData(fixtureData("aegis_encrypted"))
        XCTAssertThrowsError(try VaultRepository.unlock(file: file, password: "not-the-password")) { error in
            guard case AegisError.crypto = error else {
                return XCTFail("expected AegisError.crypto, got \(error)")
            }
        }
    }

    // MARK: - Export round-trips

    func testEncryptedExportReUnlockRoundTrip() throws {
        let file = try VaultFile.fromData(fixtureData("aegis_plain"))
        let repo = try VaultRepository.loadPlain(file: file)

        let exported = try repo.exportEncrypted(password: "hunter2")

        let exportedFile = try VaultFile.fromData(exported)
        XCTAssertTrue(exportedFile.isEncrypted)

        let reopened = try VaultRepository.unlock(file: exportedFile, password: "hunter2")
        XCTAssertEqual(reopened.vault.entries.count, repo.vault.entries.count)
        for original in repo.vault.entries {
            let match = try XCTUnwrap(reopened.vault.entries.first { $0.uuid == original.uuid })
            XCTAssertTrue(match.equivalates(original))
        }

        // Wrong password on the export still fails.
        XCTAssertThrowsError(try VaultRepository.unlock(file: exportedFile, password: "wrong"))
    }

    func testPlainExportRoundTrip() throws {
        let file = try VaultFile.fromData(fixtureData("aegis_plain"))
        let repo = try VaultRepository.loadPlain(file: file)

        let exported = try repo.exportPlain()
        let exportedFile = try VaultFile.fromData(exported)
        XCTAssertFalse(exportedFile.isEncrypted)

        let reopened = try VaultRepository.loadPlain(file: exportedFile)
        assertMatchesCanonical(reopened.vault.entries)
    }

    // MARK: - Icon parsing edge cases

    func testIconMissingMimeDefaultsToJpegAndRecomputesHash() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let obj: JSONObject = [
            "type": "totp", "uuid": UUID().uuidString.lowercased(),
            "name": "n", "issuer": "i",
            "info": ["secret": "4SJHB4GSD43FZBAI7C2HLRJGPQ", "algo": "SHA1", "digits": 6, "period": 30],
            "icon": bytes.base64EncodedString()
            // no icon_mime, no icon_hash
        ]
        let entry = try VaultEntry.fromJson(obj)
        let icon = try XCTUnwrap(entry.icon)
        XCTAssertEqual(icon.type, .jpeg)
        XCTAssertEqual(icon.bytes, bytes)
        XCTAssertEqual(icon.hash, VaultEntryIcon.generateHash(bytes: bytes, type: .jpeg))
    }

    func testIconBadMimeIsSwallowed() throws {
        let obj: JSONObject = [
            "type": "totp", "uuid": UUID().uuidString.lowercased(),
            "name": "n", "issuer": "i",
            "info": ["secret": "4SJHB4GSD43FZBAI7C2HLRJGPQ", "algo": "SHA1", "digits": 6, "period": 30],
            "icon": Data([0x01]).base64EncodedString(),
            "icon_mime": "image/gif"
        ]
        let entry = try VaultEntry.fromJson(obj)
        XCTAssertNil(entry.icon, "unknown MIME should be swallowed -> icon-less entry")
    }

    func testIconStoredHashIsTrusted() throws {
        let bytes = Data([0xAA, 0xBB, 0xCC])
        // A deliberately "wrong" hash to prove it is used verbatim, not recomputed.
        let storedHash = Data(repeating: 0x00, count: 32)
        let obj: JSONObject = [
            "type": "totp", "uuid": UUID().uuidString.lowercased(),
            "name": "n", "issuer": "i",
            "info": ["secret": "4SJHB4GSD43FZBAI7C2HLRJGPQ", "algo": "SHA1", "digits": 6, "period": 30],
            "icon": bytes.base64EncodedString(),
            "icon_mime": "image/png",
            "icon_hash": HexCodec.encode(storedHash)
        ]
        let entry = try VaultEntry.fromJson(obj)
        XCTAssertEqual(entry.icon?.hash, storedHash)
    }

    func testIconHashFormula() {
        // hash = SHA256( utf8(mime) || bytes )
        let bytes = Data("hello".utf8)
        var hasher = SHA256()
        hasher.update(data: Data("image/png".utf8))
        hasher.update(data: bytes)
        XCTAssertEqual(VaultEntryIcon.generateHash(bytes: bytes, type: .png), Data(hasher.finalize()))
    }

    // MARK: - Version rejection

    func testVaultDbVersionTooNewRejected() {
        let obj: JSONObject = ["version": 4, "entries": [], "groups": []]
        XCTAssertThrowsError(try Vault.fromJson(obj))
    }

    func testVaultFileVersionTooNewRejected() throws {
        let obj: JSONObject = [
            "version": 2,
            "header": ["slots": NSNull(), "params": NSNull()],
            "db": ["version": 3, "entries": [], "groups": []]
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try VaultFile.fromData(data))
    }

    func testIconsOptimizedSemantics() throws {
        func iconsOptimized(_ value: Any?) throws -> Bool {
            var obj: JSONObject = ["version": 3, "entries": [], "groups": []]
            if let value = value { obj["icons_optimized"] = value }
            return try Vault.fromJson(obj).iconsOptimized
        }
        XCTAssertTrue(try iconsOptimized(true))    // explicit true keeps optimized
        XCTAssertFalse(try iconsOptimized(false))  // explicit false
        XCTAssertFalse(try iconsOptimized(nil))    // missing -> false
    }

    // MARK: - Header / envelope detection

    func testHeaderEmptyIffPlaintext() throws {
        let plain = try VaultFile.fromData(fixtureData("aegis_plain"))
        XCTAssertFalse(plain.isEncrypted)
        XCTAssertTrue(plain.header.isEmpty)

        let enc = try VaultFile.fromData(fixtureData("aegis_encrypted"))
        XCTAssertTrue(enc.isEncrypted)
        XCTAssertFalse(enc.header.isEmpty)
        XCTAssertNotNil(enc.header.slots)
        XCTAssertNotNil(enc.header.params)
    }

    // MARK: - Repository mutations

    func testEntryMutationsAndMove() throws {
        let repo = try VaultRepository.createNew(password: nil)

        func makeEntry(_ issuer: String) throws -> VaultEntry {
            VaultEntry(name: "n", issuer: issuer,
                       info: try TotpInfo(secret: Base32.decode("4SJHB4GSD43FZBAI7C2HLRJGPQ")))
        }

        let a = try makeEntry("A"), b = try makeEntry("B"), c = try makeEntry("C")
        repo.addEntry(a); repo.addEntry(b); repo.addEntry(c)
        XCTAssertEqual(repo.vault.entries.map { $0.issuer }, ["A", "B", "C"])

        // Move C (index 2) to index 0.
        repo.moveEntry(from: 2, to: 0)
        XCTAssertEqual(repo.vault.entries.map { $0.issuer }, ["C", "A", "B"])

        // Update B's note in place (same UUID, position preserved).
        b.note = "edited"
        repo.updateEntry(b)
        XCTAssertEqual(repo.vault.entries.map { $0.issuer }, ["C", "A", "B"])
        XCTAssertEqual(repo.vault.entries.last?.note, "edited")

        // Remove A.
        repo.removeEntry(a)
        XCTAssertEqual(repo.vault.entries.map { $0.issuer }, ["C", "B"])
    }

    func testRemoveGroupStripsFromEntries() throws {
        let repo = try VaultRepository.createNew(password: nil)
        let group = VaultGroup(name: "Team")
        repo.addGroup(group)

        let entry = VaultEntry(name: "n", issuer: "i",
                               info: try TotpInfo(secret: Base32.decode("4SJHB4GSD43FZBAI7C2HLRJGPQ")),
                               groups: [group.uuid])
        repo.addEntry(entry)
        XCTAssertEqual(entry.groups, [group.uuid])

        repo.removeGroup(group)
        XCTAssertTrue(repo.vault.groups.isEmpty)
        XCTAssertTrue(entry.groups.isEmpty, "group UUID must be stripped from the entry")
    }

    func testRenameGroup() throws {
        let repo = try VaultRepository.createNew(password: nil)
        let group = VaultGroup(name: "Old")
        repo.addGroup(group)
        repo.renameGroup(group, to: "New")
        XCTAssertEqual(repo.vault.groups.first?.name, "New")
        XCTAssertEqual(repo.vault.groups.first?.uuid, group.uuid)
    }

    // MARK: - Atomic save

    func testAtomicSaveAndReloadEncrypted() throws {
        let repo = try VaultRepository.createNew(password: "pw")
        let entry = VaultEntry(name: "acct", issuer: "Svc",
                               info: try TotpInfo(secret: Base32.decode("4SJHB4GSD43FZBAI7C2HLRJGPQ")))
        repo.addEntry(entry)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aegis-vaulttests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("aegis.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        try repo.save(to: url)
        XCTAssertTrue(VaultRepository.fileExists(at: url))

        // Owner-only permissions (0600).
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, Int16(0o600))

        let file = try VaultRepository.loadFile(at: url)
        XCTAssertTrue(file.isEncrypted)
        let reopened = try VaultRepository.unlock(file: file, password: "pw")
        XCTAssertEqual(reopened.vault.entries.count, 1)
        XCTAssertTrue(try XCTUnwrap(reopened.vault.entries.first).equivalates(entry))
    }

    func testAtomicSavePlaintextReload() throws {
        let repo = try VaultRepository.createNew(password: nil)
        let entry = VaultEntry(name: "acct", issuer: "Svc",
                               info: try TotpInfo(secret: Base32.decode("4SJHB4GSD43FZBAI7C2HLRJGPQ")))
        repo.addEntry(entry)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aegis-vaulttests-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("aegis.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        try repo.save(to: url)
        // Overwrite once more to exercise the replace path.
        try repo.save(to: url)

        let file = try VaultRepository.loadFile(at: url)
        XCTAssertFalse(file.isEncrypted)
        let reopened = try VaultRepository.loadPlain(file: file)
        XCTAssertEqual(reopened.vault.entries.count, 1)
    }

    // MARK: - Encryption management (set / change / remove password)

    private func totpEntry(_ name: String = "acct") throws -> VaultEntry {
        VaultEntry(name: name, issuer: "Svc",
                   info: try TotpInfo(secret: Base32.decode("4SJHB4GSD43FZBAI7C2HLRJGPQ")))
    }

    private func saveReload(_ repo: VaultRepository) throws -> VaultFile {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aegis-enc-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("aegis.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try repo.save(to: url)
        return try VaultRepository.loadFile(at: url)
    }

    /// Encrypting a plaintext vault: the on-disk file becomes encrypted and unlocks
    /// with the chosen password. Mirrors upstream `enableEncryption`.
    func testEnableEncryptionOnPlaintextVault() throws {
        let repo = try VaultRepository.createNew(password: nil)
        try repo.addEntry(totpEntry())
        XCTAssertFalse(repo.isEncrypted)

        try repo.enableEncryption(password: "secret")
        XCTAssertTrue(repo.isEncrypted)

        let file = try saveReload(repo)
        XCTAssertTrue(file.isEncrypted)
        let reopened = try VaultRepository.unlock(file: file, password: "secret")
        XCTAssertEqual(reopened.vault.entries.count, 1)
    }

    func testEnableEncryptionIsNoOpWhenAlreadyEncrypted() throws {
        let repo = try VaultRepository.createNew(password: "original")
        try repo.enableEncryption(password: "ignored")
        // The original password still works; the second call did nothing.
        let file = try saveReload(repo)
        XCTAssertNoThrow(try VaultRepository.unlock(file: file, password: "original"))
        XCTAssertThrowsError(try VaultRepository.unlock(file: file, password: "ignored"))
    }

    /// Changing the password keeps the same master key (entries stay readable) but
    /// only the new password unlocks. Mirrors upstream `SetPasswordListener`.
    func testChangePasswordReencryptsWithNewPasswordOnly() throws {
        let repo = try VaultRepository.createNew(password: "old")
        let entry = try totpEntry()
        try repo.addEntry(entry)

        try repo.changePassword(newPassword: "new")

        let file = try saveReload(repo)
        XCTAssertTrue(file.isEncrypted)
        XCTAssertThrowsError(try VaultRepository.unlock(file: file, password: "old"))
        let reopened = try VaultRepository.unlock(file: file, password: "new")
        XCTAssertEqual(reopened.vault.entries.count, 1)
        XCTAssertTrue(try XCTUnwrap(reopened.vault.entries.first).equivalates(entry))
    }

    func testChangePasswordThrowsWhenPlaintext() throws {
        let repo = try VaultRepository.createNew(password: nil)
        XCTAssertThrowsError(try repo.changePassword(newPassword: "new"))
    }

    /// Removing the password turns the vault back into plaintext on disk.
    func testDisableEncryption() throws {
        let repo = try VaultRepository.createNew(password: "pw")
        try repo.addEntry(totpEntry())
        XCTAssertTrue(repo.isEncrypted)

        repo.disableEncryption()
        XCTAssertFalse(repo.isEncrypted)

        let file = try saveReload(repo)
        XCTAssertFalse(file.isEncrypted)
        let reopened = try VaultRepository.loadPlain(file: file)
        XCTAssertEqual(reopened.vault.entries.count, 1)
    }
}

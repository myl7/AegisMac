import Foundation

/// The `header` object of a vault file. Both `slots` and `params` null means the
/// vault is **plaintext**; either present means **encrypted**.
struct VaultFileHeader {
    var slots: SlotList?
    var params: CryptParameters?

    /// `Header.isEmpty()` — true for a plaintext vault.
    var isEmpty: Bool {
        return slots == nil && params == nil
    }

    func toJson() -> JSONObject {
        var obj: JSONObject = [:]
        if let slots = slots {
            obj["slots"] = slots.toJson()
        } else {
            obj["slots"] = NSNull()
        }
        if let params = params {
            obj["params"] = params.toJson()
        } else {
            obj["params"] = NSNull()
        }
        return obj
    }

    static func fromJson(_ obj: JSONObject) throws -> VaultFileHeader {
        let slotsNull = (obj["slots"] == nil) || (obj["slots"] is NSNull)
        let paramsNull = (obj["params"] == nil) || (obj["params"] is NSNull)
        if slotsNull && paramsNull {
            return VaultFileHeader(slots: nil, params: nil)
        }
        guard let slotsArr = obj["slots"] as? [Any] else {
            throw AegisError.vault("header missing 'slots'")
        }
        let slots = try SlotList.fromJson(slotsArr)
        guard let paramsObj = obj["params"] as? JSONObject else {
            throw AegisError.vault("header missing 'params'")
        }
        let params = try CryptParameters.fromJson(paramsObj)
        return VaultFileHeader(slots: slots, params: params)
    }
}

/// Credentials for encrypting/decrypting a vault file: the shared master key plus
/// the slot list that wraps it (`VaultFileCredentials.java`).
struct VaultFileCredentials {
    var slots: SlotList
    var masterKey: MasterKey
}

/// The outer vault file envelope (`VaultFile.java`), format **version 1**.
///
/// - Plaintext: `db` is the raw Vault db JSON object; header is `{slots:null, params:null}`.
/// - Encrypted: `db` is the base64 string of the AES-256-GCM ciphertext of the db
///   JSON; the GCM tag lives in `header.params.tag`.
final class VaultFile {
    static let version = 1

    var header: VaultFileHeader
    /// Either a `JSONObject` (plaintext db) or a `String` (base64 ciphertext).
    private var content: Any

    init(content: Any, header: VaultFileHeader) {
        self.content = content
        self.header = header
    }

    var isEncrypted: Bool {
        return !header.isEmpty
    }

    // MARK: Reading

    static func fromData(_ data: Data) throws -> VaultFile {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw AegisError.vault("invalid vault file JSON: \(error.localizedDescription)")
        }
        guard let obj = json as? JSONObject else {
            throw AegisError.vault("vault file is not a JSON object")
        }

        let ver = try requiredInt(obj, "version")
        if ver > VaultFile.version {
            throw AegisError.vault("unsupported version")
        }

        guard let headerObj = obj["header"] as? JSONObject else {
            throw AegisError.vault("vault file missing 'header'")
        }
        let header = try VaultFileHeader.fromJson(headerObj)

        if !header.isEmpty {
            guard let db = obj["db"] as? String else {
                throw AegisError.vault("encrypted vault 'db' must be a string")
            }
            return VaultFile(content: db, header: header)
        } else {
            guard let db = obj["db"] as? JSONObject else {
                throw AegisError.vault("plaintext vault 'db' must be an object")
            }
            return VaultFile(content: db, header: header)
        }
    }

    /// The plaintext db object (only valid when the vault is not encrypted).
    func getPlainContent() throws -> JSONObject {
        guard !isEncrypted else {
            throw AegisError.vault("vault is encrypted; a master key is required")
        }
        guard let obj = content as? JSONObject else {
            throw AegisError.vault("invalid plaintext vault content")
        }
        return obj
    }

    /// Decrypts and parses the db object using the given master key.
    func getContent(masterKey: MasterKey) throws -> JSONObject {
        guard isEncrypted, let params = header.params else {
            throw AegisError.vault("vault is not encrypted")
        }
        guard let db = content as? String else {
            throw AegisError.vault("invalid encrypted vault content")
        }
        guard let cipher = Data(base64Encoded: db) else {
            throw AegisError.vault("invalid base64 db payload")
        }
        let plain = try masterKey.decrypt(cipher, params: params)
        guard let json = try? JSONSerialization.jsonObject(with: plain, options: []),
              let obj = json as? JSONObject else {
            throw AegisError.vault("decrypted vault content is not a JSON object")
        }
        return obj
    }

    // MARK: Writing

    func toJson() -> JSONObject {
        return [
            "version": VaultFile.version,
            "header": header.toJson(),
            "db": content
        ]
    }

    /// Serializes the envelope as pretty-printed UTF-8 JSON.
    func toData() throws -> Data {
        return try VaultFile.prettyData(toJson())
    }

    /// Builds a vault file from a vault. `credentials == nil` produces a plaintext
    /// file; otherwise the db is encrypted with the credentials' master key and the
    /// credentials' slots are written into the header.
    static func make(vault: Vault, credentials: VaultFileCredentials?) throws -> VaultFile {
        let dbObj = vault.toJson()
        if let creds = credentials {
            let dbBytes = try prettyData(dbObj)
            let (cipher, params) = try creds.masterKey.encrypt(dbBytes)
            let header = VaultFileHeader(slots: creds.slots, params: params)
            return VaultFile(content: cipher.base64EncodedString(), header: header)
        } else {
            let header = VaultFileHeader(slots: nil, params: nil)
            return VaultFile(content: dbObj, header: header)
        }
    }

    // MARK: - Helpers

    /// Pretty-printed JSON data (Aegis writes 4-space indent; JSONSerialization
    /// emits 2-space, but the difference is not load-bearing — readers are
    /// key-based and tests compare parsed JSON, not raw bytes).
    static func prettyData(_ obj: JSONObject) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted]
        if #available(macOS 10.15, *) {
            options.insert(.withoutEscapingSlashes)
        }
        guard JSONSerialization.isValidJSONObject(obj) else {
            throw AegisError.vault("vault content is not serializable to JSON")
        }
        do {
            return try JSONSerialization.data(withJSONObject: obj, options: options)
        } catch {
            throw AegisError.vault("failed to serialize vault: \(error.localizedDescription)")
        }
    }

    private static func requiredInt(_ obj: JSONObject, _ key: String) throws -> Int {
        guard let value = obj[key], !(value is NSNull) else {
            throw AegisError.vault("vault file missing '\(key)'")
        }
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let i = Int(s) { return i }
        throw AegisError.vault("vault file '\(key)' is not an integer")
    }
}

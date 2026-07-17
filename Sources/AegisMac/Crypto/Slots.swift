import Foundation

/// Slot type discriminator (`type` field in the JSON).
enum SlotType: Int {
    case raw = 0
    case password = 1
    case biometric = 2
}

/// A slot holds an independently-wrapped copy of the vault master key. The base
/// class carries the fields common to every slot type; subclasses add their own.
///
/// JSON (common shape):
/// ```
/// { "type": <int>, "uuid": "<lowercase uuid>",
///   "key": "<hex ciphertext of the 32-byte master key>",
///   "key_params": { "nonce": "<hex 12B>", "tag": "<hex 16B>" } }
/// ```
class Slot {
    var uuid: UUID
    /// AES-GCM ciphertext of the 32-byte master key (32 bytes -> 64 hex chars).
    var encryptedMasterKey: Data
    /// GCM nonce + tag used to wrap the master key.
    var keyParams: CryptParameters

    init(uuid: UUID, encryptedMasterKey: Data, keyParams: CryptParameters) {
        self.uuid = uuid
        self.encryptedMasterKey = encryptedMasterKey
        self.keyParams = keyParams
    }

    /// Overridden by every concrete subclass.
    var type: SlotType {
        fatalError("Slot.type must be overridden")
    }

    func toJson() -> JSONObject {
        return [
            "type": type.rawValue,
            "uuid": uuid.uuidString.lowercased(),
            "key": HexCodec.encode(encryptedMasterKey),
            "key_params": keyParams.toJson()
        ]
    }

    /// Parses a slot object, dispatching on the `type` field.
    /// Unknown types throw `AegisError.crypto("unrecognized slot type")`.
    static func fromJson(_ obj: JSONObject) throws -> Slot {
        let uuid: UUID
        if let uuidStr = obj["uuid"] as? String {
            guard let parsed = UUID(uuidString: uuidStr) else {
                throw AegisError.crypto("invalid slot uuid")
            }
            uuid = parsed
        } else {
            // Absent uuid -> generate a fresh one (matches Slot.fromJson).
            uuid = UUID()
        }

        guard let keyHex = obj["key"] as? String else {
            throw AegisError.crypto("slot missing 'key'")
        }
        let key = try HexCodec.decode(keyHex)

        guard let keyParamsObj = obj["key_params"] as? JSONObject else {
            throw AegisError.crypto("slot missing 'key_params'")
        }
        let keyParams = try CryptParameters.fromJson(keyParamsObj)

        guard let typeInt = Slot.intValue(obj["type"]) else {
            throw AegisError.crypto("slot missing 'type'")
        }

        switch typeInt {
        case SlotType.raw.rawValue:
            return RawSlot(uuid: uuid, encryptedMasterKey: key, keyParams: keyParams)
        case SlotType.password.rawValue:
            guard let n = Slot.intValue(obj["n"]),
                  let r = Slot.intValue(obj["r"]),
                  let p = Slot.intValue(obj["p"]) else {
                throw AegisError.crypto("password slot missing scrypt params")
            }
            guard let saltHex = obj["salt"] as? String else {
                throw AegisError.crypto("password slot missing 'salt'")
            }
            let salt = try HexCodec.decode(saltHex)
            let scryptParams = ScryptParameters(n: n, r: r, p: p, salt: salt)
            let repaired = Slot.boolValue(obj["repaired"], default: false)
            let isBackup = Slot.boolValue(obj["is_backup"], default: false)
            return PasswordSlot(uuid: uuid,
                                encryptedMasterKey: key,
                                keyParams: keyParams,
                                scryptParams: scryptParams,
                                repaired: repaired,
                                isBackup: isBackup)
        case SlotType.biometric.rawValue:
            return BiometricSlot(uuid: uuid, encryptedMasterKey: key, keyParams: keyParams)
        default:
            throw AegisError.crypto("unrecognized slot type")
        }
    }

    /// AES-GCM-unwraps the master key using the given 32-byte wrapping key.
    /// Throws on authentication failure (wrong key).
    func getKey(_ keyBytes: Data) throws -> MasterKey {
        let plain = try CryptoUtils.decrypt(encryptedMasterKey, key: keyBytes, params: keyParams)
        return MasterKey(bytes: plain)
    }

    /// Wraps `masterKey` with the given 32-byte wrapping key and stores the result.
    func setKey(_ masterKey: MasterKey, wrappingKey: Data) throws {
        let (cipherText, params) = try CryptoUtils.encrypt(masterKey.bytes, key: wrappingKey)
        encryptedMasterKey = cipherText
        keyParams = params
    }

    // MARK: - JSON number helpers

    /// Extracts an Int from an org.json-style `Any` value (bridged `NSNumber`).
    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    /// Extracts a Bool from an org.json-style `Any` value, with a default when absent.
    static func boolValue(_ any: Any?, default def: Bool) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return def
    }
}

/// Raw slot (type 0): master key wrapped with a caller-supplied 32-byte AES key.
final class RawSlot: Slot {
    override var type: SlotType { .raw }
}

/// Password slot (type 1): master key wrapped with a scrypt-derived key.
final class PasswordSlot: Slot {
    var scryptParams: ScryptParameters
    var repaired: Bool
    var isBackup: Bool

    override var type: SlotType { .password }

    init(uuid: UUID,
         encryptedMasterKey: Data,
         keyParams: CryptParameters,
         scryptParams: ScryptParameters,
         repaired: Bool,
         isBackup: Bool) {
        self.scryptParams = scryptParams
        self.repaired = repaired
        self.isBackup = isBackup
        super.init(uuid: uuid, encryptedMasterKey: encryptedMasterKey, keyParams: keyParams)
    }

    override func toJson() -> JSONObject {
        var obj = super.toJson()
        obj["n"] = scryptParams.n
        obj["r"] = scryptParams.r
        obj["p"] = scryptParams.p
        obj["salt"] = HexCodec.encode(scryptParams.salt)
        obj["repaired"] = repaired
        obj["is_backup"] = isBackup
        return obj
    }

    /// Derives this slot's 32-byte scrypt key from the given password.
    func deriveKey(password: String) throws -> Data {
        return try CryptoUtils.deriveKey(password: Array(password.utf8), params: scryptParams)
    }

    /// Wrapping the master key through a password slot marks it repaired
    /// (matches `PasswordSlot.setKey`).
    override func setKey(_ masterKey: MasterKey, wrappingKey: Data) throws {
        try super.setKey(masterKey, wrappingKey: wrappingKey)
        repaired = true
    }

    /// Creates a fresh password slot that wraps `masterKey`, deriving a scrypt key
    /// from `password` with default parameters (N=32768, r=8, p=1, random 32-byte
    /// salt) and marking the slot `repaired`. Implements vault-crypto spec §6.3.
    static func create(password: String, masterKey: MasterKey, isBackup: Bool = false) throws -> PasswordSlot {
        let params = ScryptParameters.generate()
        let derivedKey = try CryptoUtils.deriveKey(password: Array(password.utf8), params: params)
        let (cipherText, keyParams) = try CryptoUtils.encrypt(masterKey.bytes, key: derivedKey)
        return PasswordSlot(uuid: UUID(),
                            encryptedMasterKey: cipherText,
                            keyParams: keyParams,
                            scryptParams: params,
                            repaired: true,
                            isBackup: isBackup)
    }
}

/// Biometric slot (type 2): parsed and re-serialized so exports/round-trips
/// preserve it, but never unlockable on macOS (the wrapping key lives in the
/// Secure Enclave / hardware keystore).
final class BiometricSlot: Slot {
    override var type: SlotType { .biometric }
}

/// Ordered list of slots (`header.slots`).
struct SlotList {
    var slots: [Slot]

    init(slots: [Slot] = []) {
        self.slots = slots
    }

    func toJson() -> [JSONObject] {
        return slots.map { $0.toJson() }
    }

    static func fromJson(_ arr: [Any]) throws -> SlotList {
        var parsed = [Slot]()
        parsed.reserveCapacity(arr.count)
        for item in arr {
            guard let obj = item as? JSONObject else {
                throw AegisError.crypto("invalid slot entry")
            }
            parsed.append(try Slot.fromJson(obj))
        }
        return SlotList(slots: parsed)
    }

    func findPasswordSlots() -> [PasswordSlot] {
        return slots.compactMap { $0 as? PasswordSlot }
    }

    func findBackupPasswordSlots() -> [PasswordSlot] {
        return findPasswordSlots().filter { $0.isBackup }
    }

    func findRegularPasswordSlots() -> [PasswordSlot] {
        return findPasswordSlots().filter { !$0.isBackup }
    }

    /// Tries the password against every password slot in order. Returns the master
    /// key from the first slot that unwraps successfully. A GCM authentication
    /// failure (or any per-slot crypto error) means "wrong slot" -> try the next.
    /// If every slot fails, throws `AegisError.crypto("unlock failed")`.
    func unlock(password: String) throws -> MasterKey {
        for slot in findPasswordSlots() {
            do {
                let derivedKey = try slot.deriveKey(password: password)
                return try slot.getKey(derivedKey)
            } catch {
                // Wrong password for this slot; try the next one.
                continue
            }
        }
        throw AegisError.crypto("unlock failed")
    }

    /// Returns a copy suitable for exporting: biometric slots are always dropped,
    /// and if any backup password slot exists, all regular (non-backup) password
    /// slots are dropped too. Raw slots are always kept. (vault-crypto spec §4.5)
    func exportable() -> SlotList {
        let hasBackup = slots.contains { ($0 as? PasswordSlot)?.isBackup == true }
        let filtered = slots.filter { slot in
            if slot is BiometricSlot {
                return false
            }
            if hasBackup, let pw = slot as? PasswordSlot, !pw.isBackup {
                return false
            }
            return true
        }
        return SlotList(slots: filtered)
    }
}

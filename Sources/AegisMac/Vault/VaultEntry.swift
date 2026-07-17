import Foundation

/// A single vault entry (`VaultEntry.java`): an OTP secret plus its display
/// metadata, icon and group memberships.
///
/// A reference type (like the Java class) so in-place edits (`favorite.toggle()`,
/// `groups = ...`, `incrementCounter()`) are reflected everywhere the entry is
/// held. `id == uuid`.
final class VaultEntry: Identifiable {
    var uuid: UUID
    var name: String
    var issuer: String
    var note: String
    var favorite: Bool
    var icon: VaultEntryIcon?
    var info: OtpInfo
    var groups: Set<UUID>

    /// Legacy single-group name carried between parse and migration (§5). Never
    /// serialized; cleared once `Vault.migrateOldGroup` runs.
    var oldGroup: String?

    var id: UUID { uuid }

    init(uuid: UUID = UUID(),
         name: String = "",
         issuer: String = "",
         note: String = "",
         favorite: Bool = false,
         icon: VaultEntryIcon? = nil,
         info: OtpInfo,
         groups: Set<UUID> = []) {
        self.uuid = uuid
        self.name = name
        self.issuer = issuer
        self.note = note
        self.favorite = favorite
        self.icon = icon
        self.info = info
        self.groups = groups
        self.oldGroup = nil
    }

    // MARK: JSON

    func toJson() -> JSONObject {
        var obj: JSONObject = [:]
        obj["type"] = info.typeId
        obj["uuid"] = uuid.uuidString.lowercased()
        obj["name"] = name
        obj["issuer"] = issuer
        obj["note"] = note
        obj["favorite"] = favorite
        VaultEntryIcon.writeJson(icon, into: &obj)
        obj["info"] = info.toJson()
        // TreeSet<UUID> iteration order = UUID natural order (Java UUID.compareTo).
        obj["groups"] = VaultEntry.sortedGroupUUIDStrings(groups)
        return obj
    }

    static func fromJson(_ obj: JSONObject) throws -> VaultEntry {
        // uuid: absent -> generate a fresh random UUID.
        let uuid: UUID
        if let uuidVal = obj["uuid"], !(uuidVal is NSNull) {
            guard let uuidStr = uuidVal as? String, let parsed = UUID(uuidString: uuidStr) else {
                throw AegisError.vault("invalid entry uuid")
            }
            uuid = parsed
        } else {
            uuid = UUID()
        }

        // info depends on the entry type; a parse failure fails the whole entry.
        let type = try requiredString(obj, "type")
        guard let infoObj = obj["info"] as? JSONObject else {
            throw AegisError.vault("entry missing 'info'")
        }
        let info = try OtpInfo.fromJson(type: type, obj: infoObj)

        let entry = VaultEntry(uuid: uuid, info: info)
        entry.name = try requiredString(obj, "name")
        entry.issuer = try requiredString(obj, "issuer")
        entry.note = optStringDefault(obj, "note", "")
        entry.favorite = optBool(obj, "favorite", false)

        // Presence of "groups" means the migration already happened -> ignore "group".
        if let groupsVal = obj["groups"], !(groupsVal is NSNull) {
            guard let groupsArr = groupsVal as? [Any] else {
                throw AegisError.vault("entry 'groups' is not an array")
            }
            for item in groupsArr {
                guard let groupStr = item as? String, let groupUUID = UUID(uuidString: groupStr) else {
                    throw AegisError.vault("invalid group uuid in entry")
                }
                entry.groups.insert(groupUUID)
            }
        } else if let old = optStringOrNil(obj, "group") {
            entry.oldGroup = old
        }

        // Icon parse errors are silently ignored (entry keeps no icon).
        do {
            entry.icon = try VaultEntryIcon.fromJson(obj)
        } catch {
            entry.icon = nil
        }

        return entry
    }

    // MARK: Equivalence

    /// Reports whether two entries are equivalent, **ignoring UUID** (Java
    /// `VaultEntry.equivalates`): name, issuer, OTP info, icon, note, favorite and
    /// group set must all match.
    func equivalates(_ other: VaultEntry) -> Bool {
        return name == other.name
            && issuer == other.issuer
            && info.isEqual(to: other.info)
            && icon == other.icon
            && note == other.note
            && favorite == other.favorite
            && groups == other.groups
    }

    // MARK: Group-UUID ordering (Java TreeSet<UUID> order)

    /// Sorts group UUIDs the way Java's `TreeSet<UUID>` iterates them: by
    /// `UUID.compareTo`, which compares the most- then least-significant 64 bits as
    /// **signed** longs. Returns the canonical lowercase strings in that order.
    static func sortedGroupUUIDStrings(_ groups: Set<UUID>) -> [String] {
        return groups.sorted(by: javaUUIDLess).map { $0.uuidString.lowercased() }
    }

    private static func javaUUIDLess(_ a: UUID, _ b: UUID) -> Bool {
        let (am, al) = signedHalves(a)
        let (bm, bl) = signedHalves(b)
        if am != bm { return am < bm }
        return al < bl
    }

    /// The (mostSigBits, leastSigBits) of a UUID as signed 64-bit integers.
    private static func signedHalves(_ u: UUID) -> (Int64, Int64) {
        let b = u.uuid
        let bytes: [UInt8] = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
                              b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
        var msb: UInt64 = 0
        var lsb: UInt64 = 0
        for i in 0..<8 { msb = (msb << 8) | UInt64(bytes[i]) }
        for i in 8..<16 { lsb = (lsb << 8) | UInt64(bytes[i]) }
        return (Int64(bitPattern: msb), Int64(bitPattern: lsb))
    }

    // MARK: - JSON coercion helpers (org.json-style)

    /// `obj.getString(key)`: throws if absent, JSON null, or not a string.
    private static func requiredString(_ obj: JSONObject, _ key: String) throws -> String {
        guard let value = obj[key], !(value is NSNull) else {
            throw AegisError.vault("entry missing '\(key)'")
        }
        guard let str = value as? String else {
            throw AegisError.vault("entry '\(key)' is not a string")
        }
        return str
    }

    /// `obj.optString(key, def)`: def when absent or JSON null, else the string.
    private static func optStringDefault(_ obj: JSONObject, _ key: String, _ def: String) -> String {
        guard let value = obj[key], !(value is NSNull) else { return def }
        return (value as? String) ?? def
    }

    /// `JsonUtils.optString(obj, key)`: nil when absent or JSON null, else the string.
    private static func optStringOrNil(_ obj: JSONObject, _ key: String) -> String? {
        guard let value = obj[key], !(value is NSNull) else { return nil }
        return value as? String
    }

    /// `obj.optBoolean(key, def)`.
    private static func optBool(_ obj: JSONObject, _ key: String, _ def: Bool) -> Bool {
        guard let value = obj[key], !(value is NSNull) else { return def }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            if s.caseInsensitiveCompare("true") == .orderedSame { return true }
            if s.caseInsensitiveCompare("false") == .orderedSame { return false }
        }
        return def
    }
}

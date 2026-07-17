import Foundation

/// The decrypted vault "db" content (`Vault.java`): the ordered list of entries,
/// the full group list, and the icons-optimized flag. Version constant is **3**.
///
/// `entries` order **is** the custom sort order (Java backs it with a
/// `LinkedHashMap` keyed by UUID; insertion order == the `entries` JSON array).
final class Vault {
    static let version = 3

    var entries: [VaultEntry]
    var groups: [VaultGroup]
    var iconsOptimized: Bool

    /// Set when a legacy `group` name was migrated during `fromJson`; the app uses
    /// it to trigger a re-save into the new format.
    var isGroupsMigrationFresh: Bool = false

    init(entries: [VaultEntry] = [], groups: [VaultGroup] = [], iconsOptimized: Bool = true) {
        self.entries = entries
        self.groups = groups
        self.iconsOptimized = iconsOptimized
    }

    // MARK: JSON

    func toJson() -> JSONObject {
        var obj: JSONObject = [:]
        obj["version"] = Vault.version
        obj["entries"] = entries.map { $0.toJson() }
        // Always serialize the full group list, even groups no entry references.
        obj["groups"] = groups.map { $0.toJson() }
        obj["icons_optimized"] = iconsOptimized
        return obj
    }

    static func fromJson(_ obj: JSONObject) throws -> Vault {
        let ver = try requiredInt(obj, "version")
        if ver > Vault.version {
            throw AegisError.vault("Unsupported version")
        }

        let vault = Vault()

        // 1. Parse groups first, deduping by UUID.
        if let groupsVal = obj["groups"], !(groupsVal is NSNull) {
            guard let groupsArr = groupsVal as? [Any] else {
                throw AegisError.vault("'groups' is not an array")
            }
            for item in groupsArr {
                guard let gObj = item as? JSONObject else {
                    throw AegisError.vault("invalid group entry")
                }
                let group = try VaultGroup.fromJson(gObj)
                if !vault.groups.contains(where: { $0.uuid == group.uuid }) {
                    vault.groups.append(group)
                }
            }
        }

        // 2. Parse entries; migrate legacy groups; drop dangling group refs.
        guard let entriesVal = obj["entries"], !(entriesVal is NSNull),
              let entriesArr = entriesVal as? [Any] else {
            throw AegisError.vault("missing 'entries'")
        }
        for item in entriesArr {
            guard let eObj = item as? JSONObject else {
                throw AegisError.vault("invalid entry")
            }
            let entry = try VaultEntry.fromJson(eObj)

            if vault.migrateOldGroup(entry) {
                vault.isGroupsMigrationFresh = true
            }

            // Drop any group UUID the vault doesn't actually have.
            let dangling = entry.groups.filter { uuid in
                !vault.groups.contains(where: { $0.uuid == uuid })
            }
            for uuid in dangling {
                entry.groups.remove(uuid)
            }

            // Defensive against duplicate UUIDs (Java asserts; we skip).
            if !vault.entries.contains(where: { $0.uuid == entry.uuid }) {
                vault.entries.append(entry)
            }
        }

        // 3. icons_optimized: only an explicit `true` keeps it optimized.
        if !optBooleanNoDefault(obj, "icons_optimized") {
            vault.iconsOptimized = false
        }

        return vault
    }

    // MARK: Group migration

    /// Migrates an entry's legacy single-group name into the new UUID-based model
    /// (`Vault.migrateOldGroup`). Reuses an existing group with the same name, or
    /// creates a new one. Returns true if a migration happened.
    @discardableResult
    func migrateOldGroup(_ entry: VaultEntry) -> Bool {
        guard let old = entry.oldGroup else { return false }
        if let existing = groups.first(where: { $0.name == old }) {
            entry.groups.insert(existing.uuid)
        } else {
            let group = VaultGroup(name: old)
            groups.append(group)
            entry.groups.insert(group.uuid)
        }
        entry.oldGroup = nil
        return true
    }

    /// The subset of groups referenced by at least one entry (`getUsedGroups`).
    func usedGroups() -> [VaultGroup] {
        var used = Set<UUID>()
        for entry in entries { used.formUnion(entry.groups) }
        return groups.filter { used.contains($0.uuid) }
    }

    // MARK: - JSON coercion helpers

    /// `obj.getInt(key)`: throws if absent or not coercible to an int.
    private static func requiredInt(_ obj: JSONObject, _ key: String) throws -> Int {
        guard let value = obj[key], !(value is NSNull) else {
            throw AegisError.vault("missing '\(key)'")
        }
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let i = Int(s) { return i }
        throw AegisError.vault("'\(key)' is not an integer")
    }

    /// `obj.optBoolean(key)` (no default): true only for an explicit boolean/`"true"`.
    private static func optBooleanNoDefault(_ obj: JSONObject, _ key: String) -> Bool {
        guard let value = obj[key], !(value is NSNull) else { return false }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String, s.caseInsensitiveCompare("true") == .orderedSame { return true }
        return false
    }
}

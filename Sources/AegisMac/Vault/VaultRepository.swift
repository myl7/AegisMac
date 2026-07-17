import Foundation

/// App-facing vault store (`VaultRepository.java`). Owns the in-memory `Vault` and
/// the (optional) credentials needed to re-encrypt it on save. Not an
/// `ObservableObject` — the UI wraps it in `AppState`.
final class VaultRepository {
    /// `~/Library/Application Support/AegisMac/aegis.json`.
    static var defaultVaultURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("AegisMac", isDirectory: true)
            .appendingPathComponent("aegis.json", isDirectory: false)
    }

    private(set) var vault: Vault
    private(set) var credentials: VaultFileCredentials?

    var isEncrypted: Bool { credentials != nil }

    init(vault: Vault, credentials: VaultFileCredentials?) {
        self.vault = vault
        self.credentials = credentials
    }

    // MARK: Loading

    static func fileExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }

    static func loadFile(at url: URL) throws -> VaultFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AegisError.vault("could not read vault file: \(error.localizedDescription)")
        }
        return try VaultFile.fromData(data)
    }

    /// Unlocks an encrypted vault file with a password.
    static func unlock(file: VaultFile, password: String) throws -> VaultRepository {
        guard let slots = file.header.slots else {
            throw AegisError.vault("vault file is not encrypted")
        }
        let masterKey = try slots.unlock(password: password)
        let content = try file.getContent(masterKey: masterKey)
        let vault = try Vault.fromJson(content)
        let creds = VaultFileCredentials(slots: slots, masterKey: masterKey)
        return VaultRepository(vault: vault, credentials: creds)
    }

    /// Loads a plaintext vault file.
    static func loadPlain(file: VaultFile) throws -> VaultRepository {
        let content = try file.getPlainContent()
        let vault = try Vault.fromJson(content)
        return VaultRepository(vault: vault, credentials: nil)
    }

    /// Creates a brand-new, empty vault. `password == nil` yields a plaintext vault;
    /// otherwise a fresh master key is wrapped by a new password slot (default
    /// scrypt params, random 32-byte salt).
    static func createNew(password: String?) throws -> VaultRepository {
        let vault = Vault()
        guard let password = password else {
            return VaultRepository(vault: vault, credentials: nil)
        }
        let masterKey = MasterKey.generate()
        let slot = try PasswordSlot.create(password: password, masterKey: masterKey)
        let creds = VaultFileCredentials(slots: SlotList(slots: [slot]), masterKey: masterKey)
        return VaultRepository(vault: vault, credentials: creds)
    }

    // MARK: Saving

    /// Serializes the vault (encrypting if credentials are present) and writes it
    /// atomically to `url` with `0600` permissions.
    func save(to url: URL) throws {
        let file = try VaultFile.make(vault: vault, credentials: credentials)
        let data = try file.toData()
        try VaultRepository.atomicWrite(data, to: url)
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let tempURL = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tempURL.path,
                            contents: data,
                            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
            throw AegisError.vault("failed to write temporary vault file")
        }

        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw AegisError.vault("failed to save vault: \(error.localizedDescription)")
        }

        // Ensure the final file is owner-only readable/writable.
        try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                              ofItemAtPath: url.path)
    }

    // MARK: Export

    /// A plaintext vault-file serialization (`aegis-export-plain`).
    func exportPlain() throws -> Data {
        return try VaultFile.make(vault: vault, credentials: nil).toData()
    }

    /// An encrypted vault-file serialization protected by `password`. Builds a fresh
    /// slot list containing a single new password slot (biometric slots are always
    /// stripped); the vault's existing master key is reused when available.
    func exportEncrypted(password: String) throws -> Data {
        let masterKey = credentials?.masterKey ?? MasterKey.generate()
        let slot = try PasswordSlot.create(password: password, masterKey: masterKey)
        // A freshly-built single-password slot list has no biometric slots, but run
        // exportable() anyway to honor the import/export spec's stripping rule.
        let slots = SlotList(slots: [slot]).exportable()
        let creds = VaultFileCredentials(slots: slots, masterKey: masterKey)
        return try VaultFile.make(vault: vault, credentials: creds).toData()
    }

    // MARK: Entry mutations

    /// Appends an entry (migrating a legacy group first, like the Android app).
    func addEntry(_ entry: VaultEntry) {
        vault.migrateOldGroup(entry)
        guard !vault.entries.contains(where: { $0.uuid == entry.uuid }) else { return }
        vault.entries.append(entry)
    }

    func removeEntry(_ entry: VaultEntry) {
        vault.entries.removeAll { $0.uuid == entry.uuid }
    }

    /// Replaces the entry with the same UUID in place (preserving its position); a
    /// previously-unknown UUID is appended.
    func updateEntry(_ entry: VaultEntry) {
        if let idx = vault.entries.firstIndex(where: { $0.uuid == entry.uuid }) {
            vault.entries[idx] = entry
        } else {
            vault.entries.append(entry)
        }
    }

    /// Moves the entry at `from` to index `to` (remove-then-insert list semantics,
    /// matching `UUIDMap.move` / `CollectionUtils.move`).
    func moveEntry(from: Int, to: Int) {
        guard from >= 0, from < vault.entries.count,
              to >= 0, to < vault.entries.count, from != to else { return }
        let item = vault.entries.remove(at: from)
        vault.entries.insert(item, at: to)
    }

    // MARK: Group mutations

    func addGroup(_ group: VaultGroup) {
        guard !vault.groups.contains(where: { $0.uuid == group.uuid }) else { return }
        vault.groups.append(group)
    }

    /// Removes a group, first stripping its UUID from every entry.
    func removeGroup(_ group: VaultGroup) {
        removeGroup(uuid: group.uuid)
    }

    func removeGroup(uuid: UUID) {
        for entry in vault.entries {
            entry.groups.remove(uuid)
        }
        vault.groups.removeAll { $0.uuid == uuid }
    }

    func renameGroup(_ group: VaultGroup, to newName: String) {
        renameGroup(uuid: group.uuid, to: newName)
    }

    func renameGroup(uuid: UUID, to newName: String) {
        if let idx = vault.groups.firstIndex(where: { $0.uuid == uuid }) {
            vault.groups[idx].name = newName
        }
    }

    func findGroup(byName name: String) -> VaultGroup? {
        return vault.groups.first { $0.name == name }
    }
}

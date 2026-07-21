import Foundation

/// High-level import/export flows: reading an Aegis vault file (plaintext or
/// password-encrypted), importing a newline-separated `otpauth://` URI list, and
/// exporting entries back out as a URI list. Mirrors `AegisImporter` /
/// `GoogleAuthUriImporter` / `VaultRepository.exportGoogleUris`.
enum ImportExport {

    /// Reads an Aegis `.json` vault file and returns its decoded `Vault`. Only the
    /// entries are imported (a merge); the source file's encryption credentials are
    /// intentionally discarded, matching upstream `ImportEntriesActivity`. Vault
    /// encryption is managed separately in the Security settings.
    /// - `password`: required when the file is encrypted; ignored for plaintext.
    static func importVaultFile(data: Data, password: String?) throws -> Vault {
        let file = try VaultFile.fromData(data)

        let content: JSONObject
        if file.isEncrypted {
            guard let password = password, !password.isEmpty else {
                throw AegisError.importError("This vault is encrypted; a password is required")
            }
            guard let slots = file.header.slots else {
                throw AegisError.importError("Encrypted vault is missing its key slots")
            }
            let masterKey = try slots.unlock(password: password)
            content = try file.getContent(masterKey: masterKey)
        } else {
            content = try file.getPlainContent()
        }

        return try Vault.fromJson(content)
    }

    /// Parses a newline-separated list of `otpauth://` URIs (one per non-blank
    /// line) into `VaultEntry` values. Throws on the first line that fails to parse.
    static func importUriList(text: String) throws -> [VaultEntry] {
        var entries: [VaultEntry] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            let info = try GoogleAuthInfo.parseUri(line)
            entries.append(info.toVaultEntry())
        }
        return entries
    }

    /// Serializes entries to a newline-separated list of `otpauth://` URIs, one
    /// per entry (`VaultRepository.exportGoogleUris`).
    static func exportUriList(entries: [VaultEntry]) -> String {
        return entries.map { entry in
            GoogleAuthInfo(info: entry.info, accountName: entry.name, issuer: entry.issuer).getUri()
        }.joined(separator: "\n")
    }
}

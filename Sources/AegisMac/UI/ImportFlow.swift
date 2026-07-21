import Foundation
import AppKit

// MARK: - Import / export orchestration (uses Import/Export module contract APIs)

extension AppState {
    /// Parse raw QR payloads (otpauth:// and otpauth-migration://) into entries and add them.
    /// Returns the number of entries imported. Throws AegisError on the first bad payload.
    @discardableResult
    func importScannedPayloads(_ payloads: [String]) throws -> Int {
        var added = 0
        for payload in payloads {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.lowercased().hasPrefix("otpauth-migration://") {
                let infos = try GoogleAuthMigration.parse(uri: trimmed)
                for info in infos { addEntry(info.toVaultEntry()); added += 1 }
            } else {
                let info = try GoogleAuthInfo.parseUri(trimmed)
                addEntry(info.toVaultEntry())
                added += 1
            }
        }
        return added
    }

    /// Scan all screens for QR codes and import any found. Returns count.
    @discardableResult
    func scanScreenAndImport() async -> Result<Int, Error> {
        do {
            let payloads = try await QRScanner.scanScreen()
            if payloads.isEmpty { return .success(0) }
            let n = try importScannedPayloads(payloads)
            return .success(n)
        } catch {
            return .failure(error)
        }
    }

    /// Scan an image file for QR codes and import any found.
    @discardableResult
    func scanImageAndImport(url: URL) -> Result<Int, Error> {
        do {
            let payloads = try QRScanner.scan(imageURL: url)
            if payloads.isEmpty { return .success(0) }
            let n = try importScannedPayloads(payloads)
            return .success(n)
        } catch {
            return .failure(error)
        }
    }

    /// Import an Aegis vault file (encrypted or plaintext) or a URI-list .txt, merging entries.
    func importVaultOrUriFile(url: URL, password: String?) throws -> Int {
        let data = try Data(contentsOf: url)
        // Try a plain-text otpauth URI list first (each non-blank line is an otpauth URI).
        if url.pathExtension.lowercased() == "txt",
           let text = String(data: data, encoding: .utf8) {
            let entries = try ImportExport.importUriList(text: text)
            for e in entries { addEntry(e) }
            return entries.count
        }
        // Import is a merge: only entries are added, and the vault keeps its own
        // encryption state (matching upstream). To encrypt a plaintext vault or
        // change its password, use the Security settings.
        let vault = try ImportExport.importVaultFile(data: data, password: password)
        var count = 0
        for e in vault.entries { addEntry(e); count += 1 }
        return count
    }

    // MARK: Export

    func exportPlain() throws -> Data {
        guard let repo = repository else { throw AegisError.vault("Vault not open") }
        return try repo.exportPlain()
    }

    func exportEncrypted(password: String) throws -> Data {
        guard let repo = repository else { throw AegisError.vault("Vault not open") }
        return try repo.exportEncrypted(password: password)
    }

    func exportUriList() -> String {
        guard let repo = repository else { return "" }
        return ImportExport.exportUriList(entries: repo.vault.entries)
    }
}

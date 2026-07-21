import SwiftUI
import AppKit

// MARK: - Settings scene content

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.palette) private var palette

    // Prefs not mirrored as @Published on AppState — kept as local state, written through.
    @State private var tapToRevealTime = 30
    @State private var searchFields = SearchFields.default
    @State private var groupsMultiselect = false
    @State private var focusSearch = false
    @State private var touchIDEnabled = false

    // Touch ID enable prompt
    @State private var showTouchIDPrompt = false
    @State private var touchIDPassword = ""
    @State private var touchIDError: String?

    // Vault password (set / change) + remove-encryption confirm
    private enum PasswordMode { case set, change }
    @State private var passwordMode: PasswordMode = .set
    @State private var showSetPasswordSheet = false
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordError: String?
    @State private var showRemovePasswordConfirm = false

    // Import / export
    @State private var showImportSheet = false
    @State private var showEncryptExportPrompt = false
    @State private var exportPassword = ""
    @State private var actionMessage: String?

    var body: some View {
        TabView {
            appearanceTab.tabItem { Label("Appearance", systemImage: "paintbrush") }
            behaviorTab.tabItem { Label("Behavior", systemImage: "hand.tap") }
            securityTab.tabItem { Label("Security", systemImage: "lock") }
            dataTab.tabItem { Label("Import / Export", systemImage: "square.and.arrow.up.on.square") }
        }
        .frame(width: 460, height: 460)
        .onAppear {
            tapToRevealTime = app.prefs.tapToRevealTime
            searchFields = app.prefs.searchFields
            groupsMultiselect = app.prefs.groupsMultiselect
            focusSearch = app.prefs.focusSearch
            touchIDEnabled = app.prefs.touchIDEnabled
        }
    }

    // MARK: Appearance

    private var appearanceTab: some View {
        Form {
            Picker("Theme", selection: $app.theme) {
                ForEach(ThemeMode.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("View mode", selection: $app.viewMode) {
                ForEach(ViewMode.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Code grouping", selection: $app.codeGrouping) {
                ForEach(CodeGrouping.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Account name", selection: $app.accountNamePosition) {
                ForEach(AccountNamePosition.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Show icons", isOn: $app.showIcons)
            Toggle("Show next code", isOn: $app.showNextCode)
            Toggle("Show expiration state", isOn: $app.showExpirationState)
            Toggle("Only show account name when shared", isOn: $app.onlyShowNecessaryAccountNames)
        }
        .padding()
    }

    // MARK: Behavior

    private var behaviorTab: some View {
        Form {
            Picker("Tap behavior", selection: $app.copyBehavior) {
                ForEach(CopyBehavior.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Tap to reveal", isOn: $app.tapToReveal)
            Stepper("Reveal for \(tapToRevealTime) s", value: $tapToRevealTime, in: 1...300)
                .onChange(of: tapToRevealTime) { _, v in app.prefs.tapToRevealTime = v }
                .disabled(!app.tapToReveal)

            Section("Search fields") {
                searchFieldToggle("Issuer", .issuer)
                searchFieldToggle("Account name", .name)
                searchFieldToggle("Note", .note)
                searchFieldToggle("Group names", .groups)
            }

            Toggle("Multi-select groups", isOn: $groupsMultiselect)
                .onChange(of: groupsMultiselect) { _, v in app.prefs.groupsMultiselect = v }
            Toggle("Focus search on open", isOn: $focusSearch)
                .onChange(of: focusSearch) { _, v in app.prefs.focusSearch = v }
        }
        .padding()
    }

    private func searchFieldToggle(_ title: String, _ field: SearchFields) -> some View {
        Toggle(title, isOn: Binding(
            get: { searchFields.contains(field) },
            set: { on in
                if on { searchFields.insert(field) } else { searchFields.remove(field) }
                app.prefs.searchFields = searchFields
            }
        ))
    }

    // MARK: Security

    private var securityTab: some View {
        Form {
            Section("Encryption") {
                if app.isEncrypted {
                    Text("This vault is password-protected.")
                        .font(.caption).foregroundColor(palette.onSurfaceDimColor)
                    Button("Change password…") { presentPasswordSheet(.change) }
                    Button("Remove password…", role: .destructive) { showRemovePasswordConfirm = true }
                } else {
                    Text("This vault is not encrypted. Set a password to protect it and to use Touch ID.")
                        .font(.caption).foregroundColor(palette.onSurfaceDimColor)
                    Button("Set password…") { presentPasswordSheet(.set) }
                }
            }

            Section("Touch ID") {
                Toggle("Unlock with Touch ID", isOn: Binding(
                    get: { touchIDEnabled },
                    set: { on in
                        if on {
                            if KeychainHelper.biometricsAvailable() {
                                showTouchIDPrompt = true
                            } else {
                                touchIDError = "Touch ID is not available on this Mac"
                            }
                        } else {
                            app.disableTouchID()
                            touchIDEnabled = false
                        }
                    }
                ))
                .disabled(!app.isEncrypted)
                if !app.isEncrypted {
                    Text("Touch ID is only available for password-protected vaults.")
                        .font(.caption).foregroundColor(palette.onSurfaceDimColor)
                }
                if let touchIDError = touchIDError {
                    Text(touchIDError).foregroundColor(palette.errorColor).font(.caption)
                }
            }
        }
        .padding()
        .sheet(isPresented: $showTouchIDPrompt) {
            passwordPrompt(title: "Confirm vault password",
                           text: $touchIDPassword,
                           onCancel: { showTouchIDPrompt = false; touchIDPassword = "" },
                           onConfirm: {
                                if app.enableTouchID(password: touchIDPassword) {
                                    touchIDEnabled = true
                                    touchIDError = nil
                                } else {
                                    touchIDError = "Could not store the key in the keychain: \(KeychainHelper.lastStoreErrorMessage())"
                                }
                                touchIDPassword = ""
                                showTouchIDPrompt = false
                           })
        }
        .sheet(isPresented: $showSetPasswordSheet) { setPasswordSheet }
        .alert("Remove password?", isPresented: $showRemovePasswordConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                do {
                    try app.removeVaultPassword()
                    touchIDEnabled = false
                    touchIDError = nil
                } catch { touchIDError = errorText(error) }
            }
        } message: {
            Text("The vault will be stored unencrypted on disk, and Touch ID will be turned off.")
        }
    }

    private func presentPasswordSheet(_ mode: PasswordMode) {
        passwordMode = mode
        newPassword = ""
        confirmPassword = ""
        passwordError = nil
        showSetPasswordSheet = true
    }

    // Set-password / change-password sheet (password + confirmation).
    private var setPasswordSheet: some View {
        VStack(spacing: 16) {
            Text(passwordMode == .set ? "Set vault password" : "Change vault password").font(.headline)
            SecureField("New password", text: $newPassword)
                .textFieldStyle(.roundedBorder).frame(width: 240)
            SecureField("Confirm password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit(submitPassword)
            if let passwordError = passwordError {
                Text(passwordError).foregroundColor(palette.errorColor).font(.caption)
            }
            HStack {
                Button("Cancel") { showSetPasswordSheet = false }
                Button("OK", action: submitPassword)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    private func submitPassword() {
        guard !newPassword.isEmpty else { passwordError = "Password required"; return }
        guard newPassword == confirmPassword else { passwordError = "Passwords do not match"; return }
        do {
            switch passwordMode {
            case .set:
                try app.setVaultPassword(newPassword)
            case .change:
                try app.changeVaultPassword(newPassword)
                touchIDEnabled = false   // Touch ID was cleared; it stored the old password
            }
            actionMessage = nil
            showSetPasswordSheet = false
            newPassword = ""; confirmPassword = ""; passwordError = nil
        } catch {
            passwordError = errorText(error)
        }
    }

    // MARK: Data (import / export)

    private var dataTab: some View {
        Form {
            Section("Export") {
                Button("Export encrypted vault…") { showEncryptExportPrompt = true }
                    .disabled(app.repository == nil)
                Button("Export plaintext vault…") { exportPlain() }
                    .disabled(app.repository == nil)
                Button("Export otpauth URI list…") { exportUriList() }
                    .disabled(app.repository == nil)
            }
            Section("Import") {
                Button("Import from file…") { importFromFile() }
                    .disabled(app.repository == nil)
            }
            if let actionMessage = actionMessage {
                Text(actionMessage).foregroundColor(palette.onSurfaceDimColor).font(.caption)
            }
        }
        .padding()
        .sheet(isPresented: $showEncryptExportPrompt) {
            passwordPrompt(title: "Export password",
                           text: $exportPassword,
                           onCancel: { showEncryptExportPrompt = false; exportPassword = "" },
                           onConfirm: {
                                exportEncrypted(password: exportPassword)
                                exportPassword = ""
                                showEncryptExportPrompt = false
                           })
        }
        .sheet(isPresented: $showImportSheet) { importRetrySheet }
    }

    // MARK: Export/import actions

    private func savePanel(name: String, ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func exportPlain() {
        guard let url = savePanel(name: "aegis-export-plain.json", ext: "json") else { return }
        do { try app.exportPlain().write(to: url); actionMessage = "Exported plaintext vault." }
        catch { actionMessage = errorText(error) }
    }

    private func exportEncrypted(password: String) {
        guard !password.isEmpty else { actionMessage = "Password required"; return }
        guard let url = savePanel(name: "aegis-export.json", ext: "json") else { return }
        do { try app.exportEncrypted(password: password).write(to: url); actionMessage = "Exported encrypted vault." }
        catch { actionMessage = errorText(error) }
    }

    private func exportUriList() {
        guard let url = savePanel(name: "aegis-uris.txt", ext: "txt") else { return }
        do { try Data(app.exportUriList().utf8).write(to: url); actionMessage = "Exported URI list." }
        catch { actionMessage = errorText(error) }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Try without a password first; if it fails, ask for one.
        do {
            let n = try app.importVaultOrUriFile(url: url, password: nil)
            actionMessage = "Imported \(n) \(n == 1 ? "entry" : "entries")."
        } catch {
            // Prompt for a password and retry.
            pendingImportURL = url
            showImportSheet = true
        }
    }

    @State private var pendingImportURL: URL?
    @State private var importPassword = ""

    // Present the retry password prompt for encrypted imports.
    private var importRetrySheet: some View {
        passwordPrompt(title: "Vault password", text: $importPassword,
                       onCancel: { showImportSheet = false; importPassword = ""; pendingImportURL = nil },
                       onConfirm: {
                            if let url = pendingImportURL {
                                do {
                                    let n = try app.importVaultOrUriFile(url: url, password: importPassword)
                                    actionMessage = "Imported \(n) \(n == 1 ? "entry" : "entries")."
                                } catch { actionMessage = errorText(error) }
                            }
                            showImportSheet = false; importPassword = ""; pendingImportURL = nil
                       })
    }

    private func errorText(_ error: Error) -> String {
        (error as? AegisError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Reusable password prompt

    private func passwordPrompt(title: String,
                                text: Binding<String>,
                                onCancel: @escaping () -> Void,
                                onConfirm: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            SecureField("Password", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(onConfirm)
            HStack {
                Button("Cancel", action: onCancel)
                Button("OK", action: onConfirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 300)
    }
}

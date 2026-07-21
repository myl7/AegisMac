import SwiftUI
import Combine
import AppKit

// MARK: - OtpInfo display helpers (extensions on the OTP module's contract types)

extension OtpInfo {
    /// Generate the current code, returning the literal "ERROR" string on failure
    /// (matches Android's behavior for legacy empty-secret entries).
    func codeString(at seconds: Int64) -> String {
        (try? getOtp(time: seconds)) ?? CodeFormatter.errorString
    }

    /// Steam and Yandex codes are never grouped.
    var isGroupingDisabled: Bool { self is SteamInfo || self is YandexInfo }

    /// The TOTP period, or nil for HOTP.
    var totpPeriod: Int? { (self as? TotpInfo)?.period }

    var isHotp: Bool { self is HotpInfo }
    var isTotpFamily: Bool { self is TotpInfo }
}

// MARK: - DisplayEntry (a VaultEntry decorated with usage stats for sorting)

struct DisplayEntry: Identifiable, EntrySortable {
    let entry: VaultEntry
    let usageCount: Int
    let lastUsed: Int64

    var id: UUID { entry.uuid }
    var sortAttributes: SortAttributes {
        SortAttributes(name: entry.name,
                       issuer: entry.issuer,
                       favorite: entry.favorite,
                       usageCount: usageCount,
                       lastUsed: lastUsed)
    }
}

// MARK: - App launch state

enum LaunchState: Equatable {
    case loading
    case onboarding          // no vault file yet
    case locked              // encrypted vault, awaiting unlock
    case unlocked            // vault open
    case error(String)
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {
    let prefs: Preferences

    // Vault
    @Published private(set) var repository: VaultRepository?
    @Published var launchState: LaunchState = .loading
    @Published private(set) var loadedFile: VaultFile?   // held while locked, for unlock

    // Time
    @Published var nowSeconds: Int64 = Int64(Date().timeIntervalSince1970)
    var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // List UI state
    @Published var searchText: String = ""
    @Published var isSearching: Bool = false
    @Published var groupFilter: Set<UUID> = []
    @Published var filterIncludesUngrouped: Bool = false
    @Published var selectedEntry: UUID?

    // Reveal / copy feedback
    @Published var revealedEntry: UUID?
    @Published var copiedEntry: UUID?
    private var doubleTapArmedEntry: UUID?

    // Mirrored preference values (write-through to Preferences)
    @Published var theme: ThemeMode { didSet { prefs.theme = theme } }
    @Published var viewMode: ViewMode { didSet { prefs.viewMode = viewMode } }
    @Published var sortCategory: SortCategory { didSet { prefs.sortCategory = sortCategory } }
    @Published var codeGrouping: CodeGrouping { didSet { prefs.codeGrouping = codeGrouping } }
    @Published var accountNamePosition: AccountNamePosition { didSet { prefs.accountNamePosition = accountNamePosition } }
    @Published var showNextCode: Bool { didSet { prefs.showNextCode = showNextCode } }
    @Published var showExpirationState: Bool { didSet { prefs.showExpirationState = showExpirationState } }
    @Published var showIcons: Bool { didSet { prefs.showIcons = showIcons } }
    @Published var tapToReveal: Bool { didSet { prefs.tapToReveal = tapToReveal } }
    @Published var copyBehavior: CopyBehavior { didSet { prefs.copyBehavior = copyBehavior } }
    @Published var onlyShowNecessaryAccountNames: Bool { didSet { prefs.onlyShowNecessaryAccountNames = onlyShowNecessaryAccountNames } }

    // Transient error banner
    @Published var errorMessage: String?

    private var timer: Timer?
    private var systemLockObserver: NSObjectProtocol?

    var vaultURL: URL = VaultRepository.defaultVaultURL

    init(prefs: Preferences = .shared) {
        self.prefs = prefs
        self.theme = prefs.theme
        self.viewMode = prefs.viewMode
        self.sortCategory = prefs.sortCategory
        self.codeGrouping = prefs.codeGrouping
        self.accountNamePosition = prefs.accountNamePosition
        self.showNextCode = prefs.showNextCode
        self.showExpirationState = prefs.showExpirationState
        self.showIcons = prefs.showIcons
        self.tapToReveal = prefs.tapToReveal
        self.copyBehavior = prefs.copyBehavior
        self.onlyShowNecessaryAccountNames = prefs.onlyShowNecessaryAccountNames
        let f = prefs.getGroupFilter()
        self.groupFilter = f.uuids
        self.filterIncludesUngrouped = f.includeUngrouped
        observeSystemLock()
    }

    /// Lock an unlocked vault when the macOS session locks (screen lock / lock
    /// screen). App quit needs no handling — the on-disk vault is always encrypted,
    /// so the next launch starts locked. Closing the window does not lock.
    private func observeSystemLock() {
        systemLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lockForSystemLock() }
        }
    }

    /// Lock the vault in response to a system lock, if it is currently unlocked and
    /// encrypted (a plaintext vault has nothing to lock).
    func lockForSystemLock() {
        guard isEncrypted, case .unlocked = launchState else { return }
        lock()
    }

    // MARK: Bootstrap

    func bootstrap() {
        // Run the initial load only once. Reopening the window re-fires
        // RootView.onAppear; without this guard an already-open (unlocked) vault
        // would re-lock just because its window was closed and reopened, even though
        // the app never quit. Locking happens on quit (the on-disk vault is always
        // encrypted) and on system lock — not on window close.
        guard case .loading = launchState else { return }

        if !VaultRepository.fileExists(at: vaultURL) {
            launchState = prefs.introDone ? .onboarding : .onboarding
            return
        }
        do {
            let file = try VaultRepository.loadFile(at: vaultURL)
            loadedFile = file
            if file.isEncrypted {
                launchState = .locked
            } else {
                repository = try VaultRepository.loadPlain(file: file)
                launchState = .unlocked
                startTimer()
            }
        } catch {
            launchState = .error((error as? AegisError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Unlock / lock

    func unlock(password: String) throws {
        guard let file = loadedFile else { throw AegisError.vault("No vault file loaded") }
        let repo = try VaultRepository.unlock(file: file, password: password)
        repository = repo
        launchState = .unlocked
        startTimer()
    }

    /// Touch ID unlock: prompt for biometrics, retrieve the stored password from the
    /// keychain, and unlock. Uses only the password unlock path (contract API); no
    /// biometric vault slot is used.
    func unlockWithTouchID() async throws {
        guard let data = await KeychainHelper.retrieveSecret(),
              let password = String(data: data, encoding: .utf8) else {
            throw AegisError.crypto("Touch ID unlock was cancelled or unavailable")
        }
        try unlock(password: password)
    }

    /// Store the given password behind biometrics so the vault can be unlocked with Touch ID.
    func enableTouchID(password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        let ok = KeychainHelper.store(secret: data)
        prefs.touchIDEnabled = ok
        return ok
    }

    func disableTouchID() {
        KeychainHelper.deleteKey()
        prefs.touchIDEnabled = false
    }

    var touchIDAvailable: Bool {
        prefs.touchIDEnabled && KeychainHelper.hasStoredKey() && KeychainHelper.biometricsAvailable()
    }

    // MARK: Vault encryption / password (mirrors upstream SecurityPreferencesFragment)

    /// Encrypt a plaintext vault with `password`, then persist it. After this the
    /// vault is password-protected and Touch ID can be enabled.
    func setVaultPassword(_ password: String) throws {
        guard let repo = repository else { throw AegisError.vault("Vault not open") }
        try repo.enableEncryption(password: password)
        try repo.save(to: vaultURL)
        objectWillChange.send()
    }

    /// Change the master password of an encrypted vault. Any Touch ID entry is
    /// cleared because it stored the previous password; re-enable it afterward.
    func changeVaultPassword(_ newPassword: String) throws {
        guard let repo = repository else { throw AegisError.vault("Vault not open") }
        try repo.changePassword(newPassword: newPassword)
        try repo.save(to: vaultURL)
        if prefs.touchIDEnabled { disableTouchID() }
        objectWillChange.send()
    }

    /// Remove the password from an encrypted vault, turning it back into plaintext.
    /// Any Touch ID entry is cleared.
    func removeVaultPassword() throws {
        guard let repo = repository else { throw AegisError.vault("Vault not open") }
        repo.disableEncryption()
        try repo.save(to: vaultURL)
        if prefs.touchIDEnabled { disableTouchID() }
        objectWillChange.send()
    }

    /// Create a brand-new vault (password = nil → plaintext) and open it.
    func createNewVault(password: String?) throws {
        try ensureVaultDirectory()
        let repo = try VaultRepository.createNew(password: password)
        try repo.save(to: vaultURL)
        repository = repo
        prefs.introDone = true
        launchState = .unlocked
        startTimer()
    }

    /// Import an existing Aegis export file as the app's vault (copies it to the vault path,
    /// then reloads — an encrypted file will land on the unlock screen).
    func importVaultFileAsNew(url: URL) throws {
        try ensureVaultDirectory()
        let data = try Data(contentsOf: url)
        // Validate it parses as a vault file before adopting it.
        _ = try VaultFile.fromData(data)
        try data.write(to: vaultURL, options: .atomic)
        prefs.introDone = true
        bootstrap()
    }

    private func ensureVaultDirectory() throws {
        let dir = vaultURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func lock() {
        stopTimer()
        repository = nil
        revealedEntry = nil
        copiedEntry = nil
        selectedEntry = nil
        searchText = ""
        isSearching = false
        // Reload the file so we can unlock again.
        if let file = try? VaultRepository.loadFile(at: vaultURL) {
            loadedFile = file
            launchState = file.isEncrypted ? .locked : .unlocked
            if !file.isEncrypted, let repo = try? VaultRepository.loadPlain(file: file) {
                repository = repo
                startTimer()
            }
        }
    }

    var isEncrypted: Bool { repository?.isEncrypted ?? (loadedFile?.isEncrypted ?? false) }

    // MARK: Timer (1 Hz code + progress refresh; paused when window hidden)

    func startTimer() {
        stopTimer()
        nowSeconds = Int64(Date().timeIntervalSince1970)
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.nowSeconds = Int64(Date().timeIntervalSince1970)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Palette

    func palette(systemIsDark: Bool) -> Palette {
        ResolvedTheme.palette(for: theme, systemIsDark: systemIsDark)
    }
    var forcedColorScheme: ColorScheme? { ResolvedTheme.colorScheme(for: theme) }

    // MARK: Groups

    var allGroups: [VaultGroup] { repository?.vault.groups ?? [] }

    func groupName(for uuid: UUID) -> String? {
        allGroups.first { $0.uuid == uuid }?.name
    }

    func groupNames(for entry: VaultEntry) -> [String] {
        entry.groups.compactMap { groupName(for: $0) }
    }

    // MARK: Shown entries pipeline (model-store spec §7, §9)

    var shownEntries: [DisplayEntry] {
        guard let repo = repository else { return [] }
        let usage = prefs.getUsageCounts()
        let lastUsed = prefs.getLastUsedTimestamps()

        // Determine which issuers are shared (for onlyShowNecessaryAccountNames).
        let all = repo.vault.entries

        var filtered = all
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespaces)
        if isSearching && !trimmedQuery.isEmpty {
            // Search bypasses the group filter.
            filtered = all.filter { entry in
                SearchMatcher.matches(query: trimmedQuery,
                                      issuer: entry.issuer,
                                      name: entry.name,
                                      note: entry.note,
                                      groupNames: groupNames(for: entry),
                                      fields: prefs.searchFields)
            }
        } else {
            filtered = all.filter { entry in
                GroupFilterMatcher.isVisible(entryGroups: entry.groups,
                                             filterUUIDs: groupFilter,
                                             includeUngrouped: filterIncludesUngrouped)
            }
        }

        let display = filtered.map { entry in
            DisplayEntry(entry: entry,
                         usageCount: usage[entry.uuid] ?? 0,
                         lastUsed: lastUsed[entry.uuid] ?? 0)
        }
        return EntrySorter.sorted(display, category: sortCategory)
    }

    /// Whether the account name should be shown for this entry, honoring "only when necessary".
    func shouldShowAccountName(for entry: VaultEntry) -> Bool {
        if accountNamePosition == .hidden { return false }
        guard onlyShowNecessaryAccountNames else { return true }
        guard let repo = repository else { return true }
        let sameIssuer = repo.vault.entries.filter {
            $0.issuer.caseInsensitiveCompare(entry.issuer) == .orderedSame && !entry.issuer.isEmpty
        }
        return sameIssuer.count >= 2
    }

    /// The number of shown favorites (top slice).
    var shownFavoritesCount: Int { shownEntries.prefix { $0.entry.favorite }.count }

    /// Whether drag-reorder is allowed: CUSTOM sort, no group filter, no active search.
    var canReorder: Bool {
        sortCategory == .custom
            && groupFilter.isEmpty && !filterIncludesUngrouped
            && !(isSearching && !searchText.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: Uniform-period detection (ui-style spec §4)

    /// Returns the dominant TOTP period if the visible TOTP entries are "uniform"
    /// (a single period shared by more than one entry), else nil (mixed → per-card bars).
    var dominantPeriod: Int? {
        let periods = shownEntries.compactMap { $0.entry.info.totpPeriod }
        guard !periods.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for p in periods { counts[p, default: 0] += 1 }
        guard let (period, count) = counts.max(by: { $0.value < $1.value }) else { return nil }
        return count > 1 ? period : nil
    }

    // MARK: Copy / reveal interactions

    func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Copy an entry's current code, show the 3 s "Copied" animation, and bump usage stats.
    func copyCode(_ entry: VaultEntry, offset: Int = 0) {
        let period = entry.info.totpPeriod ?? 0
        let time = nowSeconds + Int64(offset) * Int64(period)
        let raw = entry.info.codeString(at: time)
        copyToPasteboard(raw)
        prefs.incrementUsage(entry.uuid, now: nowMillis)
        objectWillChange.send()
        showCopied(entry.uuid)
    }

    private func showCopied(_ uuid: UUID) {
        copiedEntry = uuid
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if copiedEntry == uuid { copiedEntry = nil }
        }
    }

    /// Handle a primary click/tap on a row, honoring reveal + copy-behavior settings.
    func handleTap(_ entry: VaultEntry) {
        selectedEntry = entry.uuid

        // Tap-to-reveal: first tap reveals (and re-hides the previous), and does not copy.
        if tapToReveal && revealedEntry != entry.uuid {
            reveal(entry)
            if copyBehavior == .singleTap { return }
        }

        switch copyBehavior {
        case .never:
            break
        case .singleTap:
            copyCode(entry)
        case .doubleTap:
            if doubleTapArmedEntry == entry.uuid {
                doubleTapArmedEntry = nil
                copyCode(entry)
            } else {
                doubleTapArmedEntry = entry.uuid
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if doubleTapArmedEntry == entry.uuid { doubleTapArmedEntry = nil }
                }
            }
        }
    }

    /// Native macOS double-click on a row: always copy the code (and reveal it when
    /// tap-to-reveal is on), independent of the tap copy-behavior preference. macOS
    /// users expect a double-click to act, so this works even when copy-behavior is
    /// "Never" or "Double tap".
    func handleDoubleTap(_ entry: VaultEntry) {
        selectedEntry = entry.uuid
        if tapToReveal { reveal(entry) }
        copyCode(entry)
    }

    func reveal(_ entry: VaultEntry) {
        revealedEntry = entry.uuid
        let seconds = max(1, prefs.tapToRevealTime)
        let uuid = entry.uuid
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            if revealedEntry == uuid { revealedEntry = nil }
        }
    }

    func isRevealed(_ entry: VaultEntry) -> Bool {
        !tapToReveal || revealedEntry == entry.uuid
    }

    /// Copy the currently-selected entry's code (⌘C).
    func copySelected() {
        guard let sel = selectedEntry,
              let entry = repository?.vault.entries.first(where: { $0.uuid == sel }) else { return }
        copyCode(entry)
    }

    // MARK: Mutations

    func save() {
        guard let repo = repository else { return }
        do {
            try repo.save(to: vaultURL)
        } catch {
            errorMessage = (error as? AegisError)?.errorDescription ?? error.localizedDescription
        }
    }

    func addEntry(_ entry: VaultEntry) {
        repository?.addEntry(entry)
        save()
        objectWillChange.send()
    }

    func updateEntry(_ entry: VaultEntry) {
        repository?.updateEntry(entry)
        save()
        objectWillChange.send()
    }

    func deleteEntry(_ entry: VaultEntry) {
        repository?.removeEntry(entry)
        if selectedEntry == entry.uuid { selectedEntry = nil }
        save()
        objectWillChange.send()
    }

    func toggleFavorite(_ entry: VaultEntry) {
        entry.favorite.toggle()
        repository?.updateEntry(entry)
        save()
        objectWillChange.send()
    }

    func incrementHotp(_ entry: VaultEntry) {
        guard let hotp = entry.info as? HotpInfo else { return }
        hotp.incrementCounter()
        repository?.updateEntry(entry)
        save()
        objectWillChange.send()
    }

    func moveEntry(from source: Int, to destination: Int) {
        repository?.moveEntry(from: source, to: destination)
        save()
        objectWillChange.send()
    }

    // Groups
    func addGroup(name: String) {
        let group = VaultGroup(uuid: UUID(), name: name)
        repository?.addGroup(group)
        save()
        objectWillChange.send()
    }

    func removeGroup(_ group: VaultGroup) {
        repository?.removeGroup(group)
        groupFilter.remove(group.uuid)
        persistGroupFilter()
        save()
        objectWillChange.send()
    }

    func setGroups(_ groups: Set<UUID>, for entry: VaultEntry) {
        entry.groups = groups
        repository?.updateEntry(entry)
        save()
        objectWillChange.send()
    }

    // MARK: Group filter persistence

    func persistGroupFilter() {
        prefs.setGroupFilter(uuids: groupFilter, includeUngrouped: filterIncludesUngrouped)
    }

    func selectGroupFilter(uuid: UUID?, multiselect: Bool) {
        if let uuid = uuid {
            if multiselect {
                if groupFilter.contains(uuid) { groupFilter.remove(uuid) } else { groupFilter.insert(uuid) }
            } else {
                groupFilter = [uuid]
                filterIncludesUngrouped = false
            }
        } else {
            // "No group" toggle
            if multiselect {
                filterIncludesUngrouped.toggle()
            } else {
                groupFilter = []
                filterIncludesUngrouped = true
            }
        }
        persistGroupFilter()
        objectWillChange.send()
    }

    func clearGroupFilter() {
        groupFilter = []
        filterIncludesUngrouped = false
        persistGroupFilter()
        objectWillChange.send()
    }

    var hasActiveGroupFilter: Bool { !groupFilter.isEmpty || filterIncludesUngrouped }
}

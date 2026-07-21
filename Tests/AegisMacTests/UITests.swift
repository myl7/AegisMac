import XCTest
import AppKit
@testable import AegisMac

// Pure-logic tests for the UI layer: code grouping, hidden masking, search token matching,
// group filter, sort comparators (incl. favorite float), theme palette hex, and the letter avatar.

final class UITests: XCTestCase {

    // MARK: - Code grouping (ui-style spec §5.1)

    func testGroupingThrees() {
        XCTAssertEqual(CodeFormatter.group("012345", grouping: .threes), "012 345")
        XCTAssertEqual(CodeFormatter.group("12345678", grouping: .threes), "123 456 78")
    }

    func testGroupingTwos() {
        XCTAssertEqual(CodeFormatter.group("012345", grouping: .twos), "01 23 45")
    }

    func testGroupingFours() {
        XCTAssertEqual(CodeFormatter.group("01234567", grouping: .fours), "0123 4567")
    }

    func testGroupingNone() {
        XCTAssertEqual(CodeFormatter.group("012345", grouping: .noGrouping), "012345")
    }

    func testGroupingHalves() {
        // len 6 -> ceil(3) per group -> "012 345"
        XCTAssertEqual(CodeFormatter.group("012345", grouping: .halves), "012 345")
        // len 5 -> ceil(3) -> "012 34"
        XCTAssertEqual(CodeFormatter.group("01234", grouping: .halves), "012 34")
        // len 7 -> ceil(4) -> "0123 456"
        XCTAssertEqual(CodeFormatter.group("0123456", grouping: .halves), "0123 456")
    }

    func testGroupingDisabledForSteamYandex() {
        // Steam/Yandex codes are never grouped.
        XCTAssertEqual(CodeFormatter.group("12345", grouping: .threes, disabled: true), "12345")
        XCTAssertEqual(CodeFormatter.group("BYNPB55555", grouping: .threes, disabled: true), "BYNPB55555")
    }

    func testErrorConstant() {
        XCTAssertEqual(CodeFormatter.errorString, "ERROR")
    }

    // MARK: - Hidden masking (ui-style spec §5.3)

    func testHiddenPreservesSpaces() {
        let hidden = CodeFormatter.hidden("012 345")
        XCTAssertEqual(hidden, "\u{25CF}\u{25CF}\u{25CF} \u{25CF}\u{25CF}\u{25CF}")
        XCTAssertEqual(hidden.count, 7)
        XCTAssertEqual(hidden.filter { $0 == " " }.count, 1)
    }

    func testHiddenNoSpaces() {
        XCTAssertEqual(CodeFormatter.hidden("12345"), String(repeating: "\u{25CF}", count: 5))
    }

    // MARK: - Search token matching (model-store spec §9)

    func testSearchAllTokensMustMatch() {
        // "git hub" -> both tokens found in "github"
        XCTAssertTrue(SearchMatcher.matches(query: "git hub", issuer: "GitHub", name: "alice",
                                            note: "", groupNames: [], fields: .default))
        // token not present anywhere
        XCTAssertFalse(SearchMatcher.matches(query: "git xyz", issuer: "GitHub", name: "alice",
                                             note: "", groupNames: [], fields: .default))
    }

    func testSearchCaseInsensitive() {
        XCTAssertTrue(SearchMatcher.matches(query: "GITHUB", issuer: "github", name: "",
                                            note: "", groupNames: [], fields: .default))
    }

    func testSearchEmptyQueryMatches() {
        XCTAssertTrue(SearchMatcher.matches(query: "   ", issuer: "x", name: "y",
                                            note: "", groupNames: [], fields: .default))
    }

    func testSearchFieldMaskRespected() {
        // "secret" is only in the note; default mask excludes note -> no match.
        XCTAssertFalse(SearchMatcher.matches(query: "secret", issuer: "GitHub", name: "alice",
                                             note: "my secret", groupNames: [], fields: .default))
        // enable note -> match
        XCTAssertTrue(SearchMatcher.matches(query: "secret", issuer: "GitHub", name: "alice",
                                            note: "my secret", groupNames: [],
                                            fields: [.issuer, .name, .note]))
    }

    func testSearchGroupNames() {
        XCTAssertFalse(SearchMatcher.matches(query: "work", issuer: "GitHub", name: "alice",
                                             note: "", groupNames: ["Work"], fields: .default))
        XCTAssertTrue(SearchMatcher.matches(query: "work", issuer: "GitHub", name: "alice",
                                            note: "", groupNames: ["Work"],
                                            fields: [.issuer, .name, .groups]))
    }

    // MARK: - Group filter (model-store spec §9)

    func testGroupFilterEmptyShowsAll() {
        XCTAssertTrue(GroupFilterMatcher.isVisible(entryGroups: [], filterUUIDs: [], includeUngrouped: false))
        XCTAssertTrue(GroupFilterMatcher.isVisible(entryGroups: [UUID()], filterUUIDs: [], includeUngrouped: false))
    }

    func testGroupFilterUngrouped() {
        let g = UUID()
        // filter active, entry ungrouped, ungrouped not included -> hidden
        XCTAssertFalse(GroupFilterMatcher.isVisible(entryGroups: [], filterUUIDs: [g], includeUngrouped: false))
        // ungrouped included, entry ungrouped -> visible
        XCTAssertTrue(GroupFilterMatcher.isVisible(entryGroups: [], filterUUIDs: [], includeUngrouped: true))
    }

    func testGroupFilterMembership() {
        let a = UUID(), b = UUID()
        XCTAssertTrue(GroupFilterMatcher.isVisible(entryGroups: [a], filterUUIDs: [a, b], includeUngrouped: false))
        XCTAssertFalse(GroupFilterMatcher.isVisible(entryGroups: [b], filterUUIDs: [a], includeUngrouped: false))
    }

    // MARK: - Sorting (model-store spec §7)

    private struct MockEntry: EntrySortable {
        let attrs: SortAttributes
        var sortAttributes: SortAttributes { attrs }
        init(_ name: String, issuer: String = "", favorite: Bool = false, usage: Int = 0, lastUsed: Int64 = 0) {
            attrs = SortAttributes(name: name, issuer: issuer, favorite: favorite, usageCount: usage, lastUsed: lastUsed)
        }
    }

    private func names(_ arr: [MockEntry]) -> [String] { arr.map { $0.attrs.name } }

    func testCiCompare() {
        XCTAssertEqual(EntrySorter.ciCompare("apple", "Apple"), 0)
        XCTAssertLessThan(EntrySorter.ciCompare("a", "b"), 0)
        XCTAssertGreaterThan(EntrySorter.ciCompare("b", "a"), 0)
        XCTAssertLessThan(EntrySorter.ciCompare("apple", "apples"), 0)
    }

    func testCustomSortFavoriteFloat() {
        // insertion order deliberately non-alphabetical
        let input = [
            MockEntry("date", favorite: true),
            MockEntry("apple", favorite: true),
            MockEntry("cherry", favorite: false),
            MockEntry("banana", favorite: false)
        ]
        let out = EntrySorter.sorted(input, category: .custom)
        XCTAssertEqual(names(out), ["date", "apple", "cherry", "banana"])
    }

    func testAccountSortFavoriteFloat() {
        let input = [
            MockEntry("date", favorite: true),
            MockEntry("apple", favorite: true),
            MockEntry("cherry", favorite: false),
            MockEntry("banana", favorite: false)
        ]
        let out = EntrySorter.sorted(input, category: .account)
        XCTAssertEqual(names(out), ["apple", "date", "banana", "cherry"])
    }

    func testAccountReversed() {
        let input = [
            MockEntry("apple", favorite: false),
            MockEntry("banana", favorite: false),
            MockEntry("cherry", favorite: false)
        ]
        let out = EntrySorter.sorted(input, category: .accountReversed)
        XCTAssertEqual(names(out), ["cherry", "banana", "apple"])
    }

    func testIssuerSort() {
        let input = [
            MockEntry("z", issuer: "Bravo"),
            MockEntry("a", issuer: "Alpha"),
            MockEntry("m", issuer: "Alpha")
        ]
        let out = EntrySorter.sorted(input, category: .issuer)
        // by issuer then name: Alpha/a, Alpha/m, Bravo/z
        XCTAssertEqual(names(out), ["a", "m", "z"])
    }

    func testUsageCountDescending() {
        let input = [
            MockEntry("low", usage: 1),
            MockEntry("high", usage: 100),
            MockEntry("mid", usage: 10)
        ]
        let out = EntrySorter.sorted(input, category: .usageCount)
        XCTAssertEqual(names(out), ["high", "mid", "low"])
    }

    func testLastUsedDescending() {
        let input = [
            MockEntry("old", lastUsed: 100),
            MockEntry("new", lastUsed: 999),
            MockEntry("mid", lastUsed: 500)
        ]
        let out = EntrySorter.sorted(input, category: .lastUsed)
        XCTAssertEqual(names(out), ["new", "mid", "old"])
    }

    func testFavoriteFloatWithUsage() {
        let input = [
            MockEntry("a", favorite: false, usage: 100),
            MockEntry("b", favorite: true, usage: 1),
            MockEntry("c", favorite: true, usage: 50)
        ]
        let out = EntrySorter.sorted(input, category: .usageCount)
        // favorites first (by usage desc), then non-favorites
        XCTAssertEqual(names(out), ["c", "b", "a"])
    }

    // MARK: - Theme palette hex (ui-style spec §1)

    func testLightPalette() {
        let p = Palette.light
        XCTAssertEqual(p.code, "2b5bb5")
        XCTAssertEqual(p.codeHidden, "c5c6d0")
        XCTAssertEqual(p.progressbar, "2b5bb5")
        XCTAssertEqual(p.favorite, "f9a825")
        XCTAssertEqual(p.background, "fefbff")
        XCTAssertEqual(p.surface, "fbf8fd")
        XCTAssertEqual(p.surfaceContainer, "efedf1")
        XCTAssertEqual(p.onSurfaceDim, "9d9ea2")
    }

    func testDarkPalette() {
        let p = Palette.dark
        XCTAssertEqual(p.code, "b0c6ff")
        XCTAssertEqual(p.codeHidden, "44464f")
        XCTAssertEqual(p.progressbar, "2b5bb5")
        XCTAssertEqual(p.favorite, "f9a825")
        XCTAssertEqual(p.background, "1b1b1f")
        XCTAssertEqual(p.surface, "131316")
        XCTAssertEqual(p.surfaceContainer, "1f1f23")
        XCTAssertEqual(p.onSurfaceDim, "616371")
    }

    func testAmoledPalette() {
        let p = Palette.amoled
        XCTAssertEqual(p.code, "ffffff")
        XCTAssertEqual(p.codeHidden, "2f2f2f")
        XCTAssertEqual(p.progressbar, "ffffff")
        XCTAssertEqual(p.favorite, "f9a825")
        XCTAssertEqual(p.background, "000000")
        XCTAssertEqual(p.surface, "000000")
        XCTAssertEqual(p.surfaceContainer, "000000")
    }

    func testThemeResolution() {
        XCTAssertEqual(ResolvedTheme.palette(for: .system, systemIsDark: true), Palette.dark)
        XCTAssertEqual(ResolvedTheme.palette(for: .system, systemIsDark: false), Palette.light)
        XCTAssertEqual(ResolvedTheme.palette(for: .systemAmoled, systemIsDark: true), Palette.amoled)
        XCTAssertEqual(ResolvedTheme.palette(for: .systemAmoled, systemIsDark: false), Palette.light)
        XCTAssertEqual(ResolvedTheme.palette(for: .amoled, systemIsDark: false), Palette.amoled)
    }

    func testCardFill() {
        // Compact uses surface; other modes use surfaceContainer.
        XCTAssertEqual(Palette.light.cardFill(.compact), Palette.light.surfaceColor)
        XCTAssertEqual(Palette.light.cardFill(.normal), Palette.light.surfaceContainerColor)
    }

    // MARK: - Letter avatar (TextDrawableHelper.java + ColorGenerator.java)

    func testJavaHashCode() {
        XCTAssertEqual(LetterAvatar.javaHashCode(""), 0)
        XCTAssertEqual(LetterAvatar.javaHashCode("a"), 97)
        XCTAssertEqual(LetterAvatar.javaHashCode("A"), 65)
        XCTAssertEqual(LetterAvatar.javaHashCode("ab"), 3105)   // 97*31 + 98
    }

    func testAvatarPaletteSize() {
        XCTAssertEqual(LetterAvatar.palette.count, 19)
    }

    func testAvatarColorDeterministic() {
        // "a".hashCode() = 97; 97 % 19 = 2 -> palette[2]
        XCTAssertEqual(LetterAvatar.colorHex(for: "a"), LetterAvatar.palette[2])
        XCTAssertEqual(LetterAvatar.colorHex(for: "a"), "7b1fa2")
    }

    func testAvatarLetterAndSource() {
        // issuer wins when present
        let a = LetterAvatar.avatar(issuer: "GitHub", name: "alice")
        XCTAssertEqual(a?.letter, "G")
        // falls back to name when issuer empty
        let b = LetterAvatar.avatar(issuer: "", name: "alice")
        XCTAssertEqual(b?.letter, "A")
        // nil when both empty
        XCTAssertNil(LetterAvatar.avatar(issuer: "", name: ""))
    }

    // MARK: - Preference enums (model-store spec §10)

    func testCodeGroupingNames() {
        XCTAssertEqual(CodeGrouping.threes.rawName, "GROUPING_THREES")
        XCTAssertEqual(CodeGrouping.fromName("GROUPING_THREES"), .threes)
        XCTAssertEqual(CodeGrouping.fromName("HALVES"), .halves)
        XCTAssertEqual(CodeGrouping.fromName("NO_GROUPING"), .noGrouping)
        XCTAssertEqual(CodeGrouping.fromName("unknown"), .threes)   // default fallback
        XCTAssertEqual(CodeGrouping.halves.rawValue, -1)
        XCTAssertEqual(CodeGrouping.noGrouping.rawValue, -2)
    }

    func testSearchFieldsDefault() {
        XCTAssertEqual(SearchFields.default.rawValue, 3)   // ISSUER | NAME
    }

    func testViewModeLayout() {
        XCTAssertEqual(ViewMode.compact.itemOffset, 1)
        XCTAssertEqual(ViewMode.tiles.itemOffset, 4)
        XCTAssertEqual(ViewMode.normal.itemOffset, 8)
        XCTAssertEqual(ViewMode.small.itemOffset, 8)
        XCTAssertEqual(ViewMode.tiles.spanCount, 2)
        XCTAssertEqual(ViewMode.normal.spanCount, 1)
        XCTAssertEqual(ViewMode.tiles.formattedAccountName("x"), "x")
        XCTAssertEqual(ViewMode.normal.formattedAccountName("x"), "(x)")
    }

    func testEnumOrdinalsMatchAndroid() {
        XCTAssertEqual(ThemeMode.system.rawValue, 3)
        XCTAssertEqual(ViewMode.normal.rawValue, 0)
        XCTAssertEqual(AccountNamePosition.end.rawValue, 1)
        XCTAssertEqual(CopyBehavior.never.rawValue, 0)
        XCTAssertEqual(SortCategory.custom.rawValue, 0)
        XCTAssertEqual(SortCategory.lastUsed.rawValue, 6)
    }

    // MARK: - Preferences persistence round-trips (isolated UserDefaults)

    private func freshPrefs() -> Preferences {
        let suite = "aegis.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return Preferences(defaults: defaults)
    }

    func testPrefsDefaults() {
        let p = freshPrefs()
        XCTAssertEqual(p.theme, .system)
        XCTAssertEqual(p.viewMode, .normal)
        XCTAssertEqual(p.codeGrouping, .threes)
        XCTAssertEqual(p.accountNamePosition, .end)
        XCTAssertEqual(p.copyBehavior, .never)
        XCTAssertEqual(p.sortCategory, .custom)
        XCTAssertTrue(p.showIcons)
        XCTAssertFalse(p.showNextCode)
        XCTAssertTrue(p.showExpirationState)
        XCTAssertFalse(p.tapToReveal)
        XCTAssertEqual(p.tapToRevealTime, 30)
        XCTAssertEqual(p.searchFields.rawValue, 3)
    }

    func testUsageCountRoundTrip() {
        let p = freshPrefs()
        let a = UUID(), b = UUID()
        p.setUsageCounts([a: 12, b: 3])
        XCTAssertEqual(p.getUsageCount(a), 12)
        XCTAssertEqual(p.getUsageCount(b), 3)
        XCTAssertEqual(p.getUsageCount(UUID()), 0)
        p.incrementUsage(a, now: 1000)
        XCTAssertEqual(p.getUsageCount(a), 13)
        XCTAssertEqual(p.getLastUsedTimestamp(a), 1000)
    }

    func testGroupFilterRoundTrip() {
        let p = freshPrefs()
        let g = UUID()
        p.setGroupFilter(uuids: [g], includeUngrouped: true)
        let f = p.getGroupFilter()
        XCTAssertTrue(f.uuids.contains(g))
        XCTAssertTrue(f.includeUngrouped)
    }

    // MARK: - Double-click to copy (native macOS affordance)

    /// A double-click must copy the code even when the tap copy-behavior is the
    /// default "Never" (so single clicks never copy). Regression for the reported
    /// "double-click doesn't copy the 2FA code" bug.
    @MainActor
    func testDoubleTapCopiesCodeWhenCopyBehaviorNever() throws {
        let prefs = freshPrefs()
        prefs.copyBehavior = .never
        let app = AppState(prefs: prefs)
        XCTAssertEqual(app.copyBehavior, .never)

        let info = try TotpInfo(secret: Data([1, 2, 3, 4, 5]), algorithm: "SHA1", digits: 6, period: 30)
        let entry = VaultEntry(name: "acct", issuer: "Example", info: info)
        let fixedTime: Int64 = 1_700_000_000
        app.nowSeconds = fixedTime

        let pb = NSPasteboard.general
        pb.clearContents()

        app.handleDoubleTap(entry)

        let expected = try info.getOtp(time: fixedTime)
        XCTAssertEqual(pb.string(forType: .string), expected, "double-click should copy the current code")
        XCTAssertEqual(app.selectedEntry, entry.uuid)
        XCTAssertEqual(app.copiedEntry, entry.uuid, "the Copied feedback should be shown")
        XCTAssertEqual(prefs.getUsageCount(entry.uuid), 1, "copy should bump usage stats")
    }

    // MARK: - Lock behavior (window close vs. quit / system lock)

    @MainActor
    private func makeAppWithEncryptedVault(password: String) throws -> AppState {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aegis-lock-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("aegis.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let repo = try VaultRepository.createNew(password: password)
        try repo.save(to: url)

        let app = AppState(prefs: freshPrefs())
        app.vaultURL = url
        return app
    }

    /// Reopening the window (which re-fires `bootstrap`) must not re-lock an already
    /// unlocked vault. Regression for "closing the window locks the vault".
    @MainActor
    func testReopeningWindowDoesNotRelockUnlockedVault() throws {
        let app = try makeAppWithEncryptedVault(password: "pw")

        app.bootstrap()
        XCTAssertEqual(app.launchState, .locked)

        try app.unlock(password: "pw")
        app.stopTimer()
        XCTAssertEqual(app.launchState, .unlocked)

        // Simulate the window being closed and reopened.
        app.bootstrap()
        XCTAssertEqual(app.launchState, .unlocked, "reopening the window must not re-lock")
    }

    /// A system lock must lock an unlocked encrypted vault.
    @MainActor
    func testSystemLockLocksUnlockedVault() throws {
        let app = try makeAppWithEncryptedVault(password: "pw")
        app.bootstrap()
        try app.unlock(password: "pw")
        app.stopTimer()
        XCTAssertEqual(app.launchState, .unlocked)

        app.lockForSystemLock()
        XCTAssertEqual(app.launchState, .locked, "system lock should lock the vault")
    }

    /// A plaintext vault has nothing to lock; a system lock leaves it unlocked.
    @MainActor
    func testSystemLockIsNoOpForPlaintextVault() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aegis-lock-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("aegis.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let repo = try VaultRepository.createNew(password: nil)
        try repo.save(to: url)

        let app = AppState(prefs: freshPrefs())
        app.vaultURL = url
        app.bootstrap()
        app.stopTimer()
        XCTAssertEqual(app.launchState, .unlocked)

        app.lockForSystemLock()
        XCTAssertEqual(app.launchState, .unlocked, "a plaintext vault should not lock")
    }
}

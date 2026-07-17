import Foundation

// MARK: - Enums mirroring the Android app (model-store spec §10)

/// pref_current_theme ordinals. AMOLED = pure-black dark.
enum ThemeMode: Int, CaseIterable, Identifiable {
    case light = 0
    case dark = 1
    case amoled = 2
    case system = 3
    case systemAmoled = 4

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .amoled: return "AMOLED"
        case .system: return "Follow system"
        case .systemAmoled: return "Follow system (AMOLED)"
        }
    }
}

/// pref_current_view_mode ordinals. Default NORMAL.
enum ViewMode: Int, CaseIterable, Identifiable {
    case normal = 0
    case compact = 1
    case small = 2
    case tiles = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .compact: return "Compact"
        case .small: return "Small"
        case .tiles: return "Tiles"
        }
    }

    /// Inter-item spacing in points (dp). COMPACT=1, TILES=4, else 8.
    var itemOffset: CGFloat {
        switch self {
        case .compact: return 1
        case .tiles: return 4
        default: return 8
        }
    }

    /// Grid columns. TILES=2, else 1.
    var spanCount: Int { self == .tiles ? 2 : 1 }

    /// Wrap an account name for display in this mode. TILES shows raw, others wrap "(name)".
    func formattedAccountName(_ name: String) -> String {
        self == .tiles ? name : "(\(name))"
    }

    // Layout dimensions (ui-style spec §3.2)
    var iconSize: CGFloat {
        switch self {
        case .normal: return 60
        case .compact, .small: return 45
        case .tiles: return 24
        }
    }
    var issuerFontSize: CGFloat {
        switch self {
        case .normal: return 16
        case .compact, .small: return 13
        case .tiles: return 11
        }
    }
    var codeFontSize: CGFloat { self == .normal ? 34 : 26 }
    var nextCodeFontSize: CGFloat { self == .normal ? 20 : 16 }
    var progressBarHeight: CGFloat { self == .normal ? 4 : 3 }
    var rowVerticalPadding: CGFloat {
        switch self {
        case .normal: return 8
        case .compact: return 3
        case .small: return 5
        case .tiles: return 0
        }
    }
}

/// pref_account_name_position ordinals. Default END.
enum AccountNamePosition: Int, CaseIterable, Identifiable {
    case hidden = 0
    case end = 1
    case below = 2

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .hidden: return "Hidden"
        case .end: return "Next to issuer"
        case .below: return "Below issuer"
        }
    }
}

/// pref_current_copy_behavior ordinals. Default NEVER.
enum CopyBehavior: Int, CaseIterable, Identifiable {
    case never = 0
    case singleTap = 1
    case doubleTap = 2

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .never: return "Never"
        case .singleTap: return "Single tap"
        case .doubleTap: return "Double tap"
        }
    }
}

/// pref_current_sort_category ordinals. Default CUSTOM. (model-store spec §7)
enum SortCategory: Int, CaseIterable, Identifiable {
    case custom = 0
    case account = 1
    case accountReversed = 2
    case issuer = 3
    case issuerReversed = 4
    case usageCount = 5
    case lastUsed = 6

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .custom: return "Custom"
        case .account: return "A → Z (name)"
        case .accountReversed: return "Z → A (name)"
        case .issuer: return "A → Z (issuer)"
        case .issuerReversed: return "Z → A (issuer)"
        case .usageCount: return "Most used"
        case .lastUsed: return "Last used"
        }
    }
}

/// pref_code_group_size_string — stored as the enum *name* string. Default GROUPING_THREES.
enum CodeGrouping: Int, CaseIterable, Identifiable {
    case halves = -1
    case noGrouping = -2
    case twos = 2
    case threes = 3
    case fours = 4

    var id: Int { rawValue }

    /// The Android enum name(), used verbatim as the stored string value.
    var rawName: String {
        switch self {
        case .halves: return "HALVES"
        case .noGrouping: return "NO_GROUPING"
        case .twos: return "GROUPING_TWOS"
        case .threes: return "GROUPING_THREES"
        case .fours: return "GROUPING_FOURS"
        }
    }

    var displayName: String {
        switch self {
        case .halves: return "Halves"
        case .noGrouping: return "No grouping"
        case .twos: return "Groups of 2"
        case .threes: return "Groups of 3"
        case .fours: return "Groups of 4"
        }
    }

    static func fromName(_ name: String) -> CodeGrouping {
        allCases.first { $0.rawName == name } ?? .threes
    }
}

/// Search-field bitmask (model-store spec §9). Default ISSUER | NAME = 3.
struct SearchFields: OptionSet {
    let rawValue: Int
    static let issuer = SearchFields(rawValue: 1)
    static let name = SearchFields(rawValue: 2)
    static let note = SearchFields(rawValue: 4)
    static let groups = SearchFields(rawValue: 8)
    static let `default`: SearchFields = [.issuer, .name]
}

// MARK: - Preferences (UserDefaults-backed, Android key parity)

/// UserDefaults-backed preferences mirroring Android SharedPreferences keys/defaults
/// (model-store spec §10). Enum prefs stored as ordinal ints, except code grouping (name string).
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults
    // Extra macOS-only key (not present on Android): whether Touch ID unlock is enabled.
    static let touchIDKey = "pref_macos_touchid"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyCopyOnTap()
    }

    // Helper: read int with a fallback used only when the key is absent.
    private func int(_ key: String, default def: Int) -> Int {
        defaults.object(forKey: key) == nil ? def : defaults.integer(forKey: key)
    }
    private func bool(_ key: String, default def: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? def : defaults.bool(forKey: key)
    }
    private func string(_ key: String, default def: String) -> String {
        defaults.object(forKey: key) as? String ?? def
    }

    // MARK: Appearance
    var theme: ThemeMode {
        get { ThemeMode(rawValue: int("pref_current_theme", default: 3)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "pref_current_theme") }
    }

    // MARK: List layout
    var viewMode: ViewMode {
        get { ViewMode(rawValue: int("pref_current_view_mode", default: 0)) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "pref_current_view_mode") }
    }

    // MARK: Code display
    var codeGrouping: CodeGrouping {
        get { CodeGrouping.fromName(string("pref_code_group_size_string", default: "GROUPING_THREES")) }
        set { defaults.set(newValue.rawName, forKey: "pref_code_group_size_string") }
    }
    var showNextCode: Bool {
        get { bool("pref_show_next_code", default: false) }
        set { defaults.set(newValue, forKey: "pref_show_next_code") }
    }
    var showExpirationState: Bool {
        get { bool("pref_expiration_state", default: true) }
        set { defaults.set(newValue, forKey: "pref_expiration_state") }
    }
    var showIcons: Bool {
        get { bool("pref_show_icons", default: true) }
        set { defaults.set(newValue, forKey: "pref_show_icons") }
    }
    var accountNamePosition: AccountNamePosition {
        get { AccountNamePosition(rawValue: int("pref_account_name_position", default: 1)) ?? .end }
        set { defaults.set(newValue.rawValue, forKey: "pref_account_name_position") }
    }
    var onlyShowNecessaryAccountNames: Bool {
        get { bool("pref_shared_issuer_account_name", default: false) }
        set { defaults.set(newValue, forKey: "pref_shared_issuer_account_name") }
    }

    // MARK: Reveal / highlight
    var tapToReveal: Bool {
        get { bool("pref_tap_to_reveal", default: false) }
        set { defaults.set(newValue, forKey: "pref_tap_to_reveal") }
    }
    var tapToRevealTime: Int {
        get { int("pref_tap_to_reveal_time", default: 30) }
        set { defaults.set(newValue, forKey: "pref_tap_to_reveal_time") }
    }
    var highlightEntry: Bool {
        get { bool("pref_highlight_entry", default: false) }
        set { defaults.set(newValue, forKey: "pref_highlight_entry") }
    }

    // MARK: Sorting / filtering
    var sortCategory: SortCategory {
        get { SortCategory(rawValue: int("pref_current_sort_category", default: 0)) ?? .custom }
        set { defaults.set(newValue.rawValue, forKey: "pref_current_sort_category") }
    }
    var searchFields: SearchFields {
        get { SearchFields(rawValue: int("pref_search_behavior_mask", default: 3)) }
        set { defaults.set(newValue.rawValue, forKey: "pref_search_behavior_mask") }
    }
    var groupsMultiselect: Bool {
        get { bool("pref_groups_multiselect", default: false) }
        set { defaults.set(newValue, forKey: "pref_groups_multiselect") }
    }
    var focusSearch: Bool {
        get { bool("pref_focus_search", default: false) }
        set { defaults.set(newValue, forKey: "pref_focus_search") }
    }

    // MARK: Copy behavior
    var copyBehavior: CopyBehavior {
        get { CopyBehavior(rawValue: int("pref_current_copy_behavior", default: 0)) ?? .never }
        set { defaults.set(newValue.rawValue, forKey: "pref_current_copy_behavior") }
    }

    // MARK: App flow
    var introDone: Bool {
        get { bool("pref_intro", default: false) }
        set { defaults.set(newValue, forKey: "pref_intro") }
    }
    var timeout: Int {
        get { int("pref_timeout", default: -1) }
        set { defaults.set(newValue, forKey: "pref_timeout") }
    }

    // MARK: Touch ID (macOS-only addition)
    var touchIDEnabled: Bool {
        get { bool(Preferences.touchIDKey, default: false) }
        set { defaults.set(newValue, forKey: Preferences.touchIDKey) }
    }

    // MARK: - Group filter (model-store spec §9)
    // JSON array of UUID strings; a JSON `null` element means "ungrouped".

    /// Returns the filter set of group UUIDs plus a bool for whether "ungrouped" is included.
    func getGroupFilter() -> (uuids: Set<UUID>, includeUngrouped: Bool) {
        let raw = string("pref_group_filter_uuids", default: "")
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return ([], false)
        }
        var uuids = Set<UUID>()
        var includeUngrouped = false
        for el in arr {
            if el is NSNull {
                includeUngrouped = true
            } else if let s = el as? String, let u = UUID(uuidString: s) {
                uuids.insert(u)
            }
        }
        return (uuids, includeUngrouped)
    }

    func setGroupFilter(uuids: Set<UUID>, includeUngrouped: Bool) {
        var arr: [Any] = uuids.map { $0.uuidString.lowercased() }
        if includeUngrouped { arr.append(NSNull()) }
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let s = String(data: data, encoding: .utf8) {
            defaults.set(s, forKey: "pref_group_filter_uuids")
        }
    }

    // MARK: - Usage counts (model-store spec §8)
    // pref_usage_count: JSON array of {"uuid": <uuid>, "count": <int>}

    func getUsageCounts() -> [UUID: Int] {
        let raw = string("pref_usage_count", default: "")
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var map = [UUID: Int]()
        for obj in arr {
            if let s = obj["uuid"] as? String, let u = UUID(uuidString: s),
               let c = (obj["count"] as? NSNumber)?.intValue {
                map[u] = c
            }
        }
        return map
    }

    func getUsageCount(_ uuid: UUID) -> Int { getUsageCounts()[uuid] ?? 0 }

    func setUsageCounts(_ map: [UUID: Int]) {
        let arr: [[String: Any]] = map.map { ["uuid": $0.key.uuidString.lowercased(), "count": $0.value] }
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let s = String(data: data, encoding: .utf8) {
            defaults.set(s, forKey: "pref_usage_count")
        }
    }

    func resetUsageCount(_ uuid: UUID) {
        var map = getUsageCounts()
        map[uuid] = 0
        setUsageCounts(map)
    }

    func clearUsageCounts() { defaults.removeObject(forKey: "pref_usage_count") }

    // MARK: - Last-used timestamps (model-store spec §8)
    // pref_last_used_timestamps: JSON array of {"uuid": <uuid>, "timestamp": <long ms>}

    func getLastUsedTimestamps() -> [UUID: Int64] {
        let raw = string("pref_last_used_timestamps", default: "")
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var map = [UUID: Int64]()
        for obj in arr {
            if let s = obj["uuid"] as? String, let u = UUID(uuidString: s),
               let t = (obj["timestamp"] as? NSNumber)?.int64Value {
                map[u] = t
            }
        }
        return map
    }

    func getLastUsedTimestamp(_ uuid: UUID) -> Int64 { getLastUsedTimestamps()[uuid] ?? 0 }

    func setLastUsedTimestamps(_ map: [UUID: Int64]) {
        let arr: [[String: Any]] = map.map { ["uuid": $0.key.uuidString.lowercased(), "timestamp": NSNumber(value: $0.value)] }
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let s = String(data: data, encoding: .utf8) {
            defaults.set(s, forKey: "pref_last_used_timestamps")
        }
    }

    /// Increment usage count (absent→1, else +1) and set last-used to `now` (epoch ms).
    func incrementUsage(_ uuid: UUID, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        var counts = getUsageCounts()
        counts[uuid] = (counts[uuid] ?? 0) + 1
        setUsageCounts(counts)
        var stamps = getLastUsedTimestamps()
        stamps[uuid] = now
        setLastUsedTimestamps(stamps)
    }

    // MARK: - Legacy migration
    // Legacy boolean pref_copy_on_tap true → CopyBehavior.SINGLETAP, then delete old key.
    private func migrateLegacyCopyOnTap() {
        guard defaults.object(forKey: "pref_copy_on_tap") != nil else { return }
        if defaults.bool(forKey: "pref_copy_on_tap") {
            defaults.set(CopyBehavior.singleTap.rawValue, forKey: "pref_current_copy_behavior")
        }
        defaults.removeObject(forKey: "pref_copy_on_tap")
    }
}

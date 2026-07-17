import Foundation

// MARK: - Code grouping (ui-style spec §5.1)

enum CodeFormatter {
    /// The literal string shown when OTP generation fails (legacy empty-secret entries).
    static let errorString = "ERROR"

    /// Bullet used to mask hidden codes (U+25CF). Spaces are preserved.
    static let bullet: Character = "\u{25CF}"

    /// Group the raw OTP digits with single spaces per the CodeGrouping mode.
    /// A space is inserted before every index that is a positive multiple of the group size.
    /// Steam and Yandex codes are never grouped — pass `disabled: true` for those.
    static func group(_ code: String, grouping: CodeGrouping, disabled: Bool = false) -> String {
        if disabled { return code }
        let chars = Array(code)
        let len = chars.count
        if len == 0 { return code }

        let groupSize: Int
        switch grouping {
        case .noGrouping:
            groupSize = len
        case .halves:
            groupSize = (len / 2) + (len % 2)   // ceil(len/2)
        default:
            groupSize = grouping.rawValue        // 2 / 3 / 4
        }
        guard groupSize > 0 else { return code }

        var out = ""
        out.reserveCapacity(len + len / max(groupSize, 1))
        for (i, ch) in chars.enumerated() {
            if i != 0 && i % groupSize == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// Replace each non-space glyph of a (grouped) code with the bullet, preserving spaces.
    static func hidden(_ groupedCode: String) -> String {
        String(groupedCode.map { $0 == " " ? " " : bullet })
    }
}

// MARK: - Search matching (model-store spec §9)

enum SearchMatcher {
    /// Token-AND, case-insensitive `contains` over the enabled fields.
    /// The query is lowercased and split on whitespace; an entry matches iff *every* token
    /// is found in at least one enabled field.
    static func matches(query: String,
                        issuer: String,
                        name: String,
                        note: String,
                        groupNames: [String],
                        fields: SearchFields) -> Bool {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.isEmpty { return true }

        var haystacks: [String] = []
        if fields.contains(.issuer) { haystacks.append(issuer.lowercased()) }
        if fields.contains(.name) { haystacks.append(name.lowercased()) }
        if fields.contains(.note) { haystacks.append(note.lowercased()) }
        if fields.contains(.groups) { haystacks.append(contentsOf: groupNames.map { $0.lowercased() }) }

        for token in tokens {
            if !haystacks.contains(where: { $0.contains(token) }) {
                return false
            }
        }
        return true
    }
}

// MARK: - Group filter (model-store spec §9)

enum GroupFilterMatcher {
    /// Returns true if the entry should be **shown** given a group filter.
    /// An empty filter (no uuids and not including ungrouped) shows everything.
    static func isVisible(entryGroups: Set<UUID>,
                          filterUUIDs: Set<UUID>,
                          includeUngrouped: Bool) -> Bool {
        if filterUUIDs.isEmpty && !includeUngrouped { return true }
        if entryGroups.isEmpty {
            return includeUngrouped
        }
        // has groups: visible if any of its groups is in the filter set
        return !entryGroups.isDisjoint(with: filterUUIDs)
    }
}

// MARK: - Sorting (model-store spec §7)

/// Attributes needed to sort an entry, independent of the vault model so the comparator is
/// unit-testable without the Vault module.
struct SortAttributes {
    var name: String
    var issuer: String
    var favorite: Bool
    var usageCount: Int
    var lastUsed: Int64
}

protocol EntrySortable {
    var sortAttributes: SortAttributes { get }
}

enum EntrySorter {
    /// Locale-independent case-insensitive compare mirroring Java `compareToIgnoreCase`
    /// (ASCII fold). Returns negative / 0 / positive.
    static func ciCompare(_ a: String, _ b: String) -> Int {
        let aa = Array(a.unicodeScalars)
        let bb = Array(b.unicodeScalars)
        let n = min(aa.count, bb.count)
        for i in 0..<n {
            let c1 = fold(aa[i].value)
            let c2 = fold(bb[i].value)
            if c1 != c2 { return c1 < c2 ? -1 : 1 }
        }
        if aa.count == bb.count { return 0 }
        return aa.count < bb.count ? -1 : 1
    }

    private static func fold(_ scalar: UInt32) -> UInt32 {
        // Java compareToIgnoreCase: toUpperCase then toLowerCase. For ASCII this is lowercase.
        if scalar >= 65 && scalar <= 90 { return scalar + 32 }   // A-Z -> a-z
        return scalar
    }

    /// Primary comparison for a sort category. Returns negative/0/positive. CUSTOM returns 0
    /// (keep incoming order).
    static func primaryCompare(_ a: SortAttributes, _ b: SortAttributes, category: SortCategory) -> Int {
        switch category {
        case .custom:
            return 0
        case .account:
            let r = ciCompare(a.name, b.name)
            return r != 0 ? r : ciCompare(a.issuer, b.issuer)
        case .accountReversed:
            let r = ciCompare(a.name, b.name)
            let combined = r != 0 ? r : ciCompare(a.issuer, b.issuer)
            return -combined
        case .issuer:
            let r = ciCompare(a.issuer, b.issuer)
            return r != 0 ? r : ciCompare(a.name, b.name)
        case .issuerReversed:
            let r = ciCompare(a.issuer, b.issuer)
            let combined = r != 0 ? r : ciCompare(a.name, b.name)
            return -combined
        case .usageCount:
            // descending
            if a.usageCount != b.usageCount { return a.usageCount > b.usageCount ? -1 : 1 }
            return 0
        case .lastUsed:
            // descending
            if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed ? -1 : 1 }
            return 0
        }
    }

    /// Sort entries by the category, then float favorites to the top with a STABLE secondary
    /// sort. Equivalent to Android's `sort(primary)` followed by `sort(FavoriteComparator)`:
    /// the effective order is (favorite, primary, insertion-index).
    static func sorted<T: EntrySortable>(_ entries: [T], category: SortCategory) -> [T] {
        return entries.enumerated().sorted { lhs, rhs in
            let a = lhs.element.sortAttributes
            let b = rhs.element.sortAttributes
            // favorites first
            if a.favorite != b.favorite { return a.favorite && !b.favorite }
            let p = primaryCompare(a, b, category: category)
            if p != 0 { return p < 0 }
            // stable: preserve original (custom/insertion) order
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }
}

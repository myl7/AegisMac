# Aegis Vault — Entry Data Model, Groups, Icons, Preferences (Swift Port Spec)

This spec covers the on-disk JSON data model (the decrypted vault "content" object), the runtime model objects, and the user preferences that drive core UX. It is derived directly from the Aegis Android source. The OTP/crypto details of the `info` object are a separate subsystem; this spec gives the exact `info` JSON shape needed to round-trip entries but defers algorithm math to the OTP spec.

All JSON here refers to the **decrypted vault content** (the plaintext object that is encrypted-at-rest and also produced by plaintext export). Everything is `org.json` semantics: object key order is not guaranteed, numbers are ints/longs/doubles, strings are UTF-8.

---

## 1. Vault container object

Top-level object (`Vault.toJson`):

```json
{
  "version": 3,
  "entries": [ /* array of entry objects */ ],
  "groups":  [ /* array of group objects */ ],
  "icons_optimized": true
}
```

- `version`: int constant **3** (`Vault.VERSION`). On read: if `version > 3` → throw "Unsupported version". Versions ≤ 3 are accepted (older files may be 1 or 2 and use the legacy per-entry `group` string; see §5).
- `entries`: array, preserves order (this is the **custom sort order** — see §6).
- `groups`: array. **Always serialized in full, even groups not referenced by any entry.** When an `EntryFilter` is applied during export, entries may be filtered out but the full group list is still written.
- `icons_optimized`: boolean, default **true**. On read: `if (!obj.optBoolean("icons_optimized")) setIconsOptimized(false)` — i.e. missing or `false` → treated as `false`; only explicit `true` keeps it optimized. Purely a flag indicating whether icons were re-encoded/downscaled to Aegis' preferred format; the port can persist it verbatim and default to `true` for newly written vaults.

### Read-time group reconciliation (important)
When parsing the vault:
1. Parse `groups` first. When adding, **dedupe**: only add a group if a group with that UUID is not already present (`if (!groups.has(group)) groups.add(group)`).
2. Parse each entry. After parsing, run **old-group migration** (§5).
3. For each UUID in the entry's `groups` set: **if the vault has no group with that UUID, remove that UUID from the entry.** (Dangling group references are silently dropped.)

---

## 2. VaultEntry JSON schema

Written by `VaultEntry.toJson()`:

```json
{
  "type": "totp",
  "uuid": "8d1b4e2a-....-............",
  "name": "alice@example.com",
  "issuer": "GitHub",
  "note": "backup account",
  "favorite": false,
  "icon": null,
  "info": { /* OTP-specific, see §4 */ },
  "groups": [ "uuid-string", "uuid-string" ]
}
```

When an icon is present, two additional keys `icon_mime` and `icon_hash` appear (see §3), and `icon` is a base64 string instead of `null`.

### Field-by-field

| JSON key | Type | Written always? | Read default | Notes |
|---|---|---|---|---|
| `type` | string | yes | required | OTP type id: `"totp"`, `"hotp"`, `"steam"`, `"yandex"`, `"motp"`. Drives which `info` subclass to build. |
| `uuid` | string | yes | if **absent**, generate a new random UUID | Canonical lowercase 8-4-4-4-12 form (`UUID.toString()`). Used as the primary key everywhere. |
| `name` | string | yes | **required** (`getString`) — but writer always emits, default value is `""` | The account name (e.g. the email/login). |
| `issuer` | string | yes | **required** (`getString`), default `""` | The service name (e.g. "GitHub"). |
| `note` | string | yes | `optString(..., "")` → `""` if absent/null | Free-text note. |
| `favorite` | boolean | yes | `optBoolean(..., false)` → `false` | See §7. |
| `icon` | string \| null | yes | see §3 | base64 of raw image bytes, or JSON `null`. |
| `icon_mime` | string | only if icon != null | see §3 | MIME type. |
| `icon_hash` | string | only if icon != null | see §3 | lowercase hex SHA-256. |
| `info` | object | yes | required | OTP parameters, see §4. |
| `groups` | array<string> | yes | `[]` if absent | UUID strings referencing `VaultGroup`s. |
| `group` | string | **never written** (legacy read-only) | — | Old single-group-by-name field; see §5. Only read when `groups` is absent. |

### Read algorithm (`VaultEntry.fromJson`)
1. `uuid` = present ? `UUID.fromString(...)` : `UUID.randomUUID()`.
2. `info` = build from `type` + `info` object (§4). If this throws, the whole entry fails to parse (`VaultEntryException`).
3. `name` = `getString("name")`, `issuer` = `getString("issuer")` (both required, will throw if missing).
4. `note` = `optString("note", "")`.
5. `favorite` = `optBoolean("favorite", false)`.
6. Groups: **if `groups` key present** → parse array, each element `UUID.fromString`, add to entry's group set. **Else if `group` key present** → store as "old group" name string for later migration. (Presence of `groups` means migration already happened; the `group` field is ignored.)
7. Icon: attempt `VaultEntryIcon.fromJson(obj)`. **Any `VaultEntryIconException` is silently swallowed** (entry keeps no icon). This is deliberate forward-compat so new icon MIME types don't break old parsers.

### Runtime-only fields (NOT serialized in the vault)
`VaultEntry` also carries `_usageCount` (int) and `_lastUsedTimestamp` (long). **These are never written to the vault JSON.** They are stored separately in Preferences (§8) and injected into the transient model object at display time for sorting.

### Default / placeholder entry
`VaultEntry.getDefault()` = a TOTP entry with `secret=null`, `name=""`, `issuer=""`, `note=""`, `favorite=false`, no icon, no groups. `isDefault()` / `equivalates()` compare name, issuer, info, icon, note, favorite, and groups (UUID is ignored in equivalence). Used to detect an untouched placeholder.

---

## 3. Icons — storage, MIME, hashing

Icons are stored **inline, base64-encoded, inside each entry** — there is no separate icon file store in the vault. Model class `VaultEntryIcon` holds:
- `_bytes`: raw image bytes (the full file: SVG text bytes, PNG, or JPEG binary).
- `_type`: `IconType` enum.
- `_hash`: SHA-256 (see below).
- Constant `MAX_DIMENS = 512` (raster icons are downscaled so the longest side ≤ 512 px when "optimized"; the port can honor this when importing images).

### IconType enum
Values: `INVALID`, `SVG`, `PNG`, `JPEG`.

| IconType | MIME (`toMimeType`) | filename ext (`fromFilename`, lowercased) |
|---|---|---|
| SVG | `image/svg+xml` | `svg` |
| PNG | `image/png` | `png` |
| JPEG | `image/jpeg` | `jpg`, `jpeg` |
| INVALID | (throws if converted to MIME) | anything else |

`fromMimeType(str)`: exact-match the three strings above; anything else → `INVALID`.

### Serialization (`VaultEntryIcon.toJson`)
```
obj.put("icon", icon == null ? JSON null : base64(icon.bytes))
if (icon != null):
    obj.put("icon_mime", icon.type.toMimeType())   // e.g. "image/png"
    obj.put("icon_hash", hexLower(icon.hash))       // 64 lowercase hex chars
```

### Deserialization (`VaultEntryIcon.fromJson`)
1. `icon = obj.get("icon")`. If it is JSON `null` → return `null` (no icon).
2. `mime = optString("icon_mime")` (null if absent/JSON-null).
3. `iconType = (mime == null) ? JPEG : fromMimeType(mime)`. **If `mime` is absent, default to JPEG** (legacy behavior — old vaults had JPEG-only icons with no MIME field).
4. If `iconType == INVALID` → throw `VaultEntryIconException("Bad icon MIME type: ...")`. (Caught & swallowed by the entry parser → entry ends up icon-less.)
5. `iconBytes = base64Decode(iconString)`.
6. `iconHashStr = optString("icon_hash")`. If present → `hash = hexDecode(iconHashStr)` and use it directly (trusts stored hash). If absent → **recompute** the hash from bytes+type.

### Hash algorithm (`generateHash`) — reproduce exactly
```
md = SHA-256
md.update( UTF8_bytes( type.toMimeType() ) )   // hash the MIME string first
return md.digest( imageBytes )                 // then the image bytes
```
i.e. `hash = SHA256( utf8(mimeType) || imageBytes )`. The MIME string is mixed in **before** the image bytes. `icon_hash` is this digest, hex-encoded lowercase (64 chars).

Icon equality is defined **solely by hash equality** (`Arrays.equals(hash)`). `hashCode()` = `Guava HashCode.fromBytes(hash).asInt()` = the first 4 bytes of the hash interpreted **little-endian** as a signed 32-bit int (only relevant if you need to match Java hashing; not needed for correctness).

### Encoding specifics
- **Base64**: Guava `BaseEncoding.base64()` = RFC 4648 **standard** alphabet (`A–Z a–z 0–9 + /`) **with `=` padding**. Not URL-safe. Decode is strict (rejects invalid chars).
- **Hex**: encode = lowercase base16; decode uppercases input first, so it accepts either case.

### Icon packs (separate feature — `icons/` package)
Icon packs are a **library/suggestion** feature, not part of the vault format. An icon pack is a `.zip`/JSON bundle the user imports; the app suggests icons from it based on the entry issuer. This is optional for a first port. Details for completeness:

`IconPack.fromJson`:
```json
{ "uuid": "...", "name": "...", "version": 1,
  "icons": [ { "filename": "github.svg", "name": "GitHub",
              "category": "dev" | null, "issuer": ["GitHub","github.com"] } ] }
```
- `uuid` (required, parsed), `name` (required), `version` (int, required), `icons` (array).
- Per icon: `filename` (required, rel path; icon type inferred from extension), `name` (optString; if null, derived from filename without extension), `category` (nullable string), `issuer` (required string array).
- Icon pack equality: same UUID **and** same version.
- Suggestion matching (`getSuggestedIcons(issuer)`): case-insensitive.
  - **NORMAL match** (higher priority, inserted at front): some icon-issuer string *contains* the entry issuer.
  - **INVERSE match** (lower priority, appended at end): entry issuer *contains* some icon-issuer string.
  - Empty/blank entry issuer → no suggestions.
- The pack files live on disk (`IconPackManager`); when chosen, the selected image's bytes are read and become a normal inline `VaultEntryIcon` on the entry (so the vault never references the pack).

---

## 4. `info` object schema (OTP params — round-trip shape)

The `type` field (on the entry, not inside `info`) selects the variant. `info` common fields (all types):

| key | type | notes |
|---|---|---|
| `secret` | string | Base32-encoded secret (Guava base32: uppercase A–Z 2–7, `=` padding). |
| `algo` | string | Hash algorithm, no `Hmac` prefix: one of `SHA1`, `SHA256`, `SHA512`, `MD5`. |
| `digits` | int | 1–10 valid. |

Type-specific additions:

| `type` | extra `info` keys | fixed constraints |
|---|---|---|
| `totp` | `period` (int seconds) | default period 30, default digits 6, default algo SHA1 |
| `steam` | `period` (int) | **digits forced to 5**, algo SHA1, period 30; codes rendered in Steam alphabet |
| `hotp` | `counter` (long) | counter-based |
| `yandex` | `pin` (string) | digits 8, period 30, algo SHA256; secret has special parsing |
| `motp` | `pin` (string) | algo MD5, period 10, digits 6 |

Read quirk to replicate: when building `info`, **if `type != "motp"` and `algo == "MD5"`, silently reset `algo` to `"SHA1"`** (works around a historical bug where non-mOTP entries got MD5).

Constants: `DEFAULT_DIGITS = 6`, `DEFAULT_ALGORITHM = "SHA1"`, TOTP `DEFAULT_PERIOD = 30`, Steam DIGITS = 5, mOTP PERIOD = 10 / DIGITS = 6 / ALGORITHM = MD5, Yandex DIGITS = 8. Full OTP generation math is in the OTP subsystem spec.

---

## 5. VaultGroup schema & the group membership model

### VaultGroup JSON (`VaultGroup.toJson`)
```json
{ "uuid": "....", "name": "Work" }
```
- `uuid`: required on read (`getString` → `UUID.fromString`). Unlike entries, a group with **no uuid fails to parse**.
- `name`: required (`getString`).
- Group **equality** = same UUID **and** same name.
- `toString()` returns the name.

### Membership model
- An entry references groups **by UUID**, held in a `Set<UUID>` implemented as a `TreeSet` (so iteration/serialization order is UUID natural order — Java `UUID.compareTo` compares the two 64-bit halves as signed longs; for the port, keeping groups sorted by UUID string is a close-enough cosmetic match). Order is not semantically meaningful.
- `addGroup(null)` / adding null is an assertion error — groups are never null.
- Group membership is many-to-many: an entry can be in multiple groups; a group can contain many entries.
- **Removing a group** (`VaultRepository.removeGroup`): iterate **all** entries and `removeGroup(uuid)` from each, then remove the group from the vault's group map. Never leaves dangling refs at runtime (and read-time reconciliation in §1 cleans any that slipped through).
- `getUsedGroups()`: the subset of groups referenced by at least one entry (union of all entries' group sets, intersected with existing groups). The UI can show "used" vs. "all" groups; the vault always persists **all** groups.
- `replaceGroups(collection)`: wipe + re-add (used when editing the group list).
- `findGroupByName(name)`: first group whose name equals (used by migration).

### Legacy single-group migration (`Vault.migrateOldGroup`)
Old vaults stored one group **by name** on the entry as `"group": "Work"` (string, no separate group objects). Migration, run per entry at load after group parsing:
```
if entry.oldGroup != null:
    g = groups.firstWhere(name == oldGroup)      // match by name
    if g exists: entry.addGroup(g.uuid)
    else:        g = new VaultGroup(oldGroup); groups.add(g); entry.addGroup(g.uuid)
    entry.oldGroup = null
    return true   // mark "groups migration fresh" → triggers a vault re-save
```
If any entry was migrated, `isGroupsMigrationFresh()` becomes true and the app persists the upgraded vault. The port should perform the same migration so old exports import correctly, and prefer matching an existing group by name before creating a new one.

---

## 6. Entry ordering (custom order)

- The vault's entries live in a `LinkedHashMap<UUID, VaultEntry>` keyed by UUID — **insertion order is the custom order** and is exactly the order of the `entries` array in JSON.
- Reordering: `move(a, b)` moves entry `a` to the list index currently occupied by `b`, shifting the rest (a standard list "move item" — remove at old index, insert at new index), then rebuilds the map in the new order. Persist the new array order.
- New entries are appended (added to the end of the map).
- **Drag-and-drop reorder is only allowed when** sort category is `CUSTOM` **and** there is no active group filter **and** no active search filter. In any other sort/filter state the list is a derived view and reordering is disabled.

---

## 7. Sorting & favorite ("pinned") semantics

There is **no separate "pinned" field** — the `favorite` boolean *is* the pinning mechanism. Favorites are always floated to the top of the list.

### Display pipeline (`calculateShownEntries`)
1. Start from the vault's entries in custom order.
2. Drop entries filtered out by group filter / search (§9).
3. Sort by the current `SortCategory`'s comparator (if any).
4. **Then always** apply `FavoriteComparator` as a second, **stable** sort so favorites move to the front while preserving the primary sort within the favorite and non-favorite partitions.

`FavoriteComparator.compare(a,b) = -1 * Boolean.compare(a.favorite, b.favorite)` → favorites (true) sort before non-favorites. Because Java `Collections.sort` is stable, running it after the primary sort yields: [favorites in primary order] then [non-favorites in primary order].

### SortCategory enum (ordinal-encoded in prefs)
| ordinal | value | comparator |
|---|---|---|
| 0 | `CUSTOM` | none (keep vault/custom order) |
| 1 | `ACCOUNT` | by name (case-insensitive) then issuer (case-insensitive) |
| 2 | `ACCOUNT_REVERSED` | reverse of ACCOUNT |
| 3 | `ISSUER` | by issuer then name (case-insensitive) |
| 4 | `ISSUER_REVERSED` | reverse of ISSUER |
| 5 | `USAGE_COUNT` | by usage count, **descending** (reverse of ascending int compare) |
| 6 | `LAST_USED` | by last-used timestamp, **descending** (most recent first) |

Comparators:
- `AccountNameComparator`: `a.name.compareToIgnoreCase(b.name)`.
- `IssuerNameComparator`: `a.issuer.compareToIgnoreCase(b.issuer)`.
- `UsageCountComparator`: `Integer.compare(a.usageCount, b.usageCount)` — wrapped in `Collections.reverseOrder` for the `USAGE_COUNT` category.
- `LastUsedComparator`: `Long.compare(a.lastUsedTimestamp, b.lastUsedTimestamp)` — reversed for `LAST_USED`.

`compareToIgnoreCase` is Java case-insensitive comparison (per-char lowercase then uppercase fold); Swift `caseInsensitiveCompare` /localized-independent is a close match — use a locale-independent case-insensitive compare for parity.

The number of favorites currently shown drives a divider/section in the UI (`getShownFavoritesCount`). The favorites "section" is purely the top slice of the sorted list.

---

## 8. Usage counts & last-used tracking

**Not part of the vault.** Stored in Preferences (app settings), keyed by entry UUID, as JSON strings.

### `pref_usage_count` (string, default `""`)
JSON array of `{ "uuid": "<uuid>", "count": <int> }`:
```json
[ {"uuid":"8d1b...","count":12}, {"uuid":"...","count":3} ]
```
- `getUsageCounts()` → `Map<UUID,Integer>`. Parse failures → empty map.
- `getUsageCount(uuid)` → the count, or **0** if absent.
- `resetUsageCount(uuid)` → set that uuid's count to 0 and re-save.
- `clearUsageCount()` → remove the whole key.

### `pref_last_used_timestamps` (string, default `""`)
JSON array of `{ "uuid": "<uuid>", "timestamp": <long> }` where timestamp is **epoch milliseconds** (`new Date().getTime()`):
```json
[ {"uuid":"8d1b...","timestamp":1723200000000} ]
```
- `getLastUsedTimestamps()` → `Map<UUID,Long>`. `getLastUsedTimestamp(uuid)` → value or **0**.

### Increment behavior (`incrementUsageCount`, on entry copy/tap)
- Usage count: `if absent → set 1; else → count + 1`.
- Last-used: set to **now** in epoch ms.
- These transient counters are pushed into the model objects at `setEntries` time (`entry.setUsageCount(...)`, `entry.setLastUsedTimestamp(...)`, defaulting to 0), used for sorting, and **persisted on app pause** (`onPause` writes both maps back to prefs). The port should mirror: increment in memory on use, flush to persistent settings on background/quit.

---

## 9. Group filter & search (list filtering)

### Group filter — `pref_group_filter_uuids` (string, default null/empty → empty set)
JSON array of UUID strings; **a JSON `null` element is allowed and means "ungrouped"**:
```json
[ "8d1b-...", null ]
```
- `getGroupFilter()` → `Set<UUID>` (may contain a `null` sentinel). Parse failure → empty set.
- Filtering logic (entry is **hidden** if):
  - Filter non-empty **and** entry has no groups **and** filter does **not** contain the `null` sentinel → hidden.
  - Filter non-empty **and** entry has groups **and** none of the entry's groups is in the filter (ignoring the null sentinel) → hidden.
  - Empty filter → nothing hidden by group.

### Search behavior — `pref_search_behavior_mask` (int)
Bit flags: `SEARCH_IN_ISSUER = 1`, `SEARCH_IN_NAME = 2`, `SEARCH_IN_NOTE = 4`, `SEARCH_IN_GROUPS = 8`. **Default = ISSUER | NAME = 3.**
- Search string is lowercased & trimmed; split on whitespace into tokens.
- An entry matches iff **every token** matches at least one **enabled** field (case-insensitive `contains`): issuer, name, note, and/or any of the entry's group names (for `SEARCH_IN_GROUPS`, match against the names of the groups the entry belongs to).
- Search and group filter are mutually exclusive in the pipeline (search takes precedence when active).

---

## 10. Preferences that matter for core UX

All keys are Android `SharedPreferences` keys (`PreferenceManager.getDefaultSharedPreferences`). For the macOS port map these to `UserDefaults`/settings. Enum-typed prefs are stored as the enum **ordinal (int)** unless noted (code grouping is stored as the enum **name string**). Below, "default" is the value returned when the key is absent.

### Appearance / theme
| Key | Type | Default | Values |
|---|---|---|---|
| `pref_current_theme` | int (ordinal) | `SYSTEM` = **3** | `LIGHT=0, DARK=1, AMOLED=2, SYSTEM=3, SYSTEM_AMOLED=4`. AMOLED = pure-black dark. SYSTEM/SYSTEM_AMOLED follow OS light/dark, using AMOLED blacks for the `_AMOLED` variant. |
| `pref_dynamic_colors` | bool | `false` | Android Material-You dynamic color; likely N/A on macOS. |

### List layout / view mode
| Key | Type | Default | Values |
|---|---|---|---|
| `pref_current_view_mode` | int (ordinal) | `NORMAL` = **0** | `NORMAL=0, COMPACT=1, SMALL=2, TILES=3`. |

ViewMode-derived layout constants:
- Inter-item spacing (dp): `COMPACT → 1`, `TILES → 4`, everything else → **8**.
- Grid span count: `TILES → 2` columns, else **1** (single column list).
- Account-name formatting: `TILES` shows the raw account name; all other modes wrap it as `"(name)"`.

### Code display / grouping
| Key | Type | Default | Values |
|---|---|---|---|
| `pref_code_group_size_string` | **string (enum name)** | `"GROUPING_THREES"` | `CodeGrouping` enum, stored by `name()`. |
| `pref_show_next_code` | bool | `false` | Show the upcoming (next-period) code too. |
| `pref_expiration_state` | bool | `true` | Show the countdown/expiry indicator. |
| `pref_show_icons` | bool | `true` | Whether entry icons are shown at all. |
| `pref_account_name_position` | int (ordinal) | `END` = **1** | `HIDDEN=0, END=1, BELOW=2` — where the account name is placed relative to the issuer. |
| `pref_shared_issuer_account_name` | bool | `false` | `onlyShowNecessaryAccountNames`: only show the account name when multiple entries share the same issuer. |

`CodeGrouping` enum — each has an associated int used as the chunk size for inserting spaces into the displayed code:
| name | value | meaning |
|---|---|---|
| `HALVES` | -1 | split code into two equal halves with one space |
| `NO_GROUPING` | -2 | no spacing at all |
| `GROUPING_TWOS` | 2 | space every 2 digits |
| `GROUPING_THREES` | 3 | space every 3 digits (**default**) |
| `GROUPING_FOURS` | 4 | space every 4 digits |

### Reveal / highlight / focus
| Key | Type | Default | Notes |
|---|---|---|---|
| `pref_tap_to_reveal` | bool | `false` | Hide codes until tapped. |
| `pref_tap_to_reveal_time` | int (seconds) | `30` | How long a revealed code stays visible. |
| `pref_highlight_entry` | bool | `false` | Highlight/dim to emphasize the focused entry. |
| `pref_pause_entry` | bool | `false` | Pause code refresh on the focused entry. **Only effective if** `pref_tap_to_reveal` OR `pref_highlight_entry` is enabled (otherwise reported as `false` regardless of stored value). |

### Sorting / ordering
| Key | Type | Default | Values |
|---|---|---|---|
| `pref_current_sort_category` | int (ordinal) | `CUSTOM` = **0** | See §7 SortCategory table. |
| `pref_group_filter_uuids` | string (JSON) | empty set | See §9. |
| `pref_search_behavior_mask` | int (bitmask) | `3` (ISSUER\|NAME) | See §9. |

### Copy behavior
| Key | Type | Default | Values |
|---|---|---|---|
| `pref_current_copy_behavior` | int (ordinal) | `NEVER` = **0** | `NEVER=0, SINGLETAP=1, DOUBLETAP=2` — whether tapping an entry copies the code, and single vs double tap. |
| `pref_minimize_on_copy` | bool | `false` | Minimize app after copying. |

Migration: legacy boolean `pref_copy_on_tap` (if present & true) → set `CopyBehavior.SINGLETAP`, then delete the old key.

### Interaction / misc UX
| Key | Type | Default | Notes |
|---|---|---|---|
| `pref_haptic_feedback` | bool | `true` | Haptics (N/A on macOS). |
| `pref_groups_multiselect` | bool | `false` | Allow selecting multiple groups in the filter chip bar. |
| `pref_focus_search` | bool | `false` | Auto-focus the search field on open. |
| `pref_pin_keyboard` | bool | `false` | Show numeric PIN keyboard for unlock. |
| `pref_secure_screen` | bool | `true` (false on debug builds) | FLAG_SECURE — block screenshots (N/A on macOS but note intent: sensitive-screen protection). |
| `pref_lang` | string | `"system"` | Language override; `"system"` = OS locale; else `lang` or `lang_REGION`. |
| `pref_intro` | bool | `false` | Whether the first-run intro/onboarding is complete. |

### Security / auto-lock (not primary UX but affects app flow)
| Key | Type | Default | Notes |
|---|---|---|---|
| `pref_auto_lock_mask` | int (bitmask) | `ON_BACK_BUTTON \| ON_DEVICE_LOCK` = **10** | Bits: `AUTO_LOCK_OFF=1, ON_BACK_BUTTON=2, ON_MINIMIZE=4, ON_DEVICE_LOCK=8`. Legacy fallback: if mask key absent, read boolean `pref_auto_lock` (default true) → true means the default mask (10), false means `AUTO_LOCK_OFF` (1). `isAutoLockEnabled()` = mask != OFF. |
| `pref_timeout` | int | `-1` | Inactivity lock timeout; -1 = never. |
| `pref_warn_time_sync` | bool | `true` | Warn if device clock looks out of sync. |

Password-reminder & backup prefs (`pref_password_reminder_freq`, `pref_backups`, `pref_backups_location`, `pref_backups_versions` default 5, `BACKUPS_VERSIONS_INFINITE = -1`, etc.) exist but are peripheral to the core viewing/entry UX; port later if needed. `PassReminderFreq` ordinals: `NEVER=0, WEEKLY=1, BIWEEKLY=2 (default), MONTHLY=3, QUARTERLY=4` (durations 1/2/4/13 weeks).

---

## 11. Key source files (absolute paths)
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/vault/VaultEntry.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/vault/VaultGroup.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/vault/VaultEntryIcon.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/vault/Vault.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/vault/VaultRepository.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/util/UUIDMap.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/icons/{IconType,IconPack,IconPackManager}.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/Preferences.java` and enums `ViewMode.java`, `SortCategory.java`, `Theme.java`, `AccountNamePosition.java`, `CopyBehavior.java`, `PassReminderFreq.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/helpers/comparators/*.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/ui/views/EntryAdapter.java` (sort/filter/usage pipeline)
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/otp/*.java` (info object; OTP subsystem)
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/encoding/{Base64,Hex}.java`

## CRITICAL FACTS (must preserve exactly)

- Vault version constant = 3; reject on read if version > 3; versions <= 3 accepted.
- Entry JSON keys (always written): type, uuid, name, issuer, note, favorite, icon, info, groups. When icon != null, also icon_mime and icon_hash.
- Entry read defaults: uuid absent -> generate random; name/issuer required getString; note optString default ""; favorite optBoolean default false; groups absent -> empty.
- usageCount and lastUsedTimestamp are NEVER in vault JSON — stored in Preferences keyed by UUID.
- uuid strings are canonical lowercase 8-4-4-4-12 form (Java UUID.toString()).
- Icons stored inline: 'icon' = standard RFC4648 base64 (alphabet A-Za-z0-9+/ with = padding, NOT url-safe) of raw image bytes, or JSON null.
- icon_mime values: image/svg+xml (SVG), image/png (PNG), image/jpeg (JPEG). Unknown MIME -> INVALID -> VaultEntryIconException (swallowed, entry ends icon-less).
- Missing icon_mime on read defaults IconType to JPEG (legacy).
- icon_hash = SHA256( utf8(mimeTypeString) || imageBytes ) — the MIME string bytes are hashed BEFORE the image bytes; encoded as lowercase hex (64 chars). If icon_hash absent on read, recompute; if present, trust it.
- Icon equality is by hash only. MAX_DIMENS = 512.
- VaultEntryIcon parse errors are silently swallowed by VaultEntry.fromJson (forward compat for new icon types).
- VaultGroup JSON = {uuid, name}; both required on read (group with no uuid fails to parse). Group equality = same uuid AND same name.
- Entry groups is Set<UUID> (TreeSet, sorted by UUID). Membership is many-to-many, referenced by UUID.
- Read-time reconciliation: parse groups first (dedupe by UUID); for each entry, migrate old group, then drop any entry group UUID not present in the vault groups.
- Legacy migration: old 'group' key is a single group NAME string. If entry has 'groups' key, ignore 'group'. Else find-or-create a VaultGroup by that name and add its UUID; mark migration fresh -> triggers re-save.
- Groups array is ALWAYS fully serialized, including groups not referenced by any entry.
- Removing a group removes its UUID from every entry, then removes the group.
- icons_optimized: default true; on read, only explicit true keeps optimized (missing or false => false).
- Entry custom order = insertion order in LinkedHashMap = order of the entries JSON array. move(a,b) reorders to b's index.
- SortCategory ordinals: CUSTOM=0, ACCOUNT=1, ACCOUNT_REVERSED=2, ISSUER=3, ISSUER_REVERSED=4, USAGE_COUNT=5, LAST_USED=6.
- Sort comparators use compareToIgnoreCase; ACCOUNT = name then issuer; ISSUER = issuer then name; USAGE_COUNT and LAST_USED are DESCENDING (reverse). CUSTOM = no comparator.
- After primary sort, ALWAYS apply a STABLE FavoriteComparator so favorites (favorite==true) float to top while preserving primary order within each partition. There is NO separate 'pinned' field — favorite IS the pin.
- Drag-and-drop reorder allowed ONLY when sortCategory==CUSTOM AND no group filter AND no search filter.
- pref_usage_count: string JSON array of {uuid, count:int}; getUsageCount default 0. Increment: absent->1 else +1.
- pref_last_used_timestamps: string JSON array of {uuid, timestamp:long epoch-millis}; default 0. Set to now on use.
- Usage/last-used are pushed into model at setEntries time and persisted on app pause (onPause).
- pref_current_theme int ordinal default SYSTEM=3; values LIGHT=0, DARK=1, AMOLED=2, SYSTEM=3, SYSTEM_AMOLED=4.
- pref_current_view_mode int ordinal default NORMAL=0; NORMAL=0, COMPACT=1, SMALL=2, TILES=3. Spacing dp: COMPACT=1, TILES=4, else 8. Span: TILES=2 else 1. TILES shows raw account name, others wrap as (name).
- pref_code_group_size_string is stored as enum NAME string, default 'GROUPING_THREES'. CodeGrouping values: HALVES(-1), NO_GROUPING(-2), GROUPING_TWOS(2), GROUPING_THREES(3), GROUPING_FOURS(4).
- pref_account_name_position int ordinal default END=1; HIDDEN=0, END=1, BELOW=2.
- pref_tap_to_reveal bool default false; pref_tap_to_reveal_time int default 30 seconds.
- pref_highlight_entry bool default false. pref_pause_entry bool default false, effective only if tap_to_reveal or highlight_entry enabled.
- pref_current_sort_category int ordinal default 0 (CUSTOM).
- pref_current_copy_behavior int ordinal default NEVER=0; NEVER=0, SINGLETAP=1, DOUBLETAP=2. Legacy pref_copy_on_tap true -> SINGLETAP.
- pref_show_icons bool default true; pref_show_next_code bool default false; pref_expiration_state bool default true; pref_shared_issuer_account_name bool default false.
- pref_search_behavior_mask bits: SEARCH_IN_ISSUER=1, SEARCH_IN_NAME=2, SEARCH_IN_NOTE=4, SEARCH_IN_GROUPS=8; default 3 (ISSUER|NAME). Search: lowercased, split on whitespace; every token must match at least one enabled field via contains.
- pref_group_filter_uuids: string JSON array of UUID strings; a JSON null element means 'ungrouped'. Filtering hides entries not matching.
- pref_auto_lock_mask default 10 (ON_BACK_BUTTON|ON_DEVICE_LOCK); bits AUTO_LOCK_OFF=1, ON_BACK_BUTTON=2, ON_MINIMIZE=4, ON_DEVICE_LOCK=8.
- Entry 'type' values: totp, hotp, steam, yandex, motp. info common keys: secret (Base32), algo (SHA1/SHA256/SHA512/MD5, no Hmac prefix), digits (int 1-10). totp/steam add period(int); hotp adds counter(long); yandex/motp add pin(string).
- OTP read quirk: if type != motp and algo == MD5, reset algo to SHA1. Steam digits forced to 5. Defaults: digits 6, algo SHA1, period 30; motp period 10/digits 6/MD5; yandex digits 8.
- Hex encode is lowercase base16; decode accepts any case (uppercases first).

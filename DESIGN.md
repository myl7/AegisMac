# AegisMac — Swift/SwiftUI port of Aegis Authenticator for macOS

Native macOS port of the Aegis Android 2FA app. Goal: full, working 2FA functionality
with a UI that preserves the Aegis look (Material indigo palette, filled cards, per-entry
progress bars) while adapting to macOS idioms (window toolbar, context menus, ⌘ shortcuts).

Vault files are **byte-compatible** with Android Aegis (`aegis.json`, format version 1,
db version 3): a vault exported on Android must unlock and import here, and vice versa.

## Ground rules (all agents)

- SPM package at repo root, single executable target `AegisMac`, macOS 14+, Swift 5 mode.
- Dependencies: **CryptoSwift** (scrypt ONLY). Everything else uses system frameworks:
  CryptoKit (AES-GCM, HMAC, SHA), Vision (QR detect), ScreenCaptureKit, LocalAuthentication.
- JSON: use `JSONSerialization` + `[String: Any]` (`JSONObject` alias), NOT Codable —
  the schema is dynamic and field presence rules matter. Compare parsed JSON in tests,
  never raw strings.
- Errors: throw `AegisError` (Support/Errors.swift). No new error enums.
- All types `internal` (no `public`). No new SPM dependencies. Do not edit Package.swift.
- **Only create/edit files you own** (ownership map below). If you need an API another
  module should provide but doesn't, write a Swift `extension` in YOUR OWN files and
  note the gap in your final report — do not touch other modules' files.
- Syntax-check your own files with `xcrun swiftc -parse <your files>`. Full builds are
  the integrator's job (wave agents may run `swift build`, but don't fight over fixing
  other modules' errors — report them instead).
- Specs are authoritative: `docs/porting-specs/*.md`
  (vault-crypto, otp-algorithms, model-store, ui-style, import-export). When a spec cites
  a constant or algorithm, reproduce it EXACTLY. The Android source at
  `/Users/myl/app/Aegis/app/src/main/java/...` is available for cross-checking.

## File ownership

| Module | Owner | Files (repo-relative) |
|---|---|---|
| Support | (pre-written) | `Sources/AegisMac/Support/Errors.swift` |
| Encoding+Crypto | agent **core-crypto** | `Sources/AegisMac/Encoding/{Base32,Hex}.swift`, `Sources/AegisMac/Crypto/{CryptoUtils,CryptParameters,ScryptParameters,MasterKey,Slots}.swift`, `Tests/AegisMacTests/CryptoTests.swift` |
| OTP | agent **otp** | `Sources/AegisMac/Otp/{OTPGen,OtpInfo}.swift`, `Tests/AegisMacTests/OtpTests.swift` |
| Vault | agent **vault** | `Sources/AegisMac/Vault/{VaultEntry,VaultGroup,VaultEntryIcon,Vault,VaultFile,VaultRepository}.swift`, `Tests/AegisMacTests/VaultTests.swift` |
| Import/Export | agent **import-export** | `Sources/AegisMac/Import/{GoogleAuthInfo,GoogleAuthMigration,QRScanner,ImportExport}.swift`, `Tests/AegisMacTests/ImportTests.swift` |
| UI | agent **ui** | `Sources/AegisMac/main.swift`, everything under `Sources/AegisMac/UI/` (AegisApp, AppState, Theme, Preferences, MainView, EntryRow, UnlockView, EditEntryView, SettingsView, GroupChips, AddMenu, LetterAvatar, TotpProgressBar, …), `Tests/AegisMacTests/UITests.swift` (logic-only tests: grouping, search, sort) |
| Integration | agent **integrator** | may touch anything to make `swift build` + `swift test` pass |

Test fixtures (already in place, declared as SPM resources — load via
`Bundle.module.url(forResource:withExtension:subdirectory:"Fixtures")`):
- `Fixtures/aegis_encrypted.json` — password `test`
- `Fixtures/aegis_plain.json`, `Fixtures/aegis_plain_grouped_v2.json`
- `Fixtures/uris_plain.txt` — otpauth:// lines

## Cross-module contracts (exact signatures — implement these verbatim)

### Encoding (`Encoding/`)
```swift
enum Base32 {
    static func decode(_ s: String) throws -> Data   // uppercases first; accepts padded & unpadded
    static func encode(_ data: Data) -> String        // UPPERCASE, NO padding
}
enum HexCodec {
    static func decode(_ s: String) throws -> Data    // case-insensitive
    static func encode(_ data: Data) -> String        // lowercase
}
```

### Crypto (`Crypto/`)
```swift
struct CryptParameters {                    // GCM nonce+tag pair
    var nonce: Data                         // 12 bytes
    var tag: Data                           // 16 bytes
    func toJson() -> JSONObject             // {"nonce": hex, "tag": hex}
    static func fromJson(_ obj: JSONObject) throws -> CryptParameters
}
struct ScryptParameters { var n: Int; var r: Int; var p: Int; var salt: Data }  // defaults 32768/8/1, 32-byte salt

enum CryptoUtils {
    static func deriveKey(password: [UInt8], params: ScryptParameters) throws -> Data  // scrypt, dkLen 32
    static func encrypt(_ plain: Data, key: Data) throws -> (cipherText: Data, params: CryptParameters)
    static func decrypt(_ cipherText: Data, key: Data, params: CryptParameters) throws -> Data
    static func randomBytes(_ count: Int) -> Data
}

final class MasterKey {                     // wraps the 32-byte vault master key
    let bytes: Data
    init(bytes: Data)
    static func generate() -> MasterKey
    func encrypt(_ plain: Data) throws -> (cipherText: Data, params: CryptParameters)
    func decrypt(_ cipherText: Data, params: CryptParameters) throws -> Data
}

// Slots.swift — slot model per vault-crypto spec §4
enum SlotType: Int { case raw = 0, password = 1, biometric = 2 }
class Slot {                                // base: uuid, encryptedMasterKey(Data), keyParams(CryptParameters)
    var uuid: UUID
    var encryptedMasterKey: Data
    var keyParams: CryptParameters
    var type: SlotType { get }
    func toJson() -> JSONObject
    static func fromJson(_ obj: JSONObject) throws -> Slot   // dispatches on "type"
    func getKey(_ keyBytes: Data) throws -> MasterKey        // AES-GCM-unwrap master key with given 32-byte key
    func setKey(_ masterKey: MasterKey, wrappingKey: Data) throws  // wrap + store
}
final class PasswordSlot: Slot {            // + n/r/p/salt/repaired/isBackup
    var scryptParams: ScryptParameters
    var repaired: Bool
    var isBackup: Bool
    func deriveKey(password: String) throws -> Data
}
final class RawSlot: Slot {}
final class BiometricSlot: Slot {}          // parsed & preserved on re-save, never unlockable on macOS

struct SlotList {
    var slots: [Slot]
    func toJson() -> [JSONObject]           // array
    static func fromJson(_ arr: [Any]) throws -> SlotList
    func findPasswordSlots() -> [PasswordSlot]
    /// Try password against every password slot; return master key or throw AegisError.crypto
    func unlock(password: String) throws -> MasterKey
}
```

### OTP (`Otp/`)
```swift
// OTPGen.swift — pure algorithm functions per otp-algorithms spec §2 (incl. all edge cases)
enum OTPGen {
    static func hotp(secret: Data, algo: String, digits: Int, counter: Int64) throws -> String  // algo bare: "SHA1"...
    static func totp(secret: Data, algo: String, digits: Int, period: Int, time: Int64) throws -> String
    static func steam(secret: Data, algo: String, digits: Int, period: Int, time: Int64) throws -> String
    static func motp(secret: Data, digits: Int, period: Int, pin: String, time: Int64) throws -> String
    static func yandex(secret: Data, pin: String, digits: Int, period: Int, time: Int64) throws -> String
}

// OtpInfo.swift — class hierarchy mirroring Java (otp spec §3, §4)
class OtpInfo {
    var secret: Data
    var algorithm: String                    // bare name, validated: SHA1/SHA256/SHA512/MD5
    var digits: Int                          // 1...10
    var typeId: String { get }               // "totp"/"hotp"/"steam"/"yandex"/"motp"
    var typeName: String { get }             // "TOTP"/"HOTP"/"Steam"/"Yandex"/"MOTP"-style display
    func getOtp(time: Int64) throws -> String
    func toJson() -> JSONObject              // {"secret": base32, "algo": ..., "digits": ...} + subclass keys
    static func fromJson(type: String, obj: JSONObject) throws -> OtpInfo  // incl. MD5→SHA1 workaround
    func isEqual(to other: OtpInfo) -> Bool
}
class TotpInfo: OtpInfo   { var period: Int; func millisTillNextRotation(now: Int64) -> Int64 }
final class HotpInfo: OtpInfo   { var counter: Int64; func incrementCounter() }
final class SteamInfo: TotpInfo {}
final class MotpInfo: TotpInfo  { var pin: String? }
final class YandexInfo: TotpInfo { var pin: String?; static func parseSecret(_ raw: Data) throws -> Data }
```

### Vault (`Vault/`)
```swift
final class VaultEntry: Identifiable {      // model-store spec §2
    var uuid: UUID                           // id = uuid
    var name: String, issuer: String, note: String
    var favorite: Bool
    var icon: VaultEntryIcon?
    var info: OtpInfo
    var groups: Set<UUID>
    func toJson() -> JSONObject
    static func fromJson(_ obj: JSONObject) throws -> VaultEntry
}
struct VaultGroup: Hashable { var uuid: UUID; var name: String; toJson/fromJson }
struct VaultEntryIcon {                      // model-store spec §3, hash = SHA256(mime || bytes)
    var bytes: Data; var type: IconType; var hash: Data
}
enum IconType: String { case svg, png, jpeg /* mime mapping per spec */ }

final class Vault {                          // db version 3
    var entries: [VaultEntry]                // ordered = custom order
    var groups: [VaultGroup]
    var iconsOptimized: Bool
    func toJson() -> JSONObject
    static func fromJson(_ obj: JSONObject) throws -> Vault   // incl. legacy group migration + reconciliation
}

struct VaultFileHeader { var slots: SlotList?; var params: CryptParameters? }  // both nil = plaintext
final class VaultFile {                      // envelope, version 1
    var header: VaultFileHeader
    static func fromData(_ data: Data) throws -> VaultFile
    func toData() throws -> Data             // pretty JSON
    var isEncrypted: Bool
    func getPlainContent() throws -> JSONObject
    func getContent(masterKey: MasterKey) throws -> JSONObject   // base64 db + header.params → decrypt
    static func make(vault: Vault, credentials: VaultFileCredentials?) throws -> VaultFile  // nil = plaintext
}
struct VaultFileCredentials { var slots: SlotList; var masterKey: MasterKey }

/// App-facing store. NOT an ObservableObject (UI wraps it in AppState).
final class VaultRepository {
    static var defaultVaultURL: URL          // ~/Library/Application Support/AegisMac/aegis.json
    private(set) var vault: Vault
    private(set) var credentials: VaultFileCredentials?   // nil = plaintext vault
    var isEncrypted: Bool

    static func fileExists(at url: URL) -> Bool
    static func loadFile(at url: URL) throws -> VaultFile
    static func unlock(file: VaultFile, password: String) throws -> VaultRepository
    static func loadPlain(file: VaultFile) throws -> VaultRepository
    static func createNew(password: String?) throws -> VaultRepository   // nil password = plaintext vault

    func save(to url: URL) throws            // atomic write
    func addEntry(_ e: VaultEntry), removeEntry, updateEntry(replacing by uuid)
    func moveEntry(from: Int, to: Int)
    func addGroup/removeGroup/renameGroup    // removeGroup strips uuid from all entries
    func exportPlain() throws -> Data        // plaintext vault file
    func exportEncrypted(password: String) throws -> Data  // fresh slot, strips biometric slots
}
```

### Import (`Import/`)
```swift
struct GoogleAuthInfo {                      // otp spec §5/§6
    var info: OtpInfo; var accountName: String; var issuer: String
    static func parseUri(_ s: String) throws -> GoogleAuthInfo
    func getUri() -> String
    func toVaultEntry() -> VaultEntry
}
enum GoogleAuthMigration {                   // otp spec §7 — hand-rolled protobuf
    static func parse(uri: String) throws -> [GoogleAuthInfo]
}
enum QRScanner {
    static func scan(imageURL: URL) throws -> [String]          // Vision, all QR payloads
    static func scan(image: CGImage) throws -> [String]
    @MainActor static func scanScreen() async throws -> [String] // ScreenCaptureKit screenshot of all displays → Vision
}
enum ImportExport {
    static func importVaultFile(data: Data, password: String?) throws -> Vault
    static func importUriList(text: String) throws -> [VaultEntry]   // skips blank lines; throws on first bad line
    static func exportUriList(entries: [VaultEntry]) -> String
}
```

### UI (`UI/` + `main.swift`)
- `main.swift` contains exactly `AegisApp.main()`. `AegisApp: App` (no `@main` attribute).
- `AppState: ObservableObject` — owns optional `VaultRepository`, lock state, search text,
  group filter, sort, now-tick timer (1 Hz + rotation boundary refresh), reveal state,
  copy feedback. All UI state flows through it.
- `Theme.swift` — the three palettes (Light/Dark/AMOLED) with exact hex from ui-style spec;
  `pref_current_theme` semantics (System follows NSApp appearance).
- `Preferences.swift` — UserDefaults-backed, same `pref_*` key names/defaults as Android
  (model-store spec §10): view mode, code grouping, account name position, tap-to-reveal,
  copy behavior, show icons, sort category, theme, group filter, search mask.
- Views: Unlock (password field + Touch ID button when Keychain key stored), Main window
  (toolbar: search, lock, sort menu, + menu), group filter chips row, entry list with all
  4 view modes (NORMAL default), footer "Showing N entries", empty state, Edit/Add sheet
  (all 5 types incl. secret Base32 field validation), Settings scene, Import/Export commands.
- Entry interactions: click = copy (with 3 s "Copied" animation per spec) honoring
  copy-behavior/tap-to-reveal prefs; right-click context menu: Copy code, Copy next code,
  Edit, Toggle favorite, Assign groups, Show QR (transfer), Delete (with confirm).
  HOTP rows show refresh button. Favorites float to top, gold sliver indicator, merged
  corner treatment per spec §3.3.
- Progress: global top bar when uniform period, else per-card bars; `max=5000` linear
  drain; expiration warning color shift + blink per spec §4 timings.
- Keyboard: ⌘F search, ⌘L lock, ⌘N add manual, ⌘, settings, ⌘C copies selected row's code.
- Touch ID (optional best-effort): Settings toggle stores master key in Keychain behind
  `.biometryCurrentSet`; Unlock view offers Touch ID when present.
- Mac adaptations: window min ~400×520, `.searchable` or toolbar search field, Settings
  scene instead of settings screen, sheet instead of new activity, menu bar commands.
  Keep Aegis palette + card look exactly (cards: 12 pt corners, no shadow/border).

## Storage & app behavior

- Vault path: `~/Library/Application Support/AegisMac/aegis.json` (Android-compatible file).
- First launch: onboarding — create new vault (password or skip = plaintext) OR import
  existing Aegis export file.
- Auto-lock: on lock command; optional on-inactivity timer (pref_timeout).
- Atomic saves on every mutation (write temp + replace).

## Build & test

```bash
cd /Users/myl/app/Aegis/macos
swift build 2>&1 | tail -20
swift test 2>&1 | tail -30
```
Tests must cover: RFC 4226 HOTP vectors, RFC 6238 TOTP vectors (SHA1/256/512),
Steam alphabet, MOTP vectors, Yandex vectors + secret checksum, scrypt RFC 7914 vector,
GCM round-trip, base32/hex edge cases, vault JSON round-trip, `aegis_encrypted.json`
unlock with password `test`, plain fixtures import, otpauth URI parse/serialize round-trip,
migration protobuf decode, code grouping, search token logic, sort comparators.

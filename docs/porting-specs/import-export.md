## Aegis Import/Export Subsystem — Swift/SwiftUI Port Spec

Scope: Aegis's own vault file format (encrypted + plaintext JSON), plain `otpauth://` URI import, Google Authenticator `otpauth-migration://` payload decode, and Aegis plaintext/encrypted/Google-URI export writing. Third-party importers (Authy, andOTP, FreeOTP, 2FAS, Bitwarden, Proton, Stratum, etc.) are out of scope.

All classes referenced live under `com.beemdevelopment.aegis`. Key source files (absolute):
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/importers/AegisImporter.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/importers/GoogleAuthUriImporter.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/otp/GoogleAuthInfo.java`
- `/Users/myl/app/Aegis/app/src/main/proto/google_auth.proto`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/vault/{VaultFile,VaultFileCredentials,Vault,VaultEntry,VaultGroup,VaultEntryIcon,VaultRepository,VaultBackupManager}.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/vault/slots/{Slot,PasswordSlot,RawSlot,BiometricSlot,SlotList}.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/crypto/{CryptoUtils,MasterKey,CryptParameters,SCryptParameters}.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/otp/{OtpInfo,TotpInfo,HotpInfo,SteamInfo,MotpInfo,YandexInfo}.java`
- `/Users/myl/app/Aegis/app/src/main/java/com/beemdevelopment/aegis/ui/fragments/preferences/ImportExportPreferencesFragment.java`

---

## 1. Cryptographic primitives (must match exactly)

**AEAD**: `AES/GCM/NoPadding`, AES-256.
- Key size: **32 bytes** (256-bit).
- GCM nonce/IV: **12 bytes** (96-bit).
- GCM tag: **16 bytes** (128-bit tag = `CRYPTO_AEAD_TAG_SIZE * 8` = 128 bits).

**KDF**: scrypt (standard RFC 7914 / Bouncy Castle `SCrypt.generate(P, S, N, r, p, dkLen)`).
- Default params for newly-created password slots: `N = 1<<15 = 32768`, `r = 8`, `p = 1`.
- Derived key length `dkLen = 32` bytes.
- `input` = password encoded as UTF-8 bytes (see §1.1). Salt comes from the slot.

**Critical GCM detail — tag is stored separately from ciphertext.** Aegis never keeps the tag appended to the ciphertext on disk. On encrypt it splits `cipher.doFinal(data)` into `ciphertext = result[0 .. len-16]` and `tag = result[len-16 .. len]`. On decrypt it re-appends `tag` to the ciphertext before calling GCM. So in Swift/CryptoKit:
- Decrypt: `AES.GCM.SealedBox(nonce: <nonce>, ciphertext: <stored ciphertext bytes>, tag: <stored tag bytes>)` then `AES.GCM.open(...)`.
- Encrypt: seal, then store `sealedBox.ciphertext` and `sealedBox.tag` separately, and `sealedBox.nonce`.

### 1.1 Password → bytes
`CryptoUtils.toBytes(char[])`: UTF-8 encode the password string, use exactly `byteBuffer.limit()` bytes (i.e. the normal UTF-8 byte representation of the string). For a Swift port: `Array(password.utf8)`.

Legacy edge case (issue #95, only relevant for compatibility with very old vaults): a deprecated `toBytesOld` used `byteBuffer.array()` which could contain extra trailing capacity bytes when the UTF-8 encoding exceeded 64 bytes. During password-slot decryption, if a slot is **not** marked `repaired` and the password's UTF-8 length is **> 64 bytes** and the normal derivation fails integrity, Aegis retries once with the "old" byte encoding. Modern vaults set `repaired: true`, so a Swift port can implement standard UTF-8 only and treat this as an unsupported corner case. All test fixtures use short passwords, so this never triggers.

### 1.2 Encodings
- **Base32** (`OtpInfo` secrets, `pin` fields): RFC 4648 base32, alphabet `ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`. Encode **omits padding** (`=`). Decode **uppercases input first** and accepts input **with or without** trailing `=` padding (Guava `BaseEncoding.base32()` decode is padding-tolerant). Use a base32 decoder that tolerates missing padding.
- **Base64** (encrypted `db` ciphertext, icon bytes, Google migration `data`): standard RFC 4648 base64 with `+`/`/` and `=` padding. Encode produces padding.
- **Hex** (`key`, `nonce`, `tag`, `salt`, `icon_hash`, mOTP secret in URI): base16. Encode is **lowercase**. Decode uppercases input first (case-insensitive).

---

## 2. Aegis vault file envelope (`VaultFile`)

The `.json` file on disk / export is a JSON object with this exact top-level shape (`VaultFile.toJson`):

```json
{
  "version": 1,
  "header": {
    "slots": <array | null>,
    "params": <object | null>
  },
  "db": <object (plaintext)  |  string (base64 ciphertext)>
}
```

- `version`: integer, current value **1**. On read: reject if `version > 1` ("unsupported version").
- **Encrypted iff header is non-empty.** `header.isEmpty()` == `slots == null && params == null`. If `header.slots` and `header.params` are both JSON `null` → the vault is **plaintext** and `db` is a JSON **object**. Otherwise it is **encrypted** and `db` is a **string** (base64).
- Serialization for writing: pretty-printed JSON with **indent = 4 spaces**, UTF-8 (`obj.toString(4)`). Key order is not significant for round-trip (all readers are key-based).

### 2.1 `header.params` (`CryptParameters`) — the vault-content GCM params
```json
{ "nonce": "<hex, 12 bytes>", "tag": "<hex, 16 bytes>" }
```

### 2.2 `header.slots` (`SlotList`) — array of slots
Each slot (`Slot.toJson`) has a common base:
```json
{
  "type": <int 0|1|2>,
  "uuid": "<uuid string>",
  "key": "<hex: encrypted master key, 32 bytes ciphertext>",
  "key_params": { "nonce": "<hex 12 bytes>", "tag": "<hex 16 bytes>" }
}
```
Slot types:
- `0` = RAW (`RawSlot`) — master key encrypted with an externally-supplied raw key.
- `1` = PASSWORD (`PasswordSlot`) — adds scrypt fields (below). **This is the only slot type a Swift port must handle for password unlock.**
- `2` = BIOMETRIC (`BiometricSlot`) — Android Keystore-backed; **ignore/skip on macOS**. Never present in exports (stripped, see §7.3).

Password slot extra fields (`PasswordSlot.toJson`):
```json
{
  "type": 1, "uuid": "...", "key": "...", "key_params": {...},
  "n": 32768, "r": 8, "p": 1,
  "salt": "<hex, typically 32 bytes>",
  "repaired": true,
  "is_backup": false
}
```
- `uuid`: if absent on read → generate a random UUID.
- `repaired`: optional boolean, default **false**.
- `is_backup`: optional boolean, default **false**. A "backup password" is a separate export-only password.

Real fixture password slot (from `aegis_encrypted.json`, password = `test`):
```json
{
  "type": 1,
  "uuid": "a8325752-c1be-458a-9b3e-5e0a8154d9ec",
  "key": "491d44550430ba248986b904b8cffd3a6c5755d176ac877bd11b82c934225017",
  "key_params": { "nonce": "e9705513ba4951fa7a0608d2", "tag": "931237af257b83c693ddb8f9a7eddaf0" },
  "n": 32768, "r": 8, "p": 1,
  "salt": "27ea9ae53fa2f08a8dcd201615a8229422647b3058f9f36b08f9457e62888be1",
  "repaired": true
}
```
Its `params` (vault-content): `nonce = 095fd13dee336fa56b4634ff`, `tag = 5db2470edf2d12f82a89ae7f48ccd50c`.

---

## 3. Importing / unlocking an encrypted Aegis `.json`

Reference: `AegisImporter.read` → `VaultFile.fromBytes` → (if encrypted) `EncryptedState.decrypt(password)` → `PasswordSlotDecryptTask.decrypt` + `VaultFile.getContent(creds)`.

### Step-by-step (password unlock)
1. Read entire file bytes, parse UTF-8 JSON into the `VaultFile` envelope (§2). Validate `version <= 1`.
2. If `header` is empty → plaintext; skip to §5 with `db` (already a JSON object).
3. If encrypted, collect all password slots (`type == 1`) from `header.slots`.
4. **Derive the master key** by trying each password slot in order until one succeeds:
   - For a slot: `derivedKey = scrypt(utf8(password), salt = hex_decode(slot.salt), N = slot.n, r = slot.r, p = slot.p, dkLen = 32)`.
   - Decrypt the slot's encrypted master key: GCM-open with `key = derivedKey`, `nonce = hex_decode(slot.key_params.nonce)`, `ciphertext = hex_decode(slot.key)`, `tag = hex_decode(slot.key_params.tag)`.
   - GCM authentication failure = wrong password for this slot → **swallow and try the next slot** (`SlotIntegrityException` is ignored). A non-integrity crypto error is fatal.
   - Success yields the 32-byte **master key** (the decrypted plaintext). Wrap as an AES key.
5. If **no** slot decrypts → password is incorrect (surface "Password incorrect").
6. **Decrypt the vault content** (`VaultFile.getContent(creds)`):
   - `ciphertext = base64_decode(db_string)`.
   - GCM-open with `key = masterKey`, `nonce = hex_decode(header.params.nonce)`, `tag = hex_decode(header.params.tag)`, `ciphertext`.
   - The plaintext bytes are UTF-8 JSON → parse into the vault DB object (§5).

Notes:
- The `VaultFileCredentials` object = `{ masterKey, slotList }`. Only the master key is needed to decrypt content; the slot list is retained so the vault can be re-saved/re-exported with the same slots.
- RAW and BIOMETRIC slots cannot be unlocked by password; on macOS only PASSWORD slots are usable.

---

## 4. Importing a plaintext Aegis `.json`

`header.slots == null && header.params == null`; `db` is a JSON object. Parse it directly as the vault DB (§5). No decryption. Fixture: `aegis_plain.json`.

---

## 5. Vault DB (decrypted content) shape (`Vault` / `AegisImporter.DecryptedState`)

The decrypted (or plaintext) `db` object:
```json
{
  "version": 3,
  "entries": [ <VaultEntry>, ... ],
  "groups":  [ <VaultGroup>, ... ],
  "icons_optimized": true
}
```
- `version`: current **3**. On read reject if `version > 3`. Known historical values 1, 2, 3 all parse (fixtures use 1 and 2). Older versions differ only in the entry group representation (see §5.2).
- `groups`: optional array (parse if present, before entries). Dedupe: skip a group whose UUID already added.
- `entries`: required array.
- `icons_optimized`: optional boolean; if absent/false, vault is flagged not-optimized (affects icon re-encoding only; irrelevant to a fresh port — you may ignore).

Entry insertion order is preserved (backed by a `LinkedHashMap` keyed by UUID); export/import round-trips maintain order. Adding two entries with the same UUID is an error in the original (throws); a Swift port should treat duplicate UUIDs defensively.

### 5.1 `VaultGroup` (`VaultGroup.fromJson`)
```json
{ "uuid": "<uuid string>", "name": "<string>" }
```
Both fields required.

### 5.2 `VaultEntry` (`VaultEntry.toJson` / `fromJson`)
```json
{
  "type": "totp",                 // OTP type id (see §6)
  "uuid": "<uuid string>",        // optional on read → random if absent
  "name": "<string>",
  "issuer": "<string>",
  "note": "<string>",             // optional, default ""
  "favorite": false,              // optional, default false
  "icon": <base64 string | null>,
  "icon_mime": "<mime>",          // present only when icon != null
  "icon_hash": "<hex>",           // present only when icon != null
  "info": { <OtpInfo fields, see §6> },
  "groups": [ "<uuid>", ... ]     // v3 format
}
```
Parsing rules:
- `type` (string) + `info` object → build the `OtpInfo` (§6).
- `name`, `issuer` required strings. `note` via optString default `""`. `favorite` via optBoolean default `false`.
- **Group representation, two formats:**
  - **New (v3)**: `"groups"` = array of group UUID strings. If present, use it (and ignore any `group` field).
  - **Legacy (v1/v2)**: no `groups`; instead a single `"group"` field = group **name** string or `null` (fixture `aegis_plain_grouped_v2.json`). On load, `Vault.migrateOldGroup` converts it: find an existing group with that name, else create a new `VaultGroup(name)` with a fresh UUID; add the entry to that group's UUID. `JsonUtils.optString` returns `null` when the JSON value is `null`.
  - After building, drop any group UUID on the entry that has no corresponding group in the vault's group list.
- **Icon** (`VaultEntryIcon.fromJson`), all errors silently ignored (entry keeps no icon on failure — forward-compat for new icon types):
  - `icon` == JSON null → no icon.
  - `icon_mime` → `IconType`: `"image/svg+xml"`→SVG, `"image/png"`→PNG, `"image/jpeg"`→JPEG. **If `icon_mime` absent → default JPEG.** Unknown MIME → treated as invalid → icon dropped.
  - `icon` string → base64-decode to bytes.
  - `icon_hash` (hex) if present is used as-is; else compute `SHA-256( utf8(mimeType) || iconBytes )` (MIME string bytes prepended, then icon bytes).

---

## 6. OtpInfo (`info` object) — per-type fields

Common (`OtpInfo.toJson`): every `info` has:
```json
{ "secret": "<base32, no padding>", "algo": "SHA1|SHA256|SHA512|MD5", "digits": <int> }
```
Type id (`type` on the entry) selects the subclass and extra fields:

| `type` | Class | Extra `info` fields | Defaults / constraints |
|---|---|---|---|
| `"totp"` | TotpInfo | `"period": <int>` | period default 30; period > 0 and ≤ Int.MAX/1000 |
| `"steam"` | SteamInfo | `"period": <int>` | digits fixed 5, algo SHA1, period 30 (but read from JSON) |
| `"hotp"` | HotpInfo | `"counter": <int64>` | counter ≥ 0 |
| `"motp"` | MotpInfo | `"period"`, `"pin": <string>` | algo MD5, period 10, digits 6 |
| `"yandex"` | YandexInfo | `"period"`, `"pin": <string>` | algo SHA256, digits 8; secret normalized to 16 bytes |

Validation (`OtpInfo`):
- `digits`: integer, `> 0 && <= 10`.
- `algo` valid set: `SHA1`, `SHA256`, `SHA512`, `MD5`. `setAlgorithm` strips a leading `"Hmac"` prefix and uppercases.
- **MD5 workaround (`OtpInfo.fromJson`)**: if `type != "motp"` and stored `algo == "MD5"`, force `algo = "SHA1"` (guards against a bug where non-mOTP entries got MD5).
- `getType()` = uppercased type id (used e.g. for Yandex issuer). `getTypeId()` = the lowercase id string above.

Secret is stored/parsed as base32 (no padding on write). Empty secret is allowed at parse time; it only errors when generating an OTP.

Yandex secret normalization (`YandexInfo.parseSecret`/`validateSecret`): raw secret length must be 16 (from QR, no checksum → assumed valid) or 26 (has trailing 12-bit checksum → validate, then truncate to first 16 bytes). Other lengths → error.

---

## 7. Plain `otpauth://` URI import ("Plain text" importer)

`GoogleAuthUriImporter` reads the input **line by line**, skips empty lines, and calls `GoogleAuthInfo.parseUri(line)` per line, wrapping each into a `VaultEntry`. Errors on a line are collected per-entry (bad line = skipped with an error, others still import). Fixture: `plain.txt` (7 lines). This importer does **not** handle `otpauth-migration://` (those decode via §8 only).

### 7.1 `GoogleAuthInfo.parseUri` algorithm
Given a URI string (parse as a URI; percent-decode query params and path):
1. `scheme` must be `otpauth` **or** `motp` (`MotpInfo.SCHEME`), else error "Unsupported protocol".
2. `secret` query param is **required**, else error.
   - If scheme is `motp`: secret = **hex**-decode.
   - Else: secret = `parseSecret` = trim, remove all `-` and space chars, then **base32**-decode.
   - If secret length == 0 → error "Secret is empty".
3. Determine `type`:
   - scheme `motp` → type = `"motp"`.
   - else type = the URI **host/authority**, which Android returns **lowercased**. Valid: `totp`, `steam`, `hotp`, `yaotp` (Yandex `HOST_ID`), `motp`. Host missing → error. Unknown → error "Unsupported OTP type".
4. Build OtpInfo by type:
   - `totp`: `TotpInfo(secret)` (algo SHA1, digits 6, period 30); if `period` param present → override period (int).
   - `steam`: `SteamInfo(secret)` (digits 5); optional `period`.
   - `hotp`: `counter` param **required** (else error); `HotpInfo` with that counter (int64).
   - `yaotp`: optional `pin` param → base32-decode then interpret bytes as UTF-8 string; `YandexInfo(secret, pin)`; also set `issuer = "Yandex"`.
   - `motp`: `MotpInfo(secret)`.
5. **Label / issuer / accountName** from the path (path minus leading `/`):
   - If label contains `:`: split on `:`. If exactly 2 parts → `issuer = parts[0]`, `accountName = parts[1]`. Otherwise → `accountName = whole label` (issuer unchanged). (Java `split(":")` drops trailing empties, so `"Issuer:"` → 1 part → accountName `"Issuer:"`; `":Name"` → `["","Name"]` → issuer `""`, name `"Name"`.)
   - If no `:`: `accountName = label`; if issuer not already set (e.g. not Yandex), `issuer = issuer` query param or `""`.
6. **Override** algorithm/digits (applied after label parsing):
   - `algorithm` param present → `setAlgorithm` (validates SHA1/256/512/MD5, strips `Hmac`, uppercases).
   - `digits` param present → `setDigits` (int, 1–10).
7. Result: `GoogleAuthInfo(otpInfo, accountName, issuer)` → `new VaultEntry(info)` sets name = accountName, issuer = issuer.

Example lines that must parse (from `plain.txt`):
```
otpauth://totp/Deno:Mason?secret=4SJHB4GSD43FZBAI7C2HLRJGPQ&issuer=Deno&algorithm=SHA1&digits=6&period=30
otpauth://hotp/Air%20Canada:Benjamin?secret=KUVJJOM753IHTNDSZVCNKL7GII&issuer=Air+Canada&algorithm=SHA256&digits=7&counter=50
otpauth://steam/Boeing:Sophia?secret=JRZCL47CMXVOQMNPZR2F7J4RGI&issuer=Boeing&algorithm=SHA1&digits=5&period=30
```
(Note `%20` in path and `+` in query both decode to space — use standard URI percent-decoding; `+` → space in query strings.)

---

## 8. Google Authenticator `otpauth-migration://` import (protobuf)

Reference: `GoogleAuthInfo.parseExportUri`. This is invoked when scanning a Google Authenticator "export accounts" QR code (not via the file "Plain text" importer).

### 8.1 URI validation
- `scheme` must equal `otpauth-migration`.
- `host` must equal `offline`.
- Query param `data` required. It arrives **URL/percent-decoded** by the URI parser, then is **standard base64-decoded** to protobuf bytes.

### 8.2 Protobuf schema (`google_auth.proto`, proto3, outer class `GoogleAuthProtos`)
```proto
message MigrationPayload {
  enum Algorithm  { ALGORITHM_UNSPECIFIED=0; ALGORITHM_SHA1=1; ALGORITHM_SHA256=2; ALGORITHM_SHA512=3; ALGORITHM_MD5=4; }
  enum DigitCount { DIGIT_COUNT_UNSPECIFIED=0; DIGIT_COUNT_SIX=1; DIGIT_COUNT_EIGHT=2; }
  enum OtpType    { OTP_TYPE_UNSPECIFIED=0; OTP_TYPE_HOTP=1; OTP_TYPE_TOTP=2; }
  message OtpParameters {
    bytes secret     = 1;   // RAW secret bytes (NOT base32)
    string name      = 2;
    string issuer    = 3;
    Algorithm algorithm = 4;
    DigitCount digits   = 5;
    OtpType type        = 6;
    int64 counter       = 7;
  }
  repeated OtpParameters otp_parameters = 1;
  int32 version        = 2;
  int32 batch_size     = 3;
  optional int32 batch_index = 4;
  int32 batch_id       = 5;
}
```
A Swift port needs a minimal protobuf wire-format decoder for these field numbers/types (varint for enums/int32/int64, length-delimited for `bytes`/`string`/embedded messages). No external proto runtime required.

### 8.3 Per-`OtpParameters` decode → GoogleAuthInfo
For each entry in `otp_parameters`:
- **digits**: `DIGIT_COUNT_UNSPECIFIED`(0) or `DIGIT_COUNT_SIX`(1) → **6**; `DIGIT_COUNT_EIGHT`(2) → **8**; anything else → error.
- **algorithm**: `ALGORITHM_UNSPECIFIED`(0) or `ALGORITHM_SHA1`(1) → `"SHA1"`; `ALGORITHM_SHA256`(2) → `"SHA256"`; `ALGORITHM_SHA512`(3) → `"SHA512"`; else (incl. MD5=4) → error "Unsupported hash algorithm".
- **secret**: raw bytes from field 1; if empty → error.
- **type**: `OTP_TYPE_UNSPECIFIED`(0) or `OTP_TYPE_TOTP`(2) → `TotpInfo(secret, algo, digits, period = 30)`; `OTP_TYPE_HOTP`(1) → `HotpInfo(secret, algo, digits, counter = field 7)`; else → error.
- **name/issuer split**: take `name` (field 2) and `issuer` (field 3). If `issuer` is empty **and** `name` contains a `:`, split at the **first** `:` → `issuer = name[0..colon]`, `name = name[colon+1..]`.
- Produce `GoogleAuthInfo(otpInfo, name, issuer)`.

The result also carries batch info: `Export(entries, batchId = field 5, batchIndex = field 4, batchSize = field 3)`. Google splits large exports across multiple QR codes; each QR is one payload with the same `batch_id` and increasing `batch_index` up to `batch_size`. To import a full export, collect all batches sharing a `batch_id` and concatenate their entries. Helpers: `isSingleBatch` (all `batch_id` equal), `getMissingIndices` (which `batch_index` in `0..batch_size-1` are absent).

---

## 9. Aegis export writing

Reference: `VaultRepository.export*` + `ImportExportPreferencesFragment`. Formats offered in the UI dropdown `export_formats`: index **0 = Aegis JSON** (plaintext or encrypted), index **1 = HTML**, index **2 = Google Authenticator URI (txt)**. The encryption checkbox is only enabled/checked for index 0. (HTML export is out of scope here.)

### 9.1 Encrypted / plaintext Aegis JSON (`exportFiltered`)
1. Build the vault DB JSON (§5) — optionally filtered to selected groups (`EntryFilter`). Note: **all groups are always serialized**, even unfiltered ones; only entries are filtered.
2. If exporting **encrypted**:
   - Use credentials; first call `creds.exportable()` (§7.3 slot stripping).
   - `VaultFile.setContent(dbObj, creds)`: serialize db as indent-4 JSON UTF-8, AES-256-GCM encrypt with the master key (fresh random 12-byte nonce), store `db = base64(ciphertext)`, `header.params = {nonce, tag}`, `header.slots = creds.slots.toJson()`.
   - If the source vault was **not** encrypted and the user chose encrypted export, Aegis generates a brand-new `VaultFileCredentials` (random 32-byte master key) and a new `PasswordSlot` from a user-entered password (scrypt N=32768,r=8,p=1, random salt), encrypts the master key into that slot, then encrypts as above.
3. If exporting **plaintext**: `creds = null` → `VaultFile.setContent(dbObj)` leaves `header = {slots:null, params:null}` and `db = dbObj` (object, unencrypted).
4. Serialize the `VaultFile` envelope with indent-4 JSON UTF-8 and write bytes.

### 9.2 Google Authenticator URI export (`exportGoogleUris`)
Newline-separated `otpauth://` URIs, one per entry, UTF-8. Built by `GoogleAuthInfo(entry.info, name, issuer).getUri()`:
- mOTP → `motp://` scheme, `secret` = **hex** of raw secret.
- else `otpauth://` with authority = `steam` (SteamInfo) / `yaotp` (YandexInfo) / `totp` (other TotpInfo) / `hotp`; query params in this order: `period` (TOTP-family) or `counter` (HOTP), then `digits`, `algorithm`, `secret` (**base32, no padding**), and `pin` (base32) for Yandex.
- Path/issuer: if issuer non-empty → path = `"<issuer>:<accountName>"` and add `issuer=<issuer>` query param; else path = accountName.

(There is also a "Google Authenticator style" QR export that builds `otpauth-migration://` payloads via `GoogleAuthInfo.Export.getUri()` — the inverse of §8: it only supports TOTP/HOTP entries with **digits == 6** and **algo == SHA1** (default), batches of `qrSize = 10` entries, random `batch_id`; incompatible entries are skipped.)

### 9.3 Export slot-stripping rules (`SlotList.exportable`)
When exporting encrypted (`creds.exportable()` → `slots.exportable()`):
- **Always drop BIOMETRIC slots** (type 2).
- If **any** backup password slot exists (`is_backup == true`), **drop all regular** password slots (`is_backup == false`), keeping only backup slots. This lets a vault be encrypted with a separate export-only password.
- Otherwise keep all (regular) password slots.

### 9.4 File naming conventions
`VaultBackupManager.FileInfo.toString()` = `"<prefix>-<yyyyMMdd-HHmmss>.<ext>"` where the timestamp uses `SimpleDateFormat("yyyyMMdd-HHmmss", Locale.ENGLISH)` (strict, non-lenient). Prefixes/extensions:

| Purpose | Prefix constant | Value | Ext | MIME | Example filename |
|---|---|---|---|---|---|
| Internal vault file | `VaultRepository.FILENAME` | `aegis.json` | — | application/json | `aegis.json` (no timestamp) |
| Encrypted JSON export | `FILENAME_PREFIX_EXPORT` | `aegis-export` | json | application/json | `aegis-export-20260717-143005.json` |
| Plaintext JSON export | `FILENAME_PREFIX_EXPORT_PLAIN` | `aegis-export-plain` | json | application/json | `aegis-export-plain-20260717-143005.json` |
| Google URI export | `FILENAME_PREFIX_EXPORT_URI` | `aegis-export-uri` | txt | text/plain | `aegis-export-uri-20260717-143005.txt` |
| HTML export | `FILENAME_PREFIX_EXPORT_HTML` | `aegis-export-html` | html | text/html | `aegis-export-html-20260717-143005.html` |
| Auto backup (single) | `VaultBackupManager.FILENAME_SINGLE` | `aegis-backup.json` | json | application/json | `aegis-backup.json` |
| Auto backup (versioned) | `VaultBackupManager.FILENAME_PREFIX` | `aegis-backup` | json | application/json | `aegis-backup-20260717-143005.json` |

Backup filename parsing (`FileInfo.parseFilename`, used for versioned-backup cleanup): must end `.json`; split on `-`; ≥ 3 parts; the part-prefix (all but last two segments, rejoined by `-`) must equal `aegis-backup`; the last two segments (`yyyyMMdd` + `-` + `HHmmss`) must strictly parse as the date. Versioned backups keep the N most recent by parsed date and delete older ones.

---

## 10. Validation / error cases to reproduce

- VaultFile `version > 1` → reject ("unsupported version").
- Vault DB `version > 3` → reject ("Unsupported version").
- Slot with unknown `type` int → error ("unrecognized slot type").
- Wrong password → every password slot fails GCM auth → return "Password incorrect" (do not throw on individual slot auth failure; only after all slots exhausted).
- GCM auth failure on vault content with a valid master key → corrupt file.
- `otpauth://` missing `secret` → error; empty secret → error; `hotp` missing `counter` → error; unknown host/type → error; unsupported scheme → error.
- `otpauth-migration://`: wrong scheme/host → error; missing `data` → error; bad base64 or malformed protobuf → error; per-entry unsupported digits/algorithm(incl. MD5)/type or empty secret → that entry errors (surfaced per-entry).
- OtpInfo: digits outside 1–10 → error; invalid algorithm → error; totp period ≤ 0 → error; hotp counter < 0 → error.
- Icon parse failures are **silently ignored** (entry imported without icon).
- Groups referenced by an entry but absent from the group list are silently dropped from the entry.

---

## 11. Test fixtures present in the repo (reuse as integration fixtures)

Directory `app/src/test/resources/com/beemdevelopment/aegis/importers/` (absolute base `/Users/myl/app/Aegis/app/src/test/resources/com/beemdevelopment/aegis/`). In-scope fixtures and their known passwords (from `DatabaseImporterTest.java`):

| File | Format | Password | Notes |
|---|---|---|---|
| `importers/aegis_plain.json` | Aegis plaintext vault (VaultFile v1, db v1) | — | 7 entries; matches canonical vectors (§12) minus Battle.net |
| `importers/aegis_encrypted.json` | Aegis encrypted vault (1 password slot) | **`test`** | scrypt N=32768,r=8,p=1; slot `repaired:true`; decrypts to same 7 entries |
| `importers/plain.txt` | Newline `otpauth://` URIs (7 lines) | — | for `GoogleAuthUriImporter` |
| `vault/aegis_plain_grouped_v2.json` | Aegis plaintext vault, **db version 2** with legacy `group` (name) field | — | exercises old→new group migration: groups `group1` (2 entries), `group2` (1 entry) |

Google Authenticator's own `.sqlite` DB fixture (`importers/google_authenticator.sqlite`, no password) is for the SQLite-based `GoogleAuthImporter`, not the `otpauth-migration` decode; the repo has **no** committed `otpauth-migration://` payload fixture — generate one for the Swift port's §8 tests.

Canonical expected entries live in `app/src/test/java/com/beemdevelopment/aegis/vectors/VaultEntries.java` (§12). Test password constants for the encrypted-export android tests (`AegisTest.java`): `VAULT_PASSWORD = "test"`, `VAULT_PASSWORD_CHANGED = "test2"`, `VAULT_BACKUP_PASSWORD = "something"`, `VAULT_BACKUP_PASSWORD_CHANGED = "something2"`.

---

## 12. Canonical expected vectors (`VaultEntries.get()`)

Use these to assert correct import (secret is base32). Note the `aegis_plain.json`/`aegis_encrypted.json` fixtures contain the first **7** (through Boeing/Steam); the 8th (Battle.net) is only used by other importers.

| # | type | issuer | name | secret (base32) | algo | digits | period/counter |
|---|---|---|---|---|---|---|---|
| 1 | totp | Deno | Mason | `4SJHB4GSD43FZBAI7C2HLRJGPQ` | SHA1 | 6 | period 30 |
| 2 | totp | SPDX | James | `5OM4WOOGPLQEF6UGN3CPEOOLWU` | SHA256 | 7 | period 20 |
| 3 | totp | Airbnb | Elijah | `7ELGJSGXNCCTV3O6LKJWYFV2RA` | SHA512 | 8 | period 50 |
| 4 | hotp | Issuu | James | `YOOMIXWS5GN6RTBPUFFWKTW5M4` | SHA1 | 6 | counter 1 |
| 5 | hotp | Air Canada | Benjamin | `KUVJJOM753IHTNDSZVCNKL7GII` | SHA256 | 7 | counter 50 |
| 6 | hotp | WWE | Mason | `5VAML3X35THCEBVRLV24CGBKOY` | SHA512 | 8 | counter 10300 |
| 7 | steam | Boeing | Sophia | `JRZCL47CMXVOQMNPZR2F7J4RGI` | SHA1 | 5 | period 30 |
| 8 | totp | Battle.net | US-2211-2050-3346 | `BMGRXPGFARQQF4GMT25JATL2VYLAHDBI` | SHA1 | 8 | period 30 |

Equivalence check used by tests: two entries are "equivalent" if name, issuer, OtpInfo (type+secret+algo+digits, plus period/counter/pin), icon, note, favorite, and group set all match (UUID ignored), and their generated OTP values match.

## CRITICAL FACTS (must preserve exactly)

- AEAD = AES-256-GCM: key 32 bytes, nonce/IV 12 bytes, GCM tag 16 bytes (128-bit). AES/GCM/NoPadding.
- GCM tag is stored SEPARATELY from ciphertext on disk (params.tag / key_params.tag); must be re-appended before decrypt. In CryptoKit build SealedBox(nonce, ciphertext, tag).
- scrypt params default N=1<<15=32768, r=8, p=1, dkLen=32. For password slots read n/r/p/salt from the slot JSON.
- Password bytes = UTF-8 of password string (Array(password.utf8)). Legacy >64-byte bug only for unrepaired old vaults.
- VaultFile top-level version = 1 (reject >1). Encrypted iff header.slots and header.params are both non-null. Encrypted db = base64(ciphertext string); plaintext db = JSON object.
- Vault DB version currently 3 (reject >3); versions 1/2 also parse. DB = {version, entries[], groups[], icons_optimized}.
- Slot types: 0=RAW, 1=PASSWORD, 2=BIOMETRIC. Only PASSWORD (type 1) is password-unlockable. BIOMETRIC never appears in exports.
- Password slot JSON: type,uuid,key(hex encrypted master key 32B),key_params{nonce,tag},n,r,p,salt(hex),repaired(default false),is_backup(default false).
- Slot unlock: for each password slot derive scrypt key from password+slot params, GCM-open key/key_params to recover 32-byte master key; ignore GCM-auth failures and try next slot; all fail => wrong password.
- Vault content decrypt: base64_decode(db) as ciphertext, GCM-open with master key + header.params.nonce + header.params.tag.
- Base32: RFC4648 alphabet, encode WITHOUT padding, decode uppercases input and tolerates missing padding. Used for OtpInfo secret and pin.
- Base64: standard RFC4648 with padding (db ciphertext, icons, migration data). Hex: base16, lowercase encode, case-insensitive decode (key/nonce/tag/salt/icon_hash).
- OtpInfo common fields: secret(base32,nopad), algo(SHA1|SHA256|SHA512|MD5), digits(1-10). totp/steam add period; hotp adds counter(int64>=0); motp/yandex add pin.
- OtpInfo.fromJson MD5 workaround: if type != 'motp' and algo=='MD5', force algo='SHA1'.
- Type ids: totp, steam(digits 5), hotp, motp(algo MD5/period 10/digits 6), yandex(algo SHA256/digits 8, secret normalized to 16 bytes; 26-byte secret validated+truncated).
- otpauth:// parseUri: scheme otpauth or motp; secret required (hex for motp, else base32 via parseSecret which strips '-' and spaces); host(lowercased)=type in {totp,steam,hotp,yaotp,motp}; hotp requires counter; period/digits/algorithm optional overrides; label path split on ':' -> issuer:accountName (exactly 2 parts) else accountName=whole; yaotp forces issuer 'Yandex'.
- Google migration URI: scheme MUST be 'otpauth-migration', host MUST be 'offline', query 'data' base64-decoded to protobuf MigrationPayload.
- MigrationPayload proto3 fields: OtpParameters{secret=1 bytes(RAW not base32), name=2, issuer=3, algorithm=4 enum, digits=5 enum, type=6 enum, counter=7 int64}; MigrationPayload{otp_parameters=1 repeated, version=2, batch_size=3, batch_index=4, batch_id=5}.
- Migration enum mappings: DigitCount UNSPECIFIED/SIX->6, EIGHT->8. Algorithm UNSPECIFIED/SHA1->SHA1, SHA256->SHA256, SHA512->SHA512, MD5->error. OtpType UNSPECIFIED/TOTP->Totp(period 30), HOTP->Hotp(counter). Empty secret->error.
- Migration name/issuer: if issuer empty and name contains ':', split at FIRST ':' -> issuer=before, name=after.
- Export slot stripping (SlotList.exportable): always drop BIOMETRIC; if any is_backup slot exists, drop all regular password slots.
- Export file naming '<prefix>-yyyyMMdd-HHmmss.<ext>': aegis-export(.json encrypted), aegis-export-plain(.json), aegis-export-uri(.txt), aegis-export-html(.html); auto-backup aegis-backup(.json) or single aegis-backup.json; internal vault file aegis.json.
- Entry icon: icon(base64|null), icon_mime(image/svg+xml|image/png|image/jpeg; absent=>JPEG default), icon_hash(hex)=SHA-256(utf8(mime)||bytes); all icon parse errors silently ignored.
- Legacy group migration: entries with 'group' (name string) instead of 'groups'[uuid] get a VaultGroup created/reused by name (Vault.migrateOldGroup). Groups referenced but absent are dropped from entry.
- Encrypted JSON plaintext is pretty-printed JSON with indent=4, UTF-8. Key order not significant for parsing.
- Test fixtures: aegis_plain.json (no pw), aegis_encrypted.json (pw 'test'), plain.txt, aegis_plain_grouped_v2.json (legacy groups). Encrypted-export test passwords: 'test','test2','something','something2'.

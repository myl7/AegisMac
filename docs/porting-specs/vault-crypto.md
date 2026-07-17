
# Aegis Vault File Format & Cryptography — Swift/SwiftUI Port Spec

This spec describes Aegis Authenticator's on-disk/exported vault format and all cryptography needed to read and write it byte-compatibly. Everything here is taken from the Java source (`vault/`, `crypto/`). Encoding choices, buffer lengths, and the tag-splitting behavior are the load-bearing details — read those sections carefully.

---

## 1. Encoding primitives (which encoding each field uses)

| Encoding | Library behavior in Aegis | Where used |
|---|---|---|
| **Base64** | Guava `BaseEncoding.base64()` = RFC 4648 standard alphabet `A–Z a–z 0–9 + /`, `=` padding. Decode throws on invalid. | Encrypted `db` payload string; entry `icon` bytes. |
| **Hex (base16)** | Encode: **lowercase** (`base16().lowerCase()`). Decode: input is **uppercased first** then decoded, so decode is case-insensitive. | Slot `key`, slot `key_params.nonce`, slot `key_params.tag`, password slot `salt`, header `params.nonce`, header `params.tag`, entry `icon_hash`. |
| **Base32** | Encode: RFC 4648 alphabet, **padding omitted** (`omitPadding()`). Decode: input uppercased first, standard RFC 4648 (accepts padding if present). | OTP `secret` inside entry `info`. |

Swift notes:
- Base64: use `Data(base64Encoded:)` / `.base64EncodedString()` (standard alphabet, matches).
- Hex: write lowercase; read case-insensitively. No standard library helper — implement or use a small helper.
- Base32: needs a custom/3rd-party implementation. When **encoding**, produce **no `=` padding**. When decoding, accept both cases and optional padding.

---

## 2. Cryptographic constants (verbatim)

```
AEAD algorithm:        "AES/GCM/NoPadding"  (AES-256-GCM)
AEAD key size:         32 bytes  (256-bit)
AEAD tag size:         16 bytes  (128-bit)   -> GCMParameterSpec tag length = 128 bits
AEAD nonce (IV) size:  12 bytes  (96-bit)

scrypt N (CPU/mem):    32768   (1 << 15)
scrypt r (block size): 8
scrypt p (parallel):   1
scrypt output length:  32 bytes (= AEAD key size)
scrypt salt length:    32 bytes (randomly generated)

master key length:     32 bytes (AES-256, randomly generated)
```

- scrypt is standard RFC 7914 (PBKDF2 core is **HMAC-SHA256**, 1 iteration). Any conformant scrypt (e.g. CryptoSwift, libsodium `crypto_pwhash_scryptsalsa208sha256`-compatible, or a dedicated RFC 7914 impl) with the parameters above produces identical output. Verified against RFC 7914 §12 test vectors in the Aegis test suite.
- No AAD (additional authenticated data) is ever used, anywhere.
- There is exactly one master key per vault. Every slot stores its own AES-GCM-encrypted copy of that same 32-byte master key. The master key encrypts the db payload.

### 2.1 CRITICAL: the GCM tag is stored SEPARATELY from the ciphertext

Java's `Cipher.doFinal()` returns `ciphertext || tag` (tag appended). Aegis explicitly **splits the last 16 bytes off as the tag** and stores ciphertext and tag in separate fields:

- On **encrypt**: `result = cipher.doFinal(plaintext)`; `tag = result[len-16 .. len]`; `ciphertext = result[0 .. len-16]`. Store `ciphertext` and `tag` and the 12-byte `nonce` separately.
- On **decrypt**: rebuild `ciphertext || tag` (append the stored tag to the stored ciphertext), then `cipher.doFinal()`.

This maps **perfectly** onto Apple CryptoKit, whose `AES.GCM.SealedBox` also keeps `nonce`, `ciphertext`, and `tag` as separate members:
- Decrypt: `AES.GCM.SealedBox(nonce: <nonce>, ciphertext: <ciphertext>, tag: <tag>)` then `AES.GCM.open(box, using: key)`.
- Encrypt: `let box = try AES.GCM.seal(plaintext, using: key)` then read `box.ciphertext`, `box.tag`, `box.nonce` (do NOT use `box.combined`, which concatenates them).

Because AES-GCM is a stream cipher, **ciphertext length == plaintext length**. So:
- Encrypted master key (plaintext = 32-byte master key) → `key` ciphertext is exactly **32 bytes → 64 hex chars**.
- Slot nonce → **12 bytes → 24 hex chars**; slot tag → **16 bytes → 32 hex chars**; salt → **32 bytes → 64 hex chars**.
- Header nonce → 12 bytes → 24 hex; header tag → 16 bytes → 32 hex.

### 2.2 Nonce generation

On encryption Aegis does **not** supply a nonce; it calls `cipher.init(ENCRYPT_MODE, key)` with no `GCMParameterSpec`, letting the JCE generate a fresh random 12-byte IV, then reads it back via `cipher.getIV()`. For the port: generate a cryptographically random **12-byte** nonce yourself for each encryption (`AES.GCM.Nonce()` in CryptoKit does this). Never reuse a nonce with the same key.

---

## 3. Outer vault file — `VaultFile`

- File name on disk (Android internal storage): **`aegis.json`**. Export filename prefixes: `aegis-export`, `aegis-export-plain`, `aegis-export-uri`, `aegis-export-html`.
- Serialized as **pretty-printed JSON with 4-space indentation** (`JSONObject.toString(4)`), UTF-8, no BOM. (Indentation is not cryptographically load-bearing for decryption — GCM just encrypts whatever bytes you produce — but reproduce it to match Aegis output exactly / for round-trip tests.)

### 3.1 Top-level schema

```json
{
  "version": 1,
  "header": { "slots": <array|null>, "params": <object|null> },
  "db": <string | object>
}
```

- `version` (int): outer file format version. **VaultFile.VERSION = 1.** On read: reject if `version > 1`.
- `header`: see §3.2.
- `db`:
  - **Encrypted vault**: `db` is a **Base64 string** of the AES-256-GCM **ciphertext of the db JSON** (ciphertext only, tag lives in `header.params.tag`).
  - **Plaintext vault**: `db` is a **nested JSON object** (the raw Vault db, §5), not a string.

**How the reader decides encrypted vs plaintext:** parse `header`; if `header.isEmpty()` (both `slots` and `params` are JSON `null`) → plaintext, read `db` as an object. Otherwise → encrypted, read `db` as a string.

### 3.2 Header

```json
// Plaintext vault:
"header": { "slots": null, "params": null }

// Encrypted vault:
"header": {
  "slots": [ <slot objects, §4> ],
  "params": { "nonce": "<hex, 24 chars>", "tag": "<hex, 32 chars>" }
}
```

- `params` = the `CryptParameters` for the **db** encryption: `nonce` (hex, 12 bytes) and `tag` (hex, 16 bytes). Both hex.
- `isEmpty()` ⟺ `slots == null && params == null`. When writing plaintext, emit both keys explicitly as JSON `null`.

---

## 4. Slots (`SlotList` / `Slot` subclasses)

`header.slots` is a JSON array of slot objects. Each slot is an independently-wrapped copy of the master key.

### 4.1 Common slot fields (all types)

```json
{
  "type": <int>,                 // 0 raw, 1 password, 2 biometric
  "uuid": "<uuid string>",       // canonical lowercase 8-4-4-4-12; if absent on read, generate a new random UUID
  "key": "<hex>",                // AES-GCM ciphertext of the 32-byte master key (32 bytes -> 64 hex chars)
  "key_params": {
      "nonce": "<hex, 24 chars>",// 12-byte GCM nonce used to wrap the master key
      "tag":   "<hex, 32 chars>" // 16-byte GCM tag
  }
}
```

Slot type constants:
```
TYPE_RAW       = 0x00
TYPE_PASSWORD  = 0x01
TYPE_BIOMETRIC = 0x02
```
Unknown type on read → error ("unrecognized slot type").

### 4.2 Password slot (type 1) — extra fields

```json
{
  "type": 1,
  "uuid": "...",
  "key": "...",
  "key_params": { "nonce": "...", "tag": "..." },
  "n": 32768,
  "r": 8,
  "p": 1,
  "salt": "<hex, 64 chars>",     // 32-byte scrypt salt
  "repaired": <bool>,            // optional on read, default false
  "is_backup": <bool>            // optional on read, default false
}
```

- `n`, `r`, `p` (ints): the scrypt parameters used for **this slot** (persisted per-slot, so honor whatever is stored rather than assuming the defaults — though new slots always use 32768/8/1).
- `salt` (hex): scrypt salt for this slot.
- `repaired` (bool, `optBoolean(...,false)`): legacy repair flag for issue #95 (see §6.3). Default false if absent.
- `is_backup` (bool, `optBoolean(...,false)`): true = this is a backup password slot. Default false if absent.

### 4.3 Biometric slot (type 2)

- JSON is exactly the common slot shape (type=2, uuid, key, key_params) — **no extra fields**.
- The wrapping key is a hardware-backed AES-256-GCM key. On Android it lives in the AndroidKeyStore under the slot's UUID as the alias, generated with GCM, no padding, `setUserAuthenticationRequired(true)`, `setRandomizedEncryptionRequired(true)`, 256-bit. On macOS the equivalent is a Secure Enclave / Keychain key gated by LocalAuthentication (Touch ID), stored under the slot UUID. The slot ciphertext/nonce/tag semantics are identical to a raw slot; only the source of the wrapping key differs.
- **Biometric slots are stripped from exports** (see §4.5). A port that only imports/exports files may ignore biometric slots on read.

### 4.4 Raw slot (type 0)

- Common shape only, no extra fields. The wrapping key is a caller-supplied raw 32-byte AES key. Rarely present in user files; used for programmatic key wrapping.

### 4.5 Export filtering (`SlotList.exportable()`)

When producing an **export** file (not the primary `aegis.json`):
1. **Drop all biometric slots** (type 2).
2. If **any** password slot has `is_backup == true`, **drop all regular (non-backup) password slots**; keep the backup slot(s). If there is no backup slot, keep the regular password slots as-is.
   (Raw slots are always kept.)

---

## 5. Inner db payload (`Vault`) — the plaintext that the master key encrypts

After decrypting (or reading directly, if plaintext), the db is this JSON object:

```json
{
  "version": 3,
  "entries": [ <entry objects> ],
  "groups":  [ <group objects> ],
  "icons_optimized": true
}
```

- `version` (int): **Vault.VERSION = 3.** On read: reject if `version > 3`. Older versions (e.g. 2) are read and migrated (see §6.2).
- `entries`: array, §5.1.
- `groups`: array, §5.3. Always written in full even if unused.
- `icons_optimized` (bool): read with `optBoolean("icons_optimized")` — if missing or false, treated as false. New vaults write `true`.

When Aegis serializes the db for encryption it uses `JSONObject.toString(4)` (4-space pretty print), UTF-8, then encrypts those bytes.

### 5.1 Entry object (`VaultEntry`)

```json
{
  "type": "totp",                        // otp type id, lowercase: totp|hotp|steam|yandex|motp
  "uuid": "3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d",
  "name": "Mason",
  "issuer": "Deno",
  "note": "",
  "favorite": false,
  "icon": null,                          // null OR base64 string of image bytes
  "icon_mime": "image/jpeg",             // present ONLY when icon != null
  "icon_hash": "<hex>",                  // present ONLY when icon != null (SHA-256 over mime-bytes||icon-bytes)
  "info": { ... },                       // §5.2, depends on type
  "groups": [ "uuid", ... ]              // array of group UUID strings
}
```

Read rules:
- `uuid`: if absent, generate a new random UUID.
- `type`: string. `info` is parsed according to it.
- `name`, `issuer`: strings (`getString`, required-ish; default empty string in the object model).
- `note`: `optString("note","")`.
- `favorite`: `optBoolean("favorite",false)`.
- Grouping: if `groups` array is present, use it (list of group UUID strings) and ignore legacy `group`. Else if legacy `group` string is present (db v2), it names a group by name → migrate (see §6.2).
- Icon: parsed leniently — any icon parse error is swallowed and the entry keeps no icon (forward-compat with new image types). If `icon` is `null` → no icon. `icon_mime` default when absent but icon present = `image/jpeg`. `icon_hash` if present is used as-is; else recomputed. Icon hash = `SHA-256( utf8(mimeType) || iconBytes )`, hex-encoded. Icon types/mimes: `image/jpeg`, `image/png`, `image/svg+xml` (SVG), plus internal fallbacks; unknown mime → icon dropped.

### 5.2 `info` object per OTP type

Common fields (all types):
```
"secret": "<base32, no padding>",   // decoded to raw secret bytes
"algo":   "SHA1" | "SHA256" | "SHA512" | "MD5",
"digits": <int, 1..10>
```
Per-type additions:
- **totp**: `"period": <int > 0>`
- **steam**: `"period": <int>` (digits normally 5)
- **hotp**: `"counter": <long >= 0>`
- **yandex**: `"period": <int>`, `"pin": "<string>"` (algo defaults SHA256, digits 8)
- **motp**: `"period": <int>`, `"pin": "<string>"`, algo MD5, digits 6, period 10

Notes: If `type != "motp"` and `algo == "MD5"`, Aegis silently rewrites algo to `SHA1` on read (works around an old bug). `algo` may appear as `HmacSHA1` etc. in some inputs; the setter strips a leading `Hmac`. This `info`/OTP layer is a separate subsystem — reproduce field names exactly but the OTP-generation math is out of scope for this spec.

### 5.3 Group object (`VaultGroup`)

```json
{ "uuid": "<uuid string>", "name": "group1" }
```
Both fields required on read.

---

## 6. Decrypt / encrypt round-trip procedures

### 6.1 DECRYPT an encrypted vault (password path)

Input: file bytes, user password (as characters).

1. Parse the outer JSON (UTF-8). Verify `version <= 1`.
2. Read `header`. If `slots == null && params == null` → this is a **plaintext** vault; skip to step 8 using `db` as an object.
3. Parse `header.slots` into slot objects and `header.params` into `{nonce, tag}` (hex-decode both).
4. Collect all **password slots** (type 1). For each password slot, attempt:
   a. Encode the password to bytes: **UTF-8, exact length, no trailing NUL** (see §6.3).
   b. Derive slot key: `scrypt(passwordBytes, salt = hexDecode(slot.salt), N = slot.n, r = slot.r, p = slot.p, dkLen = 32)`.
   c. Reconstruct GCM box for the slot: `nonce = hexDecode(slot.key_params.nonce)`, `ciphertext = hexDecode(slot.key)`, `tag = hexDecode(slot.key_params.tag)`.
   d. `masterKey = AES-256-GCM open(box, key = slotKey)`. On authentication failure (bad tag), this slot/password combo is wrong → catch and try the **next** password slot. If all fail → wrong password.
   e. On success, `masterKey` is the 32-byte vault master key.
5. (Biometric slots are decrypted the analogous way but with the wrapping key obtained from the secure enclave/keychain instead of scrypt; same GCM open using the slot's nonce/ciphertext/tag.)
6. Base64-decode `db` → `dbCiphertext`.
7. Reconstruct GCM box for the db: `nonce = header.params.nonce`, `ciphertext = dbCiphertext`, `tag = header.params.tag`. `dbPlaintext = AES-256-GCM open(box, key = masterKey)`.
8. UTF-8-decode `dbPlaintext` (or take the `db` object directly if plaintext vault) → parse as Vault JSON (§5). Verify db `version <= 3`.

### 6.2 ENCRYPT / save a vault

Input: Vault model, master key (32 bytes), the existing slot list (each slot already holds its wrapped copy of the master key + params).

1. Build the db JSON object (§5), `version = 3`. Serialize with 4-space pretty print, UTF-8 → `dbBytes`.
2. Encrypt: generate a fresh 12-byte nonce; `sealed = AES-256-GCM seal(dbBytes, key = masterKey, nonce)`. Take `ciphertext = sealed.ciphertext` (NOT combined), `tag = sealed.tag`.
3. `db = Base64(ciphertext)`.
4. `header.params = { nonce: hex(nonce), tag: hex(tag) }`.
5. `header.slots = ` serialize each slot: for each, emit `type`, `uuid`, `key = hex(wrappedMasterKeyCiphertext)`, `key_params = { nonce: hex, tag: hex }`, plus password-slot extras (`n,r,p,salt,repaired,is_backup`).
6. Emit outer object `{ version: 1, header, db }`, 4-space pretty print, UTF-8. Write.

For a **plaintext** save: `header = { slots: null, params: null }`, `db` = the db JSON object inline (not encrypted, not base64), `version: 1`.

For an **export**: first apply `SlotList.exportable()` (§4.5) to the slots, then proceed as above.

### 6.3 Creating / re-wrapping a password slot (master-key wrapping flow)

To add a password slot that wraps the master key:
1. Generate a random 32-byte `salt`.
2. `slotKey = scrypt(utf8(password), salt, N=32768, r=8, p=1, dkLen=32)`.
3. Generate a fresh 12-byte nonce; `sealed = AES-256-GCM seal(masterKeyBytes /*32*/, key=slotKey, nonce)`.
4. Store: `key = hex(sealed.ciphertext)` (32 bytes), `key_params.nonce = hex(nonce)`, `key_params.tag = hex(sealed.tag)`, `n=32768, r=8, p=1, salt=hex(salt), repaired=true, is_backup=<as chosen>`, `uuid = new random UUID`.

**Password → bytes (issue #95 / `repaired`), important for compatibility with old vaults:**
- Correct/current encoding (`CryptoUtils.toBytes`): UTF-8 encode the password characters, take **exactly** `byteBuffer.limit()` bytes (no padding, no trailing NUL). This is what you should use for all new vaults and for the first decrypt attempt.
- Legacy encoding (`toBytesOld`): returned `byteBuffer.array()`, whose backing array can be **longer** than the actual content (extra trailing bytes) for some passwords. A bug meant slots created before the fix could have been wrapped with these longer bytes.
- Collision fact (from tests): because scrypt's PBKDF2-HMAC-SHA256 first block is 64 bytes, appending trailing NULs to an input that stays **≤ 64 bytes total** yields the **same** derived key. So for passwords whose UTF-8 length ≤ 64 bytes, correct and legacy encodings are equivalent and old slots decrypt fine with the correct encoding.
- Fallback (only needed to open old vaults with very long passwords): if the GCM open in §6.1 step 4d fails, the slot is **not** `repaired`, and the legacy-encoded byte length is **> 64**, retry the derivation using the legacy encoding and open again.
- After a successful decrypt of a not-`repaired` slot, Aegis re-wraps the master key using the correct-encoding slot key and sets `repaired = true`. This is cosmetic self-healing; a port can skip it, but must then continue to honor the fallback for old files. A greenfield port that only ever writes `repaired = true` slots never needs the fallback for its own files.

---

## 7. Worked examples (field names verbatim)

### 7.1 Encrypted vault (structure; hex/base64 values illustrative)

```json
{
    "version": 1,
    "header": {
        "slots": [
            {
                "type": 1,
                "uuid": "8f2e4b1a-0c3d-4e5f-9a6b-7c8d9e0f1a2b",
                "key": "e1c2...<64 hex chars total>...9f",
                "key_params": {
                    "nonce": "0a1b2c3d4e5f60718293a4b5",
                    "tag": "112233445566778899aabbccddeeff00"
                },
                "n": 32768,
                "r": 8,
                "p": 1,
                "salt": "9f8e7d6c5b4a39281706f5e4d3c2b1a0112233445566778899aabbccddeeff00",
                "repaired": true,
                "is_backup": false
            },
            {
                "type": 2,
                "uuid": "c4d5e6f7-a8b9-4c0d-8e1f-2a3b4c5d6e7f",
                "key": "77aa...<64 hex chars>...bc",
                "key_params": {
                    "nonce": "aabbccddeeff001122334455",
                    "tag": "00ffeeddccbbaa99887766554433221100"
                }
            }
        ],
        "params": {
            "nonce": "1f2e3d4c5b6a79889796a5b4",
            "tag": "fedcba98765432100123456789abcdef"
        }
    },
    "db": "QmFzZTY0LWVuY29kZWQtQUVTLUdDTS1jaXBoZXJ0ZXh0LW9mLXRoZS1kYi1KU09O..."
}
```

- The `db` string Base64-decodes to the AES-256-GCM ciphertext (tag NOT included). Decrypt with `masterKey`, nonce = `header.params.nonce`, tag = `header.params.tag`.
- Each slot's `key` hex-decodes to the 32-byte wrapped master-key ciphertext; open with that slot's derived/wrapping key, nonce/tag from its `key_params`.

### 7.2 Plaintext (unencrypted) vault — real shape (adapted from the test resource; note `version: 3`, `groups` array + `icons_optimized`)

```json
{
    "version": 1,
    "header": {
        "slots": null,
        "params": null
    },
    "db": {
        "version": 3,
        "entries": [
            {
                "type": "totp",
                "uuid": "3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d",
                "name": "Mason",
                "issuer": "Deno",
                "note": "",
                "favorite": false,
                "icon": null,
                "info": {
                    "secret": "4SJHB4GSD43FZBAI7C2HLRJGPQ",
                    "algo": "SHA1",
                    "digits": 6,
                    "period": 30
                },
                "groups": [ "b6f3e2a1-1111-4222-8333-444455556666" ]
            },
            {
                "type": "hotp",
                "uuid": "0a8c0571-ff6f-4b02-aa4b-50553b4fb4fe",
                "name": "James",
                "issuer": "Issuu",
                "note": "",
                "favorite": false,
                "icon": null,
                "info": {
                    "secret": "YOOMIXWS5GN6RTBPUFFWKTW5M4",
                    "algo": "SHA1",
                    "digits": 6,
                    "counter": 1
                },
                "groups": []
            },
            {
                "type": "steam",
                "uuid": "5b11ae3b-6fc3-4d46-8ca7-cf0aea7de920",
                "name": "Sophia",
                "issuer": "Boeing",
                "note": "",
                "favorite": false,
                "icon": null,
                "info": {
                    "secret": "JRZCL47CMXVOQMNPZR2F7J4RGI",
                    "algo": "SHA1",
                    "digits": 5,
                    "period": 30
                },
                "groups": []
            }
        ],
        "groups": [
            { "uuid": "b6f3e2a1-1111-4222-8333-444455556666", "name": "group1" }
        ],
        "icons_optimized": true
    }
}
```

### 7.3 Legacy db (version 2) grouping — for read/migration only

Old files used `"version": 2` in db, no top-level `groups` array, and each entry carried a single `"group": "<name>"|null` field (plus `"icon_mime": null`). Migration (§6.2): for each entry with a non-null `group` name, find or create a `VaultGroup` with that name (merging entries that share a name into one group), assign the group's UUID to the entry's `groups` set, and clear the legacy field. When re-saved, the db becomes version 3 with a `groups` array and `groups` UUID lists on entries.

---

## 8. Miscellaneous rules & gotchas checklist

- Outer file version `> 1` → reject. Db version `> 3` → reject. Both are `<=` checks.
- UUIDs are Java `UUID.toString()` = **lowercase** canonical `8-4-4-4-12`. Generate v4 random UUIDs when absent.
- Numeric JSON types: `version`, `type`(slot), `n`, `r`, `p`, `digits`, `period` are ints; `counter` is a 64-bit long; slot `type` serialized as an int.
- Booleans: `repaired`, `is_backup`, `favorite`, `icons_optimized`.
- No AAD in any GCM operation. Tag length always 128 bits. Nonce always 12 bytes. Key always 32 bytes.
- The tag is always stored/transported **separately** from ciphertext (both for slot key-wrapping and for the db). Re-join before decrypting; split after encrypting. (CryptoKit `SealedBox` handles this natively — avoid `.combined`.)
- scrypt salt for a new password slot = 32 random bytes; but on read use the per-slot stored `n/r/p/salt`.
- All slots wrap the identical master key; decrypting any one slot yields the same 32 bytes.
- Password bytes = exact-length UTF-8 (no trailing NUL). Legacy fallback only for un-`repaired` slots whose legacy encoding exceeds 64 bytes.
- On decrypt, iterate password slots and treat GCM auth failure as "try next"; only conclude "wrong password" after all fail.
- Exports strip biometric slots and, when a backup password slot exists, strip regular password slots.
- Files are UTF-8, pretty-printed with 4-space indent. Not required for decryption correctness, but required to byte-match Aegis output.


## CRITICAL FACTS (must preserve exactly)

- AEAD = AES-256-GCM ('AES/GCM/NoPadding'); key 32 bytes, GCM tag 16 bytes (128-bit), nonce/IV 12 bytes (96-bit). No AAD anywhere.
- GCM tag is stored SEPARATELY from ciphertext (Java splits off the last 16 bytes). On decrypt you must re-append tag to ciphertext; on encrypt split it off. Maps to CryptoKit AES.GCM.SealedBox(nonce,ciphertext,tag) — do NOT use .combined.
- scrypt params: N=32768 (1<<15), r=8, p=1, dkLen=32; salt=32 random bytes. Standard RFC 7914 (PBKDF2-HMAC-SHA256, 1 iteration).
- Master key = 32 random bytes (AES-256). Exactly one per vault; every slot stores its own AES-GCM-wrapped copy; master key encrypts the db.
- Outer VaultFile.VERSION = 1 (reject version>1). Inner Vault(db).VERSION = 3 (reject version>3, migrate v2).
- Encoding per field: db payload string = Base64 (RFC4648 std, '=' padding); slot key, key_params.nonce, key_params.tag, password salt, header params.nonce, header params.tag, icon_hash = HEX (lowercase on write, case-insensitive read); OTP secret = Base32 (RFC4648, NO padding on encode).
- Slot type ints: 0=raw, 1=password, 2=biometric. Common fields: type, uuid, key(hex ciphertext of master key, 32B->64hex), key_params{nonce(24hex),tag(32hex)}.
- Password slot extra fields: n, r, p (ints), salt (hex 64), repaired (bool, optBoolean default false), is_backup (bool, optBoolean default false).
- Encrypted vault: header.slots=array, header.params={nonce,tag} hex, db=Base64 string of db-JSON ciphertext (tag in header.params.tag). Plaintext vault: header.slots=null AND header.params=null, db = nested JSON object.
- Password->bytes = UTF-8 exact length, NO trailing NUL. Legacy 'toBytesOld' fallback (retry with longer encoding) only when slot not repaired AND legacy length >64 bytes; passwords <=64 bytes collide to same scrypt key so no fallback needed.
- Decrypt: iterate password slots, GCM auth failure => try next slot; only 'wrong password' after all fail. Then Base64-decode db, GCM-open with master key + header.params nonce/tag.
- Files are UTF-8, pretty-printed with 4-space indent (JSONObject.toString(4)).
- UUIDs = lowercase canonical 8-4-4-4-12; generate random v4 when absent on read.
- Entry info common fields: secret(base32 no pad), algo(SHA1/SHA256/SHA512/MD5), digits(int 1..10). totp/steam add period; hotp adds counter(long); yandex/motp add period+pin. If type!=motp and algo==MD5, algo rewritten to SHA1 on read.
- Export filtering (SlotList.exportable): drop all biometric slots; if any is_backup password slot exists, drop all non-backup password slots; raw slots kept.
- Entry icon: icon=null or Base64 image bytes; icon_mime and icon_hash present only when icon!=null; icon_hash = hex(SHA-256(utf8(mimeType) || iconBytes)). Icon parse errors are silently ignored (entry keeps no icon).

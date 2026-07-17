
# Aegis OTP Generation & otpauth URI Handling — Swift Port Spec

This spec covers OTP code generation (HOTP/TOTP/Steam/Yandex/MOTP) and `otpauth://` /
`otpauth-migration://` URI parsing/serialization, plus the vault JSON shape for OTP entries.
All algorithms, constants, and test vectors are transcribed verbatim from the Aegis Android
source. Byte-for-byte reproduction of these algorithms is required for cross-compatibility.

---

## 1. Encoding primitives (`encoding/`)

All three use Guava `BaseEncoding`. Reimplement to match exactly:

### Base32 (RFC 4648, alphabet `ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`)
- `decode(s)`: **uppercase the input first** (`s.toUpperCase`), then RFC-4648 base32 decode.
  Must **accept unpadded input** (Aegis encodes without padding but decodes with the padded
  decoder; Guava tolerates missing trailing `=`). Also accept padded input. Invalid chars or
  invalid final-block lengths → throw `EncodingException`.
- `encode(byte[])`: RFC-4648 base32, **uppercase, NO padding** (padding `=` omitted).
- `encode(String s)`: `encode(s.getBytes(UTF_8))`.

### Hex / Base16 (alphabet `0123456789ABCDEF`)
- `decode(s)`: **uppercase input first**, then base16 decode. Odd length / invalid char → throw.
- `encode(byte[])`: base16 **lowercase** output.

### Base64 (RFC 4648 standard, `A–Za–z0–9+/`, padding `=`)
- `decode(String)` / `decode(byte[]→UTF_8 String)`: standard base64 decode (padded).
- `encode(byte[])`: standard base64 **with padding**.

---

## 2. Core OTP math (`crypto/otp/`)

### 2.1 HOTP (`HOTP.java`) — RFC 4226 truncation (EXACT)

`getHash(secret, algo, counter)`:
1. Key = raw `secret` bytes as an HMAC key (`SecretKeySpec(secret, "RAW")`).
2. Encode `counter` (a signed 64-bit long) as **8 bytes big-endian**.
3. `mac = HMAC(algo)`; `mac.init(key)`; return `mac.doFinal(counterBytes)`.
   - `algo` is a Java Mac name: `"HmacSHA1"`, `"HmacSHA256"`, `"HmacSHA512"`, `"HmacMD5"`.

`generateOTP(secret, algo, digits, counter)` → produces an integer OTP `code`:
```
hash   = getHash(secret, algo, counter)
offset = hash[hash.length - 1] & 0x0f
otp    = ((hash[offset]     & 0x7f) << 24)
       | ((hash[offset + 1] & 0xff) << 16)
       | ((hash[offset + 2] & 0xff) << 8)
       |  (hash[offset + 3] & 0xff)
```
Returns an `OTP(code=otp, digits)`. `otp` is a 31-bit non-negative int.

`OTP.toString()` (decimal formatting):
```
code = otp % (int) Math.pow(10, digits)   // 10^digits
// left-pad with '0' until length == digits
```
Edge case: `(int) Math.pow(10, digits)` is a **double→int cast**. For `digits == 10`,
`10^10 = 1e10` saturates to `Integer.MAX_VALUE = 2147483647`, so the modulus for 10-digit
codes is 2147483647, not 10^10. For digits 1–9 the modulus is the exact power of ten. Digits
are validated to 1–10 (see §3.1), and codes are ≤ 2^31-1.

`OTP.toSteamString()` — Steam alphabet encoding (see §2.5).

### 2.2 TOTP (`TOTP.java`) — time-step

```
counter = (long) Math.floor((double) seconds / period)   // integer floor division
return HOTP.generateOTP(secret, algo, digits, counter)
```
- `seconds` = Unix time in seconds. Default source: `System.currentTimeMillis() / 1000`.
- `period` in seconds (e.g. 30). Both `period` and `seconds` are longs.

### 2.3 Steam — TOTP variant, 5-char alphabet output (see §2.5).

### 2.4 MOTP (`MOTP.java`) — Mobile-OTP (EXACT)

`generateOTP(secret, algo, digits, period, pin, time)`:
```
timeBasedCounter = time / period                 // long integer division (floor for +)
secretAsString   = Hex.encode(secret)            // LOWERCASE hex string
toDigest         = String.valueOf(timeBasedCounter) + secretAsString + pin   // string concat
code             = getDigest(algo, toDigest.getBytes(UTF_8))
```
`getDigest(algo, bytes)`:
```
md     = MessageDigest.getInstance(algo)   // algo == "MD5" (raw name, NOT "HmacMD5")
digest = md.digest(bytes)
return Hex.encode(digest)                  // LOWERCASE hex, 32 chars for MD5
```
`toString()`: `code.substring(0, digits)` → **first `digits` chars** of the lowercase hex
digest (default 6).

Notes: `timeBasedCounter` is rendered in decimal with no leading zeros. `pin` is a plain
string appended verbatim. MOTP always uses raw digest name `"MD5"` (via `getAlgorithm(false)`),
period 10, digits 6.

### 2.5 Steam alphabet (`OTP.java`)

```
STEAM_ALPHABET = "23456789BCDFGHJKMNPQRTVWXY"   // length 26
```
`toSteamString()` with `code` = the 31-bit int from HOTP truncation, `digits` = 5:
```
res = ""
code2 = code
for i in 0..<digits:              // 5 iterations
    c = STEAM_ALPHABET[ code2 % 26 ]
    res += c                       // append (NOT prepend) — least-significant char first
    code2 = code2 / 26
return res
```
So the first output char is `alphabet[code % 26]`, second is `alphabet[(code/26) % 26]`, etc.

### 2.6 Yandex OTP (`YAOTP.java`) — (EXACT)

```
EN_ALPHABET_LENGTH = 26
```
`generateOTP(secret, pin, digits, otpAlgo, period, seconds)`:
```
pinBytes    = pin.getBytes(UTF_8)
pinWithHash = pinBytes ++ secret                 // concatenation: PIN bytes first, then secret
keyHash     = SHA-256(pinWithHash)               // 32 bytes
if keyHash[0] == 0:                              // signed-byte == 0x00
    keyHash = keyHash[1..]                        // drop the first byte (now 31 bytes)

counter    = (long) Math.floor((double) seconds / period)
periodHash = HOTP.getHash(keyHash, otpAlgo, counter)   // HMAC, 8-byte BE counter; otpAlgo="HmacSHA256"
offset     = periodHash[periodHash.length - 1] & 0x0f
periodHash[offset] &= 0x7f                        // clear top bit in place
otp        = big-endian signed 64-bit long read from periodHash starting at byte `offset`
             // i.e. periodHash[offset..offset+7] as int64 BE (guaranteed >=0 due to mask)
```
`toString()`:
```
code = otp % (long) Math.pow(26, digits)         // 26^digits
chars = new char[digits]
for i from digits-1 downto 0:
    chars[i] = (char)('a' + (code % 26))
    code = code / 26
return String(chars)                             // lowercase a–z, length = digits
```
Key details: the counter HMAC uses `keyHash` (post-SHA256, possibly trimmed) as the HMAC key.
`otpAlgo` for Yandex is always `"HmacSHA256"`, digits 8, period 30. Output is 8 lowercase
letters. The secret passed in is the **parsed/truncated 16-byte Yandex secret** (see §3.6).

---

## 3. OtpInfo model classes (`otp/`)

Base class `OtpInfo` (abstract). Fields: `secret: byte[]`, `algorithm: String`, `digits: int`.

### 3.1 Constants & validation
```
OtpInfo.DEFAULT_DIGITS    = 6
OtpInfo.DEFAULT_ALGORITHM = "SHA1"
```
- `isAlgorithmValid(a)`: true iff `a` ∈ {`"SHA1"`, `"SHA256"`, `"SHA512"`, `"MD5"`} (exact,
  uppercase).
- `setAlgorithm(a)`: if `a` starts with `"Hmac"`, strip the 4-char prefix; then uppercase;
  then validate; store the **bare** name (e.g. "SHA1"). Invalid → `OtpInfoException`.
- `getAlgorithm(java)`: if `java == true` return `"Hmac" + name` (e.g. "HmacSHA1"); else the
  bare name.
- `isDigitsValid(d)`: `d > 0 && d <= 10`. (Comment: truncation extracts only 31 bits.)
- `getType()` = `getTypeId().toUpperCase()`. `getTypeId()` per subclass below.

Generation dispatch: each subclass implements `getOtp()` / `getOtp(long time)`. `checkSecret()`
throws `OtpInfoException("Secret is empty")` if `secret.length == 0` — called before every
generation.

### 3.2 TotpInfo (`getTypeId()` = `"totp"`)
```
DEFAULT_PERIOD = 30
```
- Fields add `period: int`.
- `isPeriodValid(p)`: `p > 0 && p <= Integer.MAX_VALUE/1000` (= `p <= 2147483`).
- `getOtp(time)`: `checkSecret()`; `TOTP.generateOTP(secret, getAlgorithm(true), digits, period, time).toString()`.
- `getMillisTillNextRotation(period)`: `p = period*1000; return p - (currentTimeMillis() % p)`.

### 3.3 HotpInfo (`getTypeId()` = `"hotp"`)
```
DEFAULT_COUNTER = 0
```
- Field `counter: long`. `isCounterValid(c)`: `c >= 0`. `incrementCounter()`: `counter += 1`.
- `getOtp()`: `checkSecret()`; `HOTP.generateOTP(secret, getAlgorithm(true), digits, counter).toString()`.

### 3.4 SteamInfo (extends TotpInfo, `getTypeId()` = `"steam"`)
```
DIGITS = 5
```
- Constructed as TotpInfo with algorithm SHA1, digits 5, period 30 (defaults).
- `getOtp(time)`: `checkSecret()`; `TOTP.generateOTP(secret, getAlgorithm(true), digits, period, time).toSteamString()`.
- `getType()` override: capitalize first letter → `"Steam"` (NOT all-caps).

### 3.5 MotpInfo (extends TotpInfo, `getTypeId()` = `"motp"`)
```
ID = "motp"; SCHEME = "motp"; ALGORITHM = "MD5"; PERIOD = 10; DIGITS = 6
```
- Constructed as TotpInfo with algorithm MD5, digits 6, period 10.
- Field `pin: String` (nullable until set).
- `getOtp(time)`: throws `IllegalStateException("PIN must be set…")` if pin null; else
  `MOTP.generateOTP(secret, getAlgorithm(false), digits, period, pin, time).toString()`.
  Note `getAlgorithm(false)` → `"MD5"` (raw MessageDigest name).

### 3.6 YandexInfo (extends TotpInfo, `getTypeId()` = `"yandex"`)
```
DEFAULT_ALGORITHM = "SHA256"; DIGITS = 8; SECRET_LENGTH = 16; SECRET_FULL_LENGTH = 26
ID = "yandex"; HOST_ID = "yaotp"
```
- Constructed as TotpInfo with algorithm SHA256, digits 8, period 30. Then `secret =
  parseSecret(secret)`. Field `pin: String` (nullable).
- `getOtp(time)`: throws `IllegalStateException` if pin null; else
  `YAOTP.generateOTP(secret, pin, digits, getAlgorithm(true), period, time).toString()`
  (`getAlgorithm(true)` → `"HmacSHA256"`).
- `getType()` override → `"Yandex"` (capitalize first letter).

`parseSecret(secret)`:
```
validateSecret(secret)
if secret.length != 16: return secret[0..16)      // truncate to first 16 bytes
return secret
```
`validateSecret(secret)` (checksum validation, ported from KeeYaOtp):
```
if length != 16 && length != 26: throw OtpInfoException("Invalid Yandex secret length…")
if length == 16: return                            // QR-code secrets have no checksum → valid

originalChecksum = ((secret[len-2] & 0x0F) << 8) | (secret[len-1] & 0xFF)   // 12-bit value
accum = 0 (16-bit); accumBits = 0
inputTotalBitsAvailable = length*8 - 12
inputIndex = 0; inputBitsAvailable = 8
while inputTotalBitsAvailable > 0:
    requiredBits = 13 - accumBits
    if inputTotalBitsAvailable < requiredBits: requiredBits = inputTotalBitsAvailable
    while requiredBits > 0:
        curInput   = (secret[inputIndex] & ((1 << inputBitsAvailable) - 1)) & 0xFF
        bitsToRead = min(requiredBits, inputBitsAvailable)
        curInput >>= (inputBitsAvailable - bitsToRead)
        accum = (accum << bitsToRead) | curInput
        inputTotalBitsAvailable -= bitsToRead
        requiredBits             -= bitsToRead
        inputBitsAvailable       -= bitsToRead
        accumBits                += bitsToRead
        if inputBitsAvailable == 0:
            inputIndex += 1; inputBitsAvailable = 8
    if accumBits == 13:
        accum ^= 0b1_1000_1111_0011           // = 0x18F3 = 6387 decimal
    accumBits = 16 - numberOfLeadingZeros16(accum)
if accum != originalChecksum: throw OtpInfoException("Yandex secret checksum invalid")
```
`numberOfLeadingZeros16(v)`: leading-zero count on a 16-bit value (0→16; else standard
binary-search LZ count over bits 15..0). All arithmetic is on 16-bit unsigned (`char` in Java);
implement with `UInt16` and mask to 16 bits after each shift.

### 3.7 equals()
Two OtpInfo are equal iff same `typeId`, same `secret` bytes, same bare algorithm, same digits;
plus subclass fields: TotpInfo also `period`; HotpInfo also `counter`; MotpInfo also `pin`;
YandexInfo also `pin`.

---

## 4. Vault JSON shape (`toJson` / `fromJson`)

Each entry stores OTP as a JSON object with a **separate `type` string** (the `getTypeId()`)
plus this object:
- Base keys: `"secret"` = Base32.encode(secret) (uppercase, unpadded), `"algo"` =
  getAlgorithm(false) (bare name), `"digits"` = int.
- TotpInfo adds `"period"` (int). HotpInfo adds `"counter"` (long). SteamInfo uses the totp
  shape (has `period`). YandexInfo adds `"pin"` (string) and has `period`. MotpInfo adds `"pin"`
  and has `period` (=10).

`fromJson(type, obj)`:
```
secret = Base32.decode(obj["secret"]); algo = obj["algo"]; digits = obj["digits"]
// MD5 workaround: if type != "motp" AND algo == "MD5": algo = "SHA1"   (DEFAULT_ALGORITHM)
switch type:
  "totp":   new TotpInfo(secret, algo, digits, obj["period"])
  "steam":  new SteamInfo(secret, algo, digits, obj["period"])
  "hotp":   new HotpInfo(secret, algo, digits, obj["counter"])   // counter is long
  "yandex": new YandexInfo(secret, obj["pin"])                    // note: ignores algo/digits, uses SHA256/8
  "motp":   new MotpInfo(secret, obj["pin"])                      // ignores algo/digits, uses MD5/6
  default:  OtpInfoException("unsupported otp type: …")
```
(The MD5→SHA1 workaround exists because a bug once let users set MD5 on non-MOTP entries.)

---

## 5. `otpauth://` URI parsing (`GoogleAuthInfo.parseUri`)

```
SCHEME        = "otpauth"
SCHEME_EXPORT = "otpauth-migration"
MotpInfo.SCHEME = "motp"
```
A `GoogleAuthInfo` holds `{ OtpInfo info, String accountName, String issuer }`.

**Parse steps:**

1. Parse URI. Scheme must equal `"otpauth"` OR `"motp"`; else `GoogleAuthInfoException`
   ("Unsupported protocol: …"). (Note `GoogleAuthInfoException.isPhoneFactor()` returns true if
   scheme == `"phonefactor"` — used only for a friendlier error elsewhere.)

2. `secret` query param is **required** ("Parameter 'secret' is not present" if missing).
   - If scheme == `"motp"`: `secret = Hex.decode(encodedSecret)`.
   - Else: `secret = parseSecret(encodedSecret)`.
   - If `secret.length == 0` → error "Secret is empty".

3. Determine `type`:
   - scheme == `"motp"` → type = `"motp"`.
   - else → type = `uri.getHost()` (the authority, e.g. `totp`/`hotp`/`steam`/`yaotp`). If null
     → error "Host not present…".

4. `issuer = ""`. Switch on `type`:
   - `"totp"`: `TotpInfo(secret)` [SHA1/6/period30]; if `period` param present →
     `setPeriod(Integer.parseInt(period))`.
   - `"steam"`: `SteamInfo(secret)` [SHA1/5/period30]; if `period` param present → setPeriod.
   - `"hotp"`: `HotpInfo(secret)`; `counter` param **required** ("Parameter 'counter' is not
     present" if missing) → `setCounter(Long.parseLong(counter))`.
   - `"yaotp"` (YandexInfo.HOST_ID): read `pin` param; if present, `pin = new
     String(parseSecret(pin), UTF_8)` — **the pin param is itself base32-decoded** then
     interpreted as a UTF-8 string. `info = YandexInfo(secret, pin)`; `issuer = info.getType()`
     (= `"Yandex"`).
   - `"motp"`: `MotpInfo(secret)` (pin NOT set from URI).
   - default → error "Unsupported OTP type: …".
   - Any `OtpInfoException` / `NumberFormatException` / `EncodingException` → wrapped
     `GoogleAuthInfoException`.

5. **Label / issuer / accountName resolution** (precedence matters):
   ```
   path  = uri.getPath()
   label = (path != null && path.length() > 0) ? path.substring(1) : ""   // strip leading '/'
   accountName = ""
   if label contains ":":
       parts = label.split(":")                 // Java split drops trailing empties
       if parts.length == 2:
           issuer = parts[0]; accountName = parts[1]     // OVERRIDES any earlier issuer (incl. Yandex)
       else:
           accountName = label                  // 0,1, or >2 colon-segments → whole label as account
   else:
       issuerParam = uri.getQueryParameter("issuer")
       if issuer.isEmpty():
           issuer = (issuerParam != null) ? issuerParam : ""
       accountName = label
   ```
   Precedence summary: (a) a single-colon label always wins for issuer; (b) otherwise the
   `issuer` query param fills issuer only if issuer is still empty; (c) Yandex pre-sets issuer to
   "Yandex", which survives unless a single-colon label overrides it. `label.split(":")` behaves
   like Java: `"a:"` → length 1; `"a:b"` → length 2; `"a:b:c"` → length 3.

6. **Algorithm/digits overrides** (applied to ALL types, after construction):
   ```
   if algorithm param present: info.setAlgorithm(algorithm)   // strips "Hmac", uppercases, validates
   if digits param present:    info.setDigits(Integer.parseInt(digits))
   ```
   Errors → wrapped `GoogleAuthInfoException`.
   **Important:** the recognized param name is `algorithm` (NOT `algo`). A URI using `algo=…`
   silently leaves the default. There is NO recognized `algorithm`/`digits` override applied to
   the pre-set Yandex/MOTP invariants beyond this generic step.

7. Return `GoogleAuthInfo(info, accountName, issuer)`.

**`parseSecret(String s)`** (base32 with tolerance):
```
s = s.trim().replace("-", "").replace(" ", "")   // trim whitespace; remove dashes and SPACE chars only
return Base32.decode(s)                            // decode uppercases internally
```

---

## 6. `otpauth://` URI serialization (`GoogleAuthInfo.getUri`)

Build with an Android `Uri.Builder` (values are percent-encoded on output).

- If `info` is **MotpInfo**:
  - scheme = `"motp"`.
  - append `secret` = `Hex.encode(secret)` (lowercase hex). **No** digits/algorithm/period params.
- Else scheme = `"otpauth"`:
  - Authority (host):
    - SteamInfo → `"steam"`; YandexInfo → `"yaotp"`; other TotpInfo → `"totp"`; then append
      `period` = period.
    - HotpInfo → `"hotp"`; then append `counter` = counter.
    - anything else → RuntimeException.
  - append `digits` = digits.
  - append `algorithm` = getAlgorithm(false) (bare name, e.g. "SHA1").
  - append `secret` = `Base32.encode(secret)` (uppercase, unpadded).
  - if YandexInfo → append `pin` = `Base32.encode(pin)` (pin string → UTF-8 → base32).
- Label + issuer (both scheme branches):
  ```
  if issuer != null && issuer != "":
      path = issuer + ":" + accountName        // e.g. "GitHub:alice"
      append issuer = issuer
  else:
      path = accountName
  ```
- Query param output order: for TOTP-family `[period, digits, algorithm, secret, (pin), issuer]`;
  for HOTP `[counter, digits, algorithm, secret, issuer]`; for MOTP `[secret, issuer]`.

---

## 7. `otpauth-migration://` — Google Authenticator protobuf (`google_auth.proto`)

proto3. Field numbers & wire types (all enums are varint / wire type 0):

```
message MigrationPayload {
  enum Algorithm  { ALGORITHM_UNSPECIFIED=0; ALGORITHM_SHA1=1; ALGORITHM_SHA256=2; ALGORITHM_SHA512=3; ALGORITHM_MD5=4; }
  enum DigitCount { DIGIT_COUNT_UNSPECIFIED=0; DIGIT_COUNT_SIX=1; DIGIT_COUNT_EIGHT=2; }
  enum OtpType    { OTP_TYPE_UNSPECIFIED=0; OTP_TYPE_HOTP=1; OTP_TYPE_TOTP=2; }

  message OtpParameters {
    bytes     secret    = 1;   // wire type 2 (length-delimited)
    string    name      = 2;   // wire type 2
    string    issuer    = 3;   // wire type 2
    Algorithm algorithm = 4;   // wire type 0 (varint)
    DigitCount digits   = 5;   // wire type 0
    OtpType   type      = 6;   // wire type 0
    int64     counter   = 7;   // wire type 0
  }

  repeated OtpParameters otp_parameters = 1;   // wire type 2, repeated
  int32  version     = 2;   // wire type 0
  int32  batch_size  = 3;   // wire type 0
  optional int32 batch_index = 4;   // wire type 0 (proto3 optional)
  int32  batch_id    = 5;   // wire type 0
}
```

### 7.1 Parse (`parseExportUri`)
1. scheme must == `"otpauth-migration"` (else "Unsupported protocol"); host must == `"offline"`
   (else "Unsupported host").
2. `data` param required ("Parameter 'data' is not set"). `bytes = Base64.decode(data)`;
   `payload = MigrationPayload.parseFrom(bytes)`.
3. For each `OtpParameters`:
   - digits: `DIGIT_COUNT_UNSPECIFIED` or `DIGIT_COUNT_SIX` → 6; `DIGIT_COUNT_EIGHT` → 8; else
     error "Unsupported digits".
   - algorithm: `ALGORITHM_UNSPECIFIED` or `ALGORITHM_SHA1` → "SHA1"; `ALGORITHM_SHA256` →
     "SHA256"; `ALGORITHM_SHA512` → "SHA512"; else error "Unsupported hash algorithm". (MD5 is
     NOT accepted on import.)
   - `secret = params.secret` bytes; if empty → error "Secret is empty".
   - type: `OTP_TYPE_UNSPECIFIED` or `OTP_TYPE_TOTP` → `TotpInfo(secret, algo, digits,
     DEFAULT_PERIOD=30)`; `OTP_TYPE_HOTP` → `HotpInfo(secret, algo, digits, params.counter)`;
     else error. (Period is always forced to 30 on import; Steam/Yandex/MOTP are not
     representable.)
   - name/issuer: `name = params.name; issuer = params.issuer; colonI = name.indexOf(':');
     if issuer.isEmpty() && colonI != -1: issuer = name[0..colonI]; name = name[colonI+1..]`.
   - Build `GoogleAuthInfo(otp, name, issuer)`.
4. Return `Export(infos, payload.batchId, payload.batchIndex, payload.batchSize)`.

`Export` fields: `batchId:int, batchIndex:int, batchSize:int, entries:List`. Helpers:
`isSingleBatch(exports)` (all same batchId), `getMissingIndices(exports)` (indices in
`0..<batchSize` not present among `batchIndex` values).

### 7.2 Serialize (`Export.getUri`)
```
payload.version = 1; payload.batchId; payload.batchIndex; payload.batchSize
for each entry:
  params.secret = secret bytes; params.name = accountName; params.issuer = issuer
  algorithm switch on getAlgorithm(false): "SHA1"→ALGORITHM_SHA1; "SHA256"→ALGORITHM_SHA256;
      "SHA512"→ALGORITHM_SHA512; "MD5"→ALGORITHM_MD5; else error.
  digits switch: 6→DIGIT_COUNT_SIX; 8→DIGIT_COUNT_EIGHT; else error "Unsupported number of digits".
  type switch on getType().toLowerCase(): "hotp"→OTP_TYPE_HOTP + setCounter(counter);
      "totp"→OTP_TYPE_TOTP; else error.
      // NOTE: SteamInfo.getType()="Steam", YandexInfo="Yandex", MotpInfo type="Motp"→ none match
      // "totp"/"hotp", so Steam/Yandex/MOTP entries CANNOT be exported to Google migration.
scheme="otpauth-migration"; authority="offline"; append data = Base64.encode(payload.toByteArray())
```

---

## 8. TEST VECTORS (verbatim — must all pass)

### 8.1 HOTP (RFC 4226) — `HOTPTest`
Secret = ASCII `"12345678901234567890"` (20 bytes: `0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,0x39,0x30` repeated twice). algo=HmacSHA1, digits=6. Counter = index:
```
counter 0 → "755224"    counter 1 → "287082"
counter 2 → "359152"    counter 3 → "969429"
counter 4 → "338314"    counter 5 → "254676"
counter 6 → "287922"    counter 7 → "162583"
counter 8 → "399871"    counter 9 → "520489"
```

### 8.2 TOTP (RFC 6238) — `TOTPTest`, digits=8, period=30
Seeds are ASCII digit strings repeated/truncated:
- SEED (SHA1) = `"12345678901234567890"` (20 bytes)
- SEED32 (SHA256) = `"12345678901234567890123456789012"` (32 bytes)
- SEED64 (SHA512) = `"1234567890"` repeated to 64 bytes = `"1234567890123456789012345678901234567890123456789012345678901234"`
```
time 59          HmacSHA1   → "94287082"
time 59          HmacSHA256 → "46119246"
time 59          HmacSHA512 → "90693936"
time 1111111109  HmacSHA1   → "07081804"
time 1111111109  HmacSHA256 → "68084774"
time 1111111109  HmacSHA512 → "25091201"
time 1111111111  HmacSHA1   → "14050471"
time 1111111111  HmacSHA256 → "67062674"
time 1111111111  HmacSHA512 → "99943326"
time 1234567890  HmacSHA1   → "89005924"
time 1234567890  HmacSHA256 → "91819424"
time 1234567890  HmacSHA512 → "93441116"
time 2000000000  HmacSHA1   → "69279037"
time 2000000000  HmacSHA256 → "90698825"
time 2000000000  HmacSHA512 → "38618901"
time 20000000000 HmacSHA1   → "65353130"
time 20000000000 HmacSHA256 → "77737706"
time 20000000000 HmacSHA512 → "47863826"
```

### 8.3 MOTP — `MOTPTest`, algo=MD5, digits=6, period=10 (secrets are hex strings, hex-decoded)
```
time 165892298        pin "1234"  secret "e3152afee62599c8" → "e7d8b6"
time 123456789        pin "1234"  secret "e3152afee62599c8" → "4ebfb2"
time 1659540020       pin "9999"  secret "bbb1912bb5c515be" → "ced7b1"   (165954002*10)
time 1659540022       pin "9999"  secret "bbb1912bb5c515be" → "ced7b1"   (165954002*10 + 2)
time 1659539870       pin "9999"  secret "bbb1912bb5c515be" → "1a14f8"   (165953987*10)
time 1659539878       pin "9999"  secret "bbb1912bb5c515be" → "1a14f8"   (165953987*10 + 8, rounds down)
```
Raw MD5 digest checks:
```
MD5("BOB")      → "355938cfe3b73a624297591972d27c01"
MD5("test1234") → "16d7a4fca7442dda3ad93c9a726597e4"
```

### 8.4 Yandex OTP — `YAOTPTest`, digits=8, algo=HmacSHA256, period=30
Secret = `YandexInfo.parseSecret(Base32.decode(secretB32))` (validate + truncate to 16 bytes):
```
pin "5239"             secret_b32 "6SB2IKNM6OBZPAVBVTOHDKS4FAAAAAAADFUTQMBTRY"  ts 1641559648 → "umozdicq"
pin "7586"             secret_b32 "LA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI"  ts 1581064020 → "oactmacq"
pin "7586"             secret_b32 "LA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI"  ts 1581090810 → "wemdwrix"
pin "5210481216086702" secret_b32 "JBGSAU4G7IEZG6OY4UAXX62JU4AAAAAAHTSG4HXU3M"  ts 1581091469 → "dfrpywob"
pin "5210481216086702" secret_b32 "JBGSAU4G7IEZG6OY4UAXX62JU4AAAAAAHTSG4HXU3M"  ts 1581093059 → "vunyprpd"
```

### 8.5 Yandex secret validation — `YandexInfoTest`
```
"LA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI"  (26 bytes, valid checksum)   → OK
"LA2V6KMCGYMWWVEW64RNP3JA3I"                  (16 bytes, QR, no checksum)  → OK
"AA2V6KMCGYMWWVEW64RNP3JA3IAAAAAAHTSG4HRZPI"  (26 bytes, first char diff)  → throws (bad checksum)
"AA2V6KMCGJA3IAAAAAAHTSG4HRZPI"               (wrong length)               → throws
```

### 8.6 URI parse examples (from importer resource fixtures — all parse successfully)
```
otpauth://totp/Deno:Mason?secret=4SJHB4GSD43FZBAI7C2HLRJGPQ&issuer=Deno&algorithm=SHA1&digits=6&period=30
otpauth://totp/SPDX:James?secret=5OM4WOOGPLQEF6UGN3CPEOOLWU&issuer=SPDX&algorithm=SHA256&digits=7&period=20
otpauth://totp/Airbnb:Elijah?secret=7ELGJSGXNCCTV3O6LKJWYFV2RA&issuer=Airbnb&algorithm=SHA512&digits=8&period=50
otpauth://hotp/Issuu:James?secret=YOOMIXWS5GN6RTBPUFFWKTW5M4&issuer=Issuu&algorithm=SHA1&digits=6&counter=1
otpauth://hotp/Air%20Canada:Benjamin?secret=KUVJJOM753IHTNDSZVCNKL7GII&issuer=Air+Canada&algorithm=SHA256&digits=7&counter=50
otpauth://hotp/WWE:Mason?secret=5VAML3X35THCEBVRLV24CGBKOY&issuer=WWE&algorithm=SHA512&digits=8&counter=10300
otpauth://steam/Boeing:Sophia?secret=JRZCL47CMXVOQMNPZR2F7J4RGI&issuer=Boeing&algorithm=SHA1&digits=5&period=30
otpauth://totp/neo4j:Charlotte?secret=B33WS2ALPT34K4BNY24AYROE4M&issuer=neo4j&algorithm=SHA1&digits=6&period=30
```
Notes visible in fixtures: `digits=7` is accepted (1–10 valid). Percent-encoded label
`Air%20Canada` decodes to `Air Canada` (issuer part of the colon label). The `issuer=Air+Canada`
query uses `+` which Android's `getQueryParameter` decodes to space. Algorithm names may appear
lowercase in some sources (`algorithm=sha512`) — `setAlgorithm` uppercases, so it is accepted.

### 8.7 Empty-secret behavior — `GoogleAuthInfoTest`
- `otpauth://totp/test:test?secret=AA&algo=SHA1&digits=6&period=30` parses OK (secret "AA"
  base32-decodes to 1 byte). Note: this test uses `algo=` (not `algorithm=`), so the algorithm
  override is NOT applied — default SHA1 used.
- Same URI with `secret=` (empty) → throws `GoogleAuthInfoException` (empty secret).
- `TotpInfo`/`HotpInfo`/`SteamInfo` built with `new byte[0]` throw `OtpInfoException` on
  `getOtp()` (via `checkSecret()`).

### 8.8 MD5 override round-trip — `HotpInfoTest.testHotpMd5Override`
- A MotpInfo(secret={1,2,3,4}, pin="1234") serialized→`fromJson("motp", …)` keeps algo "MD5".
- A HotpInfo with algorithm forced to "MD5", serialized→`fromJson("hotp", …)` comes back as
  "SHA1" (DEFAULT_ALGORITHM) — the non-MOTP MD5 workaround.
- HotpInfo with "SHA256" round-trips unchanged.


## CRITICAL FACTS (must preserve exactly)

- Base32: RFC4648 alphabet ABCDEFGHIJKLMNOPQRSTUVWXYZ234567; decode uppercases input first and MUST accept unpadded input; encode is uppercase with NO padding.
- Hex/Base16: decode uppercases input first; encode is LOWERCASE. Base64: standard RFC4648 with padding on both encode and decode.
- HOTP truncation: offset = hash[last] & 0x0f; otp = ((hash[offset]&0x7f)<<24)|((hash[offset+1]&0xff)<<16)|((hash[offset+2]&0xff)<<8)|(hash[offset+3]&0xff). Counter encoded as 8-byte BIG-ENDIAN signed long. HMAC key is raw secret bytes.
- OTP.toString: code = otp % (int)Math.pow(10,digits), left-zero-padded to digits. For digits=10 the (int) cast of 1e10 saturates to Integer.MAX_VALUE=2147483647.
- TOTP counter = floor(seconds/period); default seconds = System.currentTimeMillis()/1000.
- Supported HMAC algos: SHA1, SHA256, SHA512, MD5 (bare names). Java Mac names prefix 'Hmac' (HmacSHA1 etc). setAlgorithm strips leading 'Hmac' and uppercases.
- Digit validity: 1..10 inclusive. Period validity: >0 and <=2147483 (Integer.MAX_VALUE/1000). Counter validity: >=0.
- Defaults: DEFAULT_DIGITS=6, DEFAULT_ALGORITHM="SHA1", TotpInfo.DEFAULT_PERIOD=30, HotpInfo.DEFAULT_COUNTER=0.
- Steam: DIGITS=5, alphabet STEAM_ALPHABET="23456789BCDFGHJKMNPQRTVWXY" (len 26); for 5 iters append alphabet[code%26] then code/=26 (least-significant char first, NOT reversed). Steam host in URI is 'steam'; getType()='Steam'.
- Yandex: DEFAULT_ALGORITHM=SHA256, DIGITS=8, period=30, SECRET_LENGTH=16, SECRET_FULL_LENGTH=26, ID='yandex', HOST_ID='yaotp'. keyHash=SHA-256(pinBytes ++ secret); if keyHash[0]==0x00 drop first byte; periodHash=HMAC(keyHash,HmacSHA256,counter); offset=periodHash[last]&0xf; periodHash[offset]&=0x7f; otp=int64 big-endian read at offset; output = 8 lowercase letters via code%26 with 'a'+... filled from index digits-1 down to 0. Yandex checksum XOR constant = 0x18F3 (0b1100011110011), uses 13-bit accumulator.
- Yandex parseSecret: validateSecret then if length!=16 truncate to first 16 bytes. Length must be 16 or 26; length 16 (QR) skips checksum.
- MOTP: ID/SCHEME='motp', ALGORITHM='MD5', PERIOD=10, DIGITS=6. toDigest = decimal(time/period) + lowercaseHex(secret) + pin, all UTF-8; code = lowercaseHex(MD5(toDigest)); output = first 6 chars. Uses raw digest name 'MD5' (getAlgorithm(false)).
- otpauth URI: scheme must be 'otpauth' or 'motp'. secret param required; motp scheme uses Hex.decode, others use parseSecret (base32, trim + remove '-' and ' '). type = 'motp' for motp scheme else uri host. hotp requires 'counter' param. Recognized override params are 'algorithm' and 'digits' (NOT 'algo').
- URI label/issuer precedence: label=path minus leading '/'. If label contains ':' and split(':').length==2 -> issuer=part0, account=part1 (overrides Yandex-preset issuer). Else account=whole label. If no colon and current issuer empty -> issuer = 'issuer' query param or ''. Yandex presets issuer to 'Yandex' from getType().
- Yandex URI pin param is base32-decoded then read as UTF-8 string on parse; serialized as Base32.encode(pin UTF-8) on output.
- URI serialize: motp scheme emits only secret(hex lowercase)+issuer. otpauth emits authority (steam/yaotp/totp/hotp), then period-or-counter, digits, algorithm(bare), secret(base32 uppercase unpadded), pin(yandex only), then path 'issuer:account' + issuer param when issuer non-empty else path=account.
- Google migration protobuf (proto3): MigrationPayload{ repeated OtpParameters otp_parameters=1; int32 version=2; int32 batch_size=3; optional int32 batch_index=4; int32 batch_id=5 }. OtpParameters{ bytes secret=1; string name=2; string issuer=3; Algorithm algorithm=4; DigitCount digits=5; OtpType type=6; int64 counter=7 }.
- Migration enums: Algorithm{UNSPECIFIED=0,SHA1=1,SHA256=2,SHA512=3,MD5=4}; DigitCount{UNSPECIFIED=0,SIX=1,EIGHT=2}; OtpType{UNSPECIFIED=0,HOTP=1,TOTP=2}.
- Migration parse: DIGIT_COUNT SIX/UNSPECIFIED->6, EIGHT->8; ALGORITHM SHA1/UNSPECIFIED->SHA1 (MD5 rejected on import); OTP_TYPE TOTP/UNSPECIFIED->TotpInfo period=30, HOTP->HotpInfo with counter. name/issuer split on first ':' only if issuer empty. scheme must be 'otpauth-migration', host 'offline', data param base64 -> protobuf. Serialize sets version=1.
- Migration serialize only supports TOTP and HOTP (getType().toLowerCase() must be 'totp' or 'hotp'); Steam/Yandex/MOTP throw. Digits must be 6 or 8; algorithm SHA1/SHA256/SHA512/MD5.
- Vault JSON keys: secret(base32 uppercase unpadded), algo(bare name), digits; +period(totp/steam/yandex/motp), +counter(hotp), +pin(yandex/motp). fromJson: if type!='motp' and algo=='MD5' then algo becomes 'SHA1' (DEFAULT_ALGORITHM). yandex/motp fromJson ignore stored algo/digits and use their fixed values.
- HOTP RFC4226 vectors (secret=ASCII '12345678901234567890', SHA1, 6 digits): counters 0-9 -> 755224,287082,359152,969429,338314,254676,287922,162583,399871,520489.
- MOTP getDigest checks: MD5('BOB')=355938cfe3b73a624297591972d27c01, MD5('test1234')=16d7a4fca7442dda3ad93c9a726597e4.

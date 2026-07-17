# AegisMac

A native Swift/SwiftUI port of [Aegis Authenticator](https://github.com/beemdevelopment/Aegis) for macOS. Vault files are byte-compatible with the Android app: the same `aegis.json` can be moved freely between devices.

> **Disclaimer**: This is an unofficial port. It is not associated with, or endorsed by, Beem Development, the creators of Aegis Authenticator.

## Features

- **OTP algorithms**: TOTP (RFC 6238), HOTP (RFC 4226), Steam, MOTP, Yandex — SHA1/SHA256/SHA512, 6–10 digits
- **Vault compatibility**: reads and writes the Android Aegis vault format (envelope v1, db v3), encrypted (scrypt + AES-256-GCM) or plaintext
- **Touch ID** unlock (password stored in the login keychain behind biometric access control)
- **Import**: `otpauth://` URIs, Google Authenticator migration QR codes (`otpauth-migration://`), Aegis JSON exports; QR detection from image files or directly off the screen
- **Export**: encrypted or plaintext Aegis JSON, `otpauth://` URI list
- **UI faithful to the original**: Aegis Material palette, Light/Dark/AMOLED themes, favorites, groups, search, four view modes — adapted to macOS conventions (toolbar search, context menus, ⌘ shortcuts, Settings scene)

## Requirements

macOS 14 (Sonoma) or later.

## Build

```sh
swift build -c release        # binary only
swift test                    # 140 unit tests (RFC vectors, vault round-trips, importers)
./scripts/package.sh          # builds dist/AegisMac-<version>.dmg (ad-hoc signed)
```

The packaged app is ad-hoc signed: it runs on the building machine as-is; on other Macs, right-click → Open on first launch (proper distribution would require a Developer ID certificate and notarization).

## Vault location

```
~/Library/Application Support/AegisMac/aegis.json
```

Back this file up. It is a standard Aegis vault — the Android app (and anything else that speaks the format) can import it directly.

## Tracking upstream

This port is based on a specific upstream commit recorded in [UPSTREAM.md](UPSTREAM.md). Run `scripts/upstream-diff.sh` to see what changed upstream since then, or use the `/sync-upstream` Claude Code skill to port relevant changes. Architecture contracts live in [DESIGN.md](DESIGN.md); the behavior specs extracted from the Java source live in `docs/porting-specs/`.

## License

[GPL-3.0](LICENSE). This project is a derivative work of [Aegis Authenticator](https://github.com/beemdevelopment/Aegis), © Beem Development and contributors, licensed under GPL-3.0.

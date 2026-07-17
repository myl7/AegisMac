# Upstream tracking

upstream: https://github.com/beemdevelopment/Aegis
base-commit: a9d45b3ade1eda43ea796c7d7546e0147275ba7c
base-note: upstream master after v3.4.2 + PR #1812 (encrypted Proton Authenticator import); port baseline as of 2026-07-17

The `base-commit:` line above is machine-read by `scripts/upstream-diff.sh` — keep the format.

## How to sync

1. Make sure a clone of upstream Aegis exists (default `~/app/Aegis`; override with `AEGIS_FORK=/path`). A blob-less partial clone works: `git clone --filter=blob:none https://github.com/beemdevelopment/Aegis.git`
2. Run `scripts/upstream-diff.sh` — it fetches upstream master and lists commits/diffs touching port-relevant paths since the base commit.
3. Port the relevant changes (or run the `/sync-upstream` Claude Code skill, which automates steps 2–5).
4. Run `swift build && swift test`.
5. Update `base-commit:` above to the newly synced upstream SHA.

## Port-relevant upstream paths

| Path (under `app/src/main/java/com/beemdevelopment/aegis/`) | Maps to |
|---|---|
| `crypto/` | `Sources/AegisMac/Crypto/` |
| `otp/` | `Sources/AegisMac/Otp/` |
| `vault/` (incl. db version bumps and slot changes) | `Sources/AegisMac/Vault/` |
| `encoding/` | `Sources/AegisMac/Encoding/` |
| `importers/` | `Sources/AegisMac/Import/` |
| `app/src/test/` | `Tests/AegisMacTests/` (port new test vectors) |

Generally Android-only (skip): `ui/`, `res/` (except new entry-field semantics), Gradle files, translations (`values-*/strings.xml`), AndroidManifest, icon packs, accessibility services.

**Critical**: if upstream bumps the vault db version, port the migration logic before anything else — vault byte-compatibility is the core invariant of this project.

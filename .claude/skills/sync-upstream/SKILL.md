---
name: sync-upstream
description: Check upstream Aegis (Android) for changes since the recorded base commit, identify port-relevant ones, and port them to this Swift codebase with tests.
---

# Sync with upstream Aegis

Port new upstream changes from the Android app (beemdevelopment/Aegis) into this Swift codebase.

## Steps

1. **Diff against upstream**: run `scripts/upstream-diff.sh`. The upstream clone defaults to `~/app/Aegis` (override with `AEGIS_FORK`); if missing, clone it with `git clone --filter=blob:none https://github.com/beemdevelopment/Aegis.git ~/app/Aegis`. If the script reports "Already up to date", stop and tell the user.

2. **Classify each upstream commit**:
   - **Port-relevant**: anything under `crypto/`, `otp/`, `vault/`, `encoding/`, `importers/` (Java package `com.beemdevelopment.aegis.*`); vault db version bumps; new entry fields; new OTP types; new importers; changed test vectors in `app/src/test/`.
   - **Android-only (skip)**: `ui/`, `res/`, Gradle/build files, translations (`values-*/strings.xml`), AndroidManifest, icon packs, Android accessibility. But do note user-visible features worth reimplementing natively and list them for the user at the end.

3. **Port each relevant change**:
   - Read the Java diff in the upstream clone (`git -C <fork> diff <base> <new> -- <path>`).
   - Find the Swift counterpart via the module-ownership table in `DESIGN.md` and the path map in `UPSTREAM.md`.
   - Update the affected spec in `docs/porting-specs/*.md` first (these are the authoritative behavior contracts), then implement in Swift.
   - Port any new upstream test vectors into `Tests/AegisMacTests/`.

4. **Respect the codebase invariants** (from DESIGN.md):
   - Vault files must stay byte-compatible with Android. If upstream bumps the vault db version, port the migration logic first, including reading older versions.
   - JSONSerialization with `[String: Any]` — no Codable for vault (de)serialization.
   - All errors are `AegisError`; no new dependencies without discussion; no Package.swift churn.

5. **Verify**: `swift build && swift test` — all tests must pass. If a ported change has upstream test vectors, they must be among the ported tests.

6. **Record the sync**: update the `base-commit:` line in `UPSTREAM.md` to the new upstream SHA (printed by the script). Summarize what was ported vs. skipped.

7. **Commit** on a branch with a message listing the upstream commits ported. Do not push unless asked.

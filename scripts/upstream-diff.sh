#!/bin/sh
# Show upstream Aegis (Android) changes relevant to this port since the
# base commit recorded in UPSTREAM.md. Read-only: fetches upstream master
# into the local Aegis clone and prints logs/diffstats, changes nothing here.
#
# Usage: scripts/upstream-diff.sh
#   AEGIS_FORK=/path/to/Aegis   override the upstream clone location
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FORK="${AEGIS_FORK:-$HOME/app/Aegis}"

BASE=$(sed -n 's/^base-commit: //p' "$ROOT/UPSTREAM.md")
if [ -z "$BASE" ]; then
    echo "error: no 'base-commit:' line found in UPSTREAM.md" >&2
    exit 1
fi
if [ ! -d "$FORK/.git" ]; then
    echo "error: Aegis clone not found at $FORK" >&2
    echo "  git clone --filter=blob:none https://github.com/beemdevelopment/Aegis.git $FORK" >&2
    echo "  (or set AEGIS_FORK to an existing clone)" >&2
    exit 1
fi

echo "Fetching upstream master into $FORK ..."
git -C "$FORK" fetch --quiet origin master
NEW=$(git -C "$FORK" rev-parse FETCH_HEAD)

echo "base:   $BASE"
echo "latest: $NEW"
if [ "$BASE" = "$NEW" ] || [ "$(git -C "$FORK" rev-list --count "$BASE..$NEW")" = "0" ]; then
    echo "Already up to date with upstream."
    exit 0
fi

J=app/src/main/java/com/beemdevelopment/aegis
RELEVANT="$J/crypto $J/otp $J/vault $J/encoding $J/importers app/src/test"

echo
echo "== Releases since base =="
git -C "$FORK" log --oneline --decorate "$BASE..$NEW" | grep 'tag:' || echo "(no release tags yet)"

echo
echo "== Commits touching port-relevant paths =="
git -C "$FORK" log --oneline "$BASE..$NEW" -- $RELEVANT || true
if [ -z "$(git -C "$FORK" log --oneline "$BASE..$NEW" -- $RELEVANT)" ]; then
    echo "(none — upstream changes appear to be Android-only)"
fi

echo
echo "== Diffstat of relevant paths =="
git -C "$FORK" diff --stat "$BASE" "$NEW" -- $RELEVANT || true

echo
echo "Total upstream commits since base: $(git -C "$FORK" rev-list --count "$BASE..$NEW")"
echo
echo "Inspect a change:  git -C $FORK diff $BASE $NEW -- <path>"
echo "After porting, update 'base-commit:' in UPSTREAM.md to $NEW"

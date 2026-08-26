#!/usr/bin/env bash
#
# package.sh — build an installable HoDLootAdvisor zip.
#
#   ./package.sh              → dist/HoDLootAdvisor-<date>.zip
#   ./package.sh 2026.08.26b  → stamp a specific version
#
# WHY THIS EXISTS SEPARATELY FROM CI. The addon has no GitHub repo yet, so
# there is no packager and no WoWUp: today the only installation is a symlink
# into one AddOns folder, which means nobody else can run it. Comms, ad-hoc
# raiders and the whole multi-installer design are untestable until a second
# person can install it, and this is the shortest path to that — a zip they
# drop into Interface/AddOns.
#
# ⚠️ THE VERSION IS STAMPED, NOT LEFT AS THE TOKEN. The .toc carries
# "@project-version@" for the BigWigs packager to substitute; unsubstituted,
# ns.Version() honestly reports "dev". That is right for a symlink and WRONG
# here: two clients both reporting "dev" cannot be told apart, and the version
# each peer announces over HELLO is part of what a two-client test is checking.
#
# ⚠️ AND test/ IS EXCLUDED, WHICH IS NOT A TIDINESS CONCERN. test/fixtures.lua
# alone is 140 MB of parity cases. Shipping the test directory would produce a
# zip nobody could download and a load-time cost nobody should pay.

set -euo pipefail

cd "$(dirname "$0")"

ADDON="HoDLootAdvisor"
VERSION="${1:-$(date -u +%Y.%m.%d)}"
OUT="dist"
STAGE="$OUT/$ADDON"

# Every file the .toc actually loads, plus what it needs at runtime. Derived
# from the .toc rather than listed by hand, so a file added there cannot be
# forgotten here — that mistake ships an addon that errors on someone else's
# machine and works perfectly on the developer's.
# Read with a while-loop rather than mapfile: macOS ships bash 3.2, where
# mapfile does not exist, and this script has to run on the machine that builds
# the zip.
TOC_FILES=()
while IFS= read -r line; do
  TOC_FILES+=("$line")
done < <(grep -E '^[A-Za-z0-9_]+\.lua[[:space:]]*$' "$ADDON.toc" | tr -d '\r')

if [ ${#TOC_FILES[@]} -eq 0 ]; then
  echo "error: no Lua files found in $ADDON.toc" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$STAGE"

missing=0
for f in "${TOC_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "error: $ADDON.toc loads '$f' but it does not exist" >&2
    missing=1
    continue
  fi
  cp "$f" "$STAGE/"
done
[ "$missing" -eq 0 ] || exit 1

# Media travels whole: fonts, their licences, and the icons. FONT LICENCES ARE
# A REQUIREMENT, NOT HOUSEKEEPING — the SIL licence must travel with the font
# software, and General Sans's terms require ITF to be credited by name.
if [ -d Media ]; then
  cp -R Media "$STAGE/"
fi

# The .toc, with the version substituted.
sed "s/@project-version@/$VERSION/" "$ADDON.toc" > "$STAGE/$ADDON.toc"

if grep -q "@project-version@" "$STAGE/$ADDON.toc"; then
  echo "error: version token was not substituted" >&2
  exit 1
fi

# Sanity: the payload has to be the real generated one, not a stub or an empty
# file left behind by a failed emit. Same reasoning as the CI guard — a payload
# that is present but hollow scores every item against nothing, silently.
DATA="$STAGE/LootData.lua"
if [ -f "$DATA" ]; then
  bytes=$(wc -c < "$DATA")
  if [ "$bytes" -lt 15000 ]; then
    echo "error: LootData.lua is only $bytes bytes — regenerate it from /api/loot-advisor/emit" >&2
    exit 1
  fi
  head -n1 "$DATA" | grep -q "GENERATED" || {
    echo "error: LootData.lua is missing its GENERATED header" >&2
    exit 1
  }
fi

ZIP="$OUT/$ADDON-$VERSION.zip"
( cd "$OUT" && zip -qr "$ADDON-$VERSION.zip" "$ADDON" )

echo "built $ZIP"
echo "  version   $VERSION"
echo "  files     ${#TOC_FILES[@]} Lua + Media"
echo "  size      $(du -h "$ZIP" | cut -f1)"
echo
echo "To install: unzip into  <WoW>/_retail_/Interface/AddOns/"
echo "It must end up as       Interface/AddOns/$ADDON/$ADDON.toc"

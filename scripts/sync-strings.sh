#!/usr/bin/env bash
set -euo pipefail

# Extracts the localizable strings of the app and every package module into Keystrand/Localizable.xcstrings.
# Usage: scripts/sync-strings.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
readonly ROOT
readonly CATALOG="Keystrand/Localizable.xcstrings"
readonly DERIVED_DATA=".build/strings"

usage() {
  cat <<'USAGE'
Usage: scripts/sync-strings.sh

Builds the Debug app with the compiler's string extraction turned on for every
target (the app and all KeystrandKit modules), then merges the extracted strings
into Keystrand/Localizable.xcstrings with xcstringstool sync, the same merge
Xcode runs. New strings are added, strings no longer in the source are removed,
or marked stale when they have translations. Running it again without source
changes leaves the catalog byte-for-byte the same.

The build uses its own derived data in .build/strings, so it does not
invalidate the regular .build/dd build.

  -h, --help   show this help
USAGE
}

die() {
  printf 'sync-strings.sh: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

step() {
  printf '==> %s\n' "$*"
}

case "${1:-}" in
  "") ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

require_cmd xcodegen
require_cmd xcodebuild
require_cmd jq
cd "$ROOT"
[[ -f "$CATALOG" ]] || die "$CATALOG does not exist."

step "Generating the Xcode project"
xcodegen generate --quiet

step "Building with string extraction"
xcodebuild -project Keystrand.xcodeproj -scheme Keystrand -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED_DATA" -quiet build \
  SWIFT_EMIT_LOC_STRINGS=YES CODE_SIGNING_ALLOWED=NO

# Keeps only files for sources that still exist, which drops leftovers of deleted or moved files
# and files for generated sources.
stringsdata=()
while IFS= read -r file; do
  src="$(jq -r '.source // empty' "$file")"
  if [[ ("$src" == "$ROOT"/Sources/* || "$src" == "$ROOT"/Keystrand/*) && -f "$src" ]]; then
    stringsdata+=("$file")
  fi
done < <(find "$DERIVED_DATA/Build/Intermediates.noindex" -name '*.stringsdata' | LC_ALL=C sort)
((${#stringsdata[@]} > 0)) || die "the build produced no .stringsdata files."

step "Syncing $CATALOG from ${#stringsdata[@]} source files"
xcrun xcstringstool sync "$CATALOG" --stringsdata "${stringsdata[@]}"
printf '%s strings in %s\n' "$(jq '.strings | length' "$CATALOG")" "$CATALOG"

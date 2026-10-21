#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and installs the Release app.
# Usage: scripts/install.sh [--skip-build] [--open]

APP_NAME="Keystrand"
SCHEME="Keystrand"
DERIVED_DATA=".build/dd"
DEFAULT_SIGN_IDENTITY="Keystrand Local"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh [--skip-build] [--open]

Builds the Release app, copies it to dist/Keystrand.app, signs it with the hardened
runtime, and installs it into the Applications folder. A running copy of the app is
asked to quit first. The version comes from scripts/version.sh.

  --skip-build   sign and install the existing dist/Keystrand.app without rebuilding
  --open         launch the installed app when done
  -h, --help     show this help

Environment:
  SIGN_IDENTITY  codesign identity; default "Keystrand Local" when that certificate
                 is in the keychain, otherwise "-" (ad-hoc). Without the certificate,
                 an interactive run offers to create it (scripts/make-signing-cert.sh).
  INSTALL_DIR    destination folder; default /Applications
USAGE
}

die() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

step() {
  printf '\n==> %s\n' "$*"
}

build_release() {
  step "Generating the Xcode project"
  xcodegen generate

  local version build
  version=$(scripts/version.sh)
  build=$(scripts/version.sh --build)

  step "Building $SCHEME $version ($build), Release"
  xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" -quiet build \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build"

  local product="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
  [[ -d "$product" ]] || die "build finished but $product does not exist."

  step "Refreshing dist/$APP_NAME.app"
  mkdir -p dist
  if [[ -e "dist/$APP_NAME.app" ]]; then
    trash "dist/$APP_NAME.app"
  fi
  ditto "$product" "dist/$APP_NAME.app"
}

# The bundled command specs are RSALv2 material, whose terms must ship with every copy of the app.
check_license_resources() {
  local resources="$1/Contents/Resources" missing=()
  local file
  for file in LICENSE THIRD_PARTY_NOTICES.md LICENSES/RSALv2.txt Credits.rtf; do
    [[ -f "$resources/$file" ]] || missing+=("$file")
  done
  if (( ${#missing[@]} > 0 )); then
    die "the built app is missing license resources in $resources: ${missing[*]}. Check the resource entries in project.yml."
  fi
}

identity_available() {
  [[ "$1" == "-" ]] && return 0
  security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$1\""
}

resolve_sign_identity() {
  if [[ -n "$SIGN_IDENTITY" ]]; then
    identity_available "$SIGN_IDENTITY" ||
      die "no valid code-signing identity named '$SIGN_IDENTITY' (see: security find-identity -v -p codesigning)."
  elif identity_available "$DEFAULT_SIGN_IDENTITY"; then
    SIGN_IDENTITY="$DEFAULT_SIGN_IDENTITY"
  elif offer_signing_certificate && identity_available "$DEFAULT_SIGN_IDENTITY"; then
    SIGN_IDENTITY="$DEFAULT_SIGN_IDENTITY"
  else
    printf 'install.sh: certificate "%s" is not in the keychain; signing ad-hoc instead. Run scripts/make-signing-cert.sh to create it.\n' \
      "$DEFAULT_SIGN_IDENTITY" >&2
    SIGN_IDENTITY="-"
  fi
}

offer_signing_certificate() {
  [[ -t 0 ]] || return 1
  printf 'The code-signing certificate "%s" is not in your login keychain.\n' "$DEFAULT_SIGN_IDENTITY"
  printf "With it, macOS remembers Keystrand's keychain access across rebuilds.\n"
  local answer
  read -r -p "Create it now with scripts/make-signing-cert.sh? [y/N] " answer
  [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || return 1
  scripts/make-signing-cert.sh
}

sign_app() {
  local app="$1"
  step "Signing $app with identity '$SIGN_IDENTITY'"
  codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$app"
  codesign --verify --deep --strict "$app"
  codesign --display --verbose=2 "$app" 2>&1 | grep -E '^(Identifier|Signature|Authority)=' || true
}

quit_running_app() {
  pgrep -xq "$APP_NAME" || return 0
  step "Quitting the running $APP_NAME"
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
  local waited=0
  while pgrep -xq "$APP_NAME"; do
    if (( waited >= 20 )); then
      die "$APP_NAME is still running. Quit it and run this script again."
    fi
    sleep 0.5
    waited=$(( waited + 1 ))
  done
}

install_app() {
  local source="$1" target="$INSTALL_DIR/$APP_NAME.app"
  [[ -d "$INSTALL_DIR" ]] || die "$INSTALL_DIR does not exist."
  [[ -w "$INSTALL_DIR" ]] || die "$INSTALL_DIR is not writable."

  step "Installing to $target"
  if [[ -e "$target" ]]; then
    trash "$target"
  fi
  ditto "$source" "$target"

  local version build
  version=$(defaults read "$target/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
  build=$(defaults read "$target/Contents/Info" CFBundleVersion 2>/dev/null || echo "?")
  printf 'Installed %s %s (%s) to %s\n' "$APP_NAME" "$version" "$build" "$target"
}

main() {
  local skip_build=false open_after=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-build) skip_build=true ;;
      --open) open_after=true ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument '$1'." ;;
    esac
    shift
  done

  for cmd in xcodegen xcodebuild codesign security ditto trash git; do
    require_cmd "$cmd"
  done

  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  cd "$root"
  resolve_sign_identity

  if [[ "$skip_build" == true ]]; then
    [[ -d "dist/$APP_NAME.app" ]] || die "dist/$APP_NAME.app does not exist; run without --skip-build."
  else
    build_release
  fi

  check_license_resources "dist/$APP_NAME.app"
  sign_app "dist/$APP_NAME.app"
  quit_running_app
  install_app "dist/$APP_NAME.app"

  if [[ "$open_after" == true ]]; then
    open "$INSTALL_DIR/$APP_NAME.app"
  fi
}

main "$@"

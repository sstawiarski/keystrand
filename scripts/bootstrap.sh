#!/usr/bin/env bash
set -euo pipefail

# Description: Checks Xcode and installs the developer tools in the Brewfile.
# Usage: scripts/bootstrap.sh [--check]

readonly BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
readonly BREW_INSTALL="/bin/bash -c \"\$(curl -fsSL $BREW_INSTALL_URL)\""
readonly MIN_XCODE_MAJOR=26

# Brewfile formula and the command it provides, looked up in the formula's
# opt directory: Valkey's redis-server shim on PATH is not Redis.
readonly FORMULAE=(
  "xcodegen:xcodegen"
  "swiftformat:swiftformat"
  "ast-grep:ast-grep"
  "markdownlint-cli:markdownlint"
  "shellcheck:shellcheck"
  "ruff:ruff"
  "redis:redis-server"
  "valkey:valkey-server"
)

ROWS=()
FAILED=false

usage() {
  cat <<'USAGE'
Usage: scripts/bootstrap.sh [--check]

Checks that Xcode is selected and at least the version in .xcode-version,
installs the tools in the Brewfile with Homebrew, points git at the hooks in
.githooks, and prints a status table. Exits non-zero when a required tool is
still missing.

  --check      report only; install nothing and leave the git config alone
  -h, --help   show this help

Environment:
  HOMEBREW_BUNDLE_BREW_SKIP  space-separated formulae to skip, for example
                             "redis valkey" on a build-only machine
USAGE
}

die() {
  printf 'bootstrap.sh: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n==> %s\n' "$*"
}

# Records one status-table row. A status other than ok, warn or skipped fails
# the run.
record() {
  local name="$1" status="$2" detail="$3"
  ROWS+=("$name"$'\t'"$status"$'\t'"$detail")
  if [[ "$status" != "ok" && "$status" != "warn" && "$status" != "skipped" ]]; then
    FAILED=true
  fi
}

print_table() {
  step "Status"
  local row name status detail
  printf '%-14s %-8s %s\n' "TOOL" "STATUS" "DETAIL"
  for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r name status detail <<<"$row"
    printf '%-14s %-8s %s\n' "$name" "$status" "$detail"
  done
}

# Prints "major minor" for a version such as 27.1 or 26.
split_version() {
  local major minor
  IFS=. read -r major minor _ <<<"$1."
  printf '%d %d\n' "${major:-0}" "${minor:-0}"
}

version_less_than() {
  local a_major a_minor b_major b_minor
  read -r a_major a_minor < <(split_version "$1")
  read -r b_major b_minor < <(split_version "$2")
  (( a_major < b_major || (a_major == b_major && a_minor < b_minor) ))
}

check_xcode() {
  local developer_dir
  if ! developer_dir=$(xcode-select -p 2>/dev/null); then
    record "Xcode" "missing" "install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app"
    return
  fi
  if [[ "$developer_dir" != *.app/Contents/Developer ]]; then
    record "Xcode" "missing" "xcode-select points at $developer_dir; run: sudo xcode-select -s /Applications/Xcode.app"
    return
  fi

  local installed pinned
  installed=$(xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2 }') || true
  if [[ -z "$installed" ]]; then
    record "Xcode" "error" "xcodebuild -version failed; open Xcode once to accept the license"
    return
  fi
  pinned=$(tr -d '[:space:]' <.xcode-version 2>/dev/null) || pinned=""
  if [[ -z "$pinned" ]]; then
    record "Xcode" "warn" "$installed; .xcode-version is missing or empty"
  elif version_less_than "$installed" "$MIN_XCODE_MAJOR"; then
    record "Xcode" "old" "$installed is older than $MIN_XCODE_MAJOR; install Xcode $pinned"
  elif version_less_than "$installed" "$pinned"; then
    record "Xcode" "warn" "$installed is older than $pinned in .xcode-version; the build may still work"
  else
    record "Xcode" "ok" "$installed ($developer_dir)"
  fi
}

skipped() {
  local formula="$1" name
  for name in ${HOMEBREW_BUNDLE_BREW_SKIP:-}; do
    [[ "$name" == "$formula" ]] && return 0
  done
  return 1
}

install_bundle() {
  if HOMEBREW_NO_AUTO_UPDATE=1 brew bundle check --file Brewfile --no-upgrade >/dev/null 2>&1; then
    printf 'Every Brewfile dependency is installed.\n'
  else
    step "Installing the Brewfile"
    brew bundle install --file Brewfile --no-upgrade ||
      printf 'bootstrap.sh: brew bundle install failed; see the table below.\n' >&2
  fi
}

check_tools() {
  local prefix="" entry formula cmd path
  if command -v brew >/dev/null 2>&1; then
    prefix=$(brew --prefix)
  fi
  for entry in "${FORMULAE[@]}"; do
    formula="${entry%%:*}"
    cmd="${entry#*:}"
    path="$prefix/opt/$formula/bin/$cmd"
    if skipped "$formula"; then
      record "$cmd" "skipped" "listed in HOMEBREW_BUNDLE_BREW_SKIP"
    elif [[ -n "$prefix" && -x "$path" ]]; then
      record "$cmd" "ok" "$path"
    else
      record "$cmd" "missing" "brew install $formula"
    fi
  done

  if path=$(command -v jq); then
    record "jq" "ok" "$path"
  else
    record "jq" "missing" "brew install jq"
  fi
}

configure_git_hooks() {
  local check_only="$1"
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    record "git hooks" "skipped" "not a git checkout"
    return
  fi
  if [[ ! -d .githooks ]]; then
    record "git hooks" "skipped" "no .githooks directory"
    return
  fi

  if [[ "$(git config --get core.hooksPath || true)" == ".githooks" ]]; then
    record "git hooks" "ok" "core.hooksPath is .githooks"
  elif [[ "$check_only" == true ]]; then
    record "git hooks" "warn" "run scripts/bootstrap.sh, or: git config core.hooksPath .githooks"
  else
    git config core.hooksPath .githooks
    record "git hooks" "ok" "set core.hooksPath to .githooks"
  fi
}

main() {
  local check_only=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) check_only=true ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument '$1'." ;;
    esac
    shift
  done

  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  cd "$root"

  check_xcode

  if command -v brew >/dev/null 2>&1; then
    record "Homebrew" "ok" "$(command -v brew)"
    if [[ "$check_only" == false ]]; then
      install_bundle
    fi
  else
    record "Homebrew" "missing" "install it: $BREW_INSTALL"
  fi

  check_tools
  configure_git_hooks "$check_only"
  print_table

  if [[ "$FAILED" == true ]]; then
    if [[ "$check_only" == true ]]; then
      die "something required is missing. Run scripts/bootstrap.sh to install it."
    fi
    die "something required is still missing. Fix the rows above and run again."
  fi
}

main "$@"

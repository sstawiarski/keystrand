#!/usr/bin/env bash
set -euo pipefail

# Description: Prints the app version derived from the nearest v* git tag.
# Usage: scripts/version.sh [--build]

usage() {
  cat <<'USAGE'
Usage: scripts/version.sh [--build]

Prints the marketing version (CFBundleShortVersionString):

  on tag v0.1.0              0.1.0
  3 commits after v0.1.0     0.1.0-dev.3
  no v* tag, or no commits   0.0.0-dev

  --build      print the build number (CFBundleVersion) instead: the commit
               count of HEAD, 0 when there are no commits
  -h, --help   show this help

A shallow clone has too few commits and may lack the tag, so CI checks out
with full history (actions/checkout fetch-depth: 0).
USAGE
}

die() {
  printf 'version.sh: %s\n' "$*" >&2
  exit 1
}

warn_if_shallow() {
  if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    printf 'version.sh: shallow clone; the version may be wrong (fetch with full history).\n' >&2
  fi
}

has_commits() {
  git rev-parse --verify --quiet HEAD >/dev/null 2>&1
}

build_number() {
  if has_commits; then
    git rev-list --count HEAD
  else
    printf '0\n'
  fi
}

marketing_version() {
  local tag count
  if ! has_commits || ! tag=$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null); then
    printf '0.0.0-dev\n'
    return
  fi
  count=$(git rev-list --count "$tag..HEAD")
  if (( count == 0 )); then
    printf '%s\n' "${tag#v}"
  else
    printf '%s-dev.%s\n' "${tag#v}" "$count"
  fi
}

main() {
  local mode=marketing
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build) mode=build ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument '$1'." ;;
    esac
    shift
  done

  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository."
  warn_if_shallow

  if [[ "$mode" == build ]]; then
    build_number
  else
    marketing_version
  fi
}

main "$@"

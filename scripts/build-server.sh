#!/usr/bin/env bash
set -euo pipefail

# Description: Builds redis-server/redis-cli or valkey-server/valkey-cli from a release tag's
#   GitHub source tarball, for the nightly compatibility matrix and local checks against older servers.
# Usage: scripts/build-server.sh <redis|valkey> <version> [--prefix DIR] [--sha256 HASH]

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/build-server.sh <redis|valkey> <version> [--prefix DIR] [--sha256 HASH]

Downloads the GitHub source tarball of a Redis or Valkey release tag, builds
the core server (no modules, libc malloc), and installs the server and CLI
binaries into <prefix>/<name>-<version>/bin. Does nothing when those binaries
already report <version>.

Prints the environment for scripts/test-servers.sh native on stdout, one
KEY=value line each, for example:

  KEYSTRAND_REDIS_SERVER=<prefix>/redis-7.2.16/bin/redis-server
  KEYSTRAND_REDIS_CLI=<prefix>/redis-7.2.16/bin/redis-cli

Progress and the tarball's SHA-256 go to stderr.

  <version>       release tag, such as 7.2.16 or 8.1.10
  --prefix DIR    install root; default .build/servers in the repository.
                  Downloads and build trees stay in DIR/src.
  --sha256 HASH   fail unless the tarball has this SHA-256
  -h, --help      show this help
USAGE
  exit 1
}

die() {
  printf 'build-server.sh: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

log() {
  printf '==> %s\n' "$*" >&2
}

print_env() {
  local upper="$1" bin="$2" name="$3"
  printf 'KEYSTRAND_%s_SERVER=%s\n' "$upper" "$bin/$name-server"
  printf 'KEYSTRAND_%s_CLI=%s\n' "$upper" "$bin/$name-cli"
}

is_installed() {
  local bin="$1" name="$2" version="$3"
  [[ -x "$bin/$name-server" && -x "$bin/$name-cli" ]] \
    && "$bin/$name-server" --version 2>/dev/null | grep -qF "v=$version "
}

main() {
  local name="" version="" prefix="" expected_sha=""
  while (($# > 0)); do
    case "$1" in
      -h | --help) usage ;;
      --prefix)
        (($# >= 2)) || usage
        prefix="$2"
        shift 2
        ;;
      --sha256)
        (($# >= 2)) || usage
        expected_sha="$2"
        shift 2
        ;;
      -*) usage ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
        elif [[ -z "$version" ]]; then
          version="$1"
        else
          usage
        fi
        shift
        ;;
    esac
  done

  local repo upper
  case "$name" in
    redis) repo="redis/redis" upper="REDIS" ;;
    valkey) repo="valkey-io/valkey" upper="VALKEY" ;;
    *) usage ;;
  esac
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 7.2.16, got '$version'."

  if [[ -z "$prefix" ]]; then
    prefix="$(cd "$(dirname "$0")/.." && pwd -P)/.build/servers"
  fi
  mkdir -p "$prefix/src"
  prefix="$(cd "$prefix" && pwd -P)"
  local bin="$prefix/$name-$version/bin"

  if is_installed "$bin" "$name" "$version"; then
    log "$name $version is already installed in $bin"
    print_env "$upper" "$bin" "$name"
    return 0
  fi

  require_cmd curl
  require_cmd make
  require_cmd shasum

  local tarball="$prefix/src/$name-$version.tar.gz"
  local url="https://github.com/$repo/archive/refs/tags/$version.tar.gz"
  log "Downloading $url"
  curl -fsSL --retry 3 -o "$tarball" "$url"

  local sha
  sha="$(shasum -a 256 "$tarball" | cut -d ' ' -f 1)"
  if [[ -n "$expected_sha" ]]; then
    [[ "$sha" == "$expected_sha" ]] || die "SHA-256 mismatch for $tarball: expected $expected_sha, got $sha."
    log "SHA-256 verified: $sha"
  else
    log "SHA-256 (pin it with --sha256): $sha"
  fi

  local work
  work="$(mktemp -d "$prefix/src/$name-$version.XXXXXX")"
  tar -xzf "$tarball" -C "$work"
  local source="$work/$name-$version"
  [[ -f "$source/Makefile" ]] || die "$tarball did not unpack to $name-$version/."

  local start=$SECONDS
  log "Building $name $version in $source"
  # The ceiling keeps the release header script from reading the enclosing repository's git metadata.
  GIT_CEILING_DIRECTORIES="$work" make -C "$source" -j"$(sysctl -n hw.ncpu)" MALLOC=libc >&2
  log "Built $name $version in $((SECONDS - start)) s"

  mkdir -p "$bin"
  install -m 755 "$source/src/$name-server" "$source/src/$name-cli" "$bin/"
  is_installed "$bin" "$name" "$version" \
    || die "$bin/$name-server does not report version $version: $("$bin/$name-server" --version)"
  log "Installed $("$bin/$name-server" --version)"
  print_env "$upper" "$bin" "$name"
}

main "$@"

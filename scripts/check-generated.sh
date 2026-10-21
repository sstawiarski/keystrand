#!/usr/bin/env bash
set -euo pipefail

# Runs every generator and fails when a generated file is stale.
# Usage: scripts/check-generated.sh [--only <name>]...

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
readonly ROOT
readonly GENERATORS=(commands samples icon strings api-reference xcodegen)
readonly COMMAND_CACHE=".build/command-sources"

usage() {
  cat <<'USAGE'
Usage: scripts/check-generated.sh [--only <name>]...

Runs each generator in place, compares its outputs with the files that were
there before, and exits 1 when any output changed (the file was stale). Stale
files are left regenerated. The comparison uses copies taken before each run,
so it works with or without git history.

Generators:
  commands       python3 -I scripts/make-redis-commands.py .build/command-sources
                 (downloads the pinned sources into that cache on first run)
  samples        python3 -I scripts/make-sample-data.py
  icon           swift scripts/make-app-icon.swift <AppIcon.appiconset>
  api-reference  scripts/make-api-reference.sh --check
  xcodegen       xcodegen generate, twice; the second run must change nothing

  --only <name>  run only this generator; repeat to run several
  -h, --help     show this help

Environment:
  CHECK_GENERATED_REPORT_DIR  where the before-copies and <name>.diff files go;
                              default a new temporary directory
USAGE
}

die() {
  printf 'check-generated.sh: %s\n' "$*" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

outputs_for() {
  case "$1" in
    commands) printf '%s\n' Sources/CommandSpecs/Resources/Commands ;;
    samples)
      printf '%s\n' \
        Sources/Features/BrowserFeature/Resources/SampleData \
        Sources/Features/VectorSearchFeature/Resources/SampleData
      ;;
    icon) printf '%s\n' Keystrand/Resources/Assets.xcassets/AppIcon.appiconset ;;
    strings) printf '%s\n' Keystrand/Localizable.xcstrings ;;
    api-reference) printf '%s\n' docs/ARCHITECTURE.md ;;
    xcodegen) printf '%s\n' Keystrand.xcodeproj Config/Info.plist ;;
  esac
}

run_generator() {
  case "$1" in
    commands) python3 -I scripts/make-redis-commands.py "$COMMAND_CACHE" ;;
    samples) python3 -I scripts/make-sample-data.py ;;
    icon) swift scripts/make-app-icon.swift Keystrand/Resources/Assets.xcassets/AppIcon.appiconset ;;
    strings) scripts/sync-strings.sh ;;
    xcodegen) xcodegen generate --quiet ;;
  esac
}

# Copies the outputs of generator $1 into a new directory and prints its path.
snapshot() {
  local name="$1" dir path dest
  dir="$(mktemp -d "$REPORT_DIR/$name.before.XXXXXX")"
  while IFS= read -r path; do
    [[ -e "$path" ]] || continue
    dest="$dir/$path"
    mkdir -p "$(dirname "$dest")"
    cp -R "$path" "$dest"
  done < <(outputs_for "$name")
  printf '%s\n' "$dir"
}

# Diffs each output of generator $1 against its copy in $2; returns 1 when any differs.
compare() {
  local name="$1" dir="$2" path before status=0
  while IFS= read -r path; do
    before="$dir/$path"
    if [[ ! -e "$before" && ! -e "$path" ]]; then
      continue
    elif [[ ! -e "$before" ]]; then
      printf 'Only after the run: %s\n' "$path"
      status=1
    elif [[ ! -e "$path" ]]; then
      printf 'Removed by the run: %s\n' "$path"
      status=1
    elif ! diff -ru "$before" "$path"; then
      status=1
    fi
  done < <(outputs_for "$name")
  return "$status"
}

print_git_status() {
  local name="$1" path paths=()
  git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 0
  while IFS= read -r path; do paths+=("$path"); done < <(outputs_for "$name")
  printf 'git status of the %s outputs:\n' "$name"
  git status --porcelain -- "${paths[@]}"
}

# Runs one generator; returns 0 when its outputs are current, 1 when stale, 2 when it failed.
check_one() {
  local name="$1" diff_file="$REPORT_DIR/$1.diff" log_file="$REPORT_DIR/$1.log"
  local started=$SECONDS before code=0
  printf '==> %s\n' "$name"
  : >"$log_file"

  # xcodegen writes only ignored files, so the first run sets them up and the second must match it.
  if [[ "$name" == xcodegen ]] && ! run_generator "$name" >>"$log_file" 2>&1; then
    report_failure "$name" "$log_file"
    return 2
  fi

  before="$(snapshot "$name")"
  if [[ "$name" == api-reference ]]; then
    scripts/make-api-reference.sh --check >"$diff_file" 2>>"$log_file" || code=$?
  else
    run_generator "$name" >>"$log_file" 2>&1 || code=2
    : >"$diff_file"
  fi

  if ((code > 1)); then
    report_failure "$name" "$log_file"
    return 2
  fi

  if ! compare "$name" "$before" >>"$diff_file" 2>&1; then
    code=1
  fi

  if ((code == 1)); then
    report_stale "$name" "$diff_file" "$log_file"
    return 1
  fi
  printf '    up to date (%ss)\n' "$((SECONDS - started))"
}

report_stale() {
  local name="$1" diff_file="$2" log_file="$3" stale
  stale="$(grep -E '^(diff -ru |Only in |Only after |Removed by |Binary files |\+\+\+ b/)' "$diff_file" |
    sed -E 's/^diff -ru [^ ]+ //; s/^\+\+\+ b\///' | sed 's/^/    /' || true)"
  printf 'STALE: %s changed these outputs:\n%s\n' "$name" "${stale:-    (see $diff_file)}" >&2
  if [[ "$name" == api-reference ]]; then
    printf '    Regenerate with: %s\n' "$(fix_hint "$name")" >&2
  else
    printf '    They are now regenerated in place. To regenerate by hand: %s\n' "$(fix_hint "$name")" >&2
  fi
  printf '    Full diff: %s\n    Generator log: %s\n' "$diff_file" "$log_file" >&2
  print_git_status "$name" >&2
}

report_failure() {
  local name="$1" log_file="$2"
  printf 'FAILED: the %s generator exited with an error. Last lines of %s:\n' "$name" "$log_file" >&2
  tail -n 20 "$log_file" | sed 's/^/    /' >&2
}

fix_hint() {
  case "$1" in
    commands) printf 'python3 -I scripts/make-redis-commands.py %s' "$COMMAND_CACHE" ;;
    samples) printf 'python3 -I scripts/make-sample-data.py' ;;
    icon) printf 'swift scripts/make-app-icon.swift Keystrand/Resources/Assets.xcassets/AppIcon.appiconset' ;;
    strings) printf 'scripts/sync-strings.sh' ;;
    api-reference) printf 'scripts/make-api-reference.sh' ;;
    xcodegen) printf 'fix project.yml so that xcodegen generate gives the same project on every run' ;;
  esac
}

selected=()
while (($#)); do
  case "$1" in
    --only)
      (($# >= 2)) || die "--only needs a generator name"
      [[ " ${GENERATORS[*]} " == *" $2 "* ]] || die "unknown generator '$2' (expected one of: ${GENERATORS[*]})"
      selected+=("$2")
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done
if ((${#selected[@]} == 0)); then
  selected=("${GENERATORS[@]}")
fi

require_cmd python3
require_cmd swift
require_cmd diff
if [[ " ${selected[*]} " == *" xcodegen "* ]]; then
  require_cmd xcodegen
fi

cd "$ROOT"
REPORT_DIR="${CHECK_GENERATED_REPORT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/check-generated.XXXXXX")}"
mkdir -p "$REPORT_DIR"
REPORT_DIR="$(cd "$REPORT_DIR" && pwd -P)"
readonly REPORT_DIR

stale=()
failed=()
for name in "${selected[@]}"; do
  code=0
  check_one "$name" || code=$?
  if ((code == 1)); then
    stale+=("$name")
  elif ((code != 0)); then
    failed+=("$name")
  fi
done

printf '\nReport directory: %s\n' "$REPORT_DIR"
if ((${#failed[@]} > 0)); then
  printf 'Generators that failed: %s\n' "${failed[*]}" >&2
fi
if ((${#stale[@]} > 0)); then
  printf 'Stale generated files from: %s\n' "${stale[*]}" >&2
fi
if ((${#failed[@]} > 0 || ${#stale[@]} > 0)); then
  exit 1
fi
printf 'All generated files are up to date.\n'

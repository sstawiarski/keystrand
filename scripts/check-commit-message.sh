#!/usr/bin/env bash
set -euo pipefail

# Description: Checks that a commit subject or PR title follows Conventional Commits.
# Usage: scripts/check-commit-message.sh <message-file | subject>
#        scripts/check-commit-message.sh --self-test

readonly PATTERN='^(feat|fix|docs|refactor|test|build|ci|chore|perf)(\([a-z0-9-]+\))?!?: .{1,72}$'
readonly EXEMPT='^(Merge |Revert |fixup! |squash! )'

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/check-commit-message.sh <message-file | subject>
       scripts/check-commit-message.sh --self-test

Checks the subject (first line that is not blank or a # comment) of a commit
message file, or a subject or PR title given as text. Exits 1 when it does not
follow Conventional Commits.
USAGE
  exit 2
}

format_help() {
  cat >&2 <<'HELP'
Expected: <type>[(scope)][!]: <summary>, with a summary of 1-72 characters.
  type   feat, fix, docs, refactor, test, build, ci, chore, or perf
  scope  optional, lowercase letters, digits, and hyphens: fix(browser): ...
  !      marks a breaking change: feat(resp)!: ...
Examples:
  feat(workbench): add a Command Helper search field
  fix: keep non-UTF-8 key names when renaming
Merge, Revert, fixup!, and squash! subjects are allowed as git writes them.
HELP
}

first_subject_line() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
    printf '%s\n' "$line"
    return 0
  done
  printf '\n'
}

subject_of() {
  if [[ -f "$1" ]]; then
    first_subject_line <"$1"
  else
    printf '%s\n' "${1%%$'\n'*}"
  fi
}

is_valid() {
  [[ "$1" =~ $EXEMPT || "$1" =~ $PATTERN ]]
}

self_test() {
  local failures=0 subject
  local valid=(
    "feat: add vector set support"
    "fix(browser): keep non-UTF-8 key names"
    "feat(resp)!: drop RESP2 fallback"
    "ci: run live tests on native servers"
    "Merge branch 'main' into feature"
    'Revert "feat: add vector set support"'
    "fixup! fix(browser): keep key names"
    "squash! docs: explain native mode"
  )
  local invalid=(
    "Add vector set support"
    "feature: add vector set support"
    "feat:add vector set support"
    "feat(Browser): keep key names"
    "fix: "
    "feat: $(printf 'x%.0s' {1..73})"
    "WIP"
  )
  for subject in "${valid[@]}"; do
    if ! is_valid "$subject"; then
      printf 'FAIL: rejected a valid subject: %s\n' "$subject" >&2
      failures=$((failures + 1))
    fi
  done
  for subject in "${invalid[@]}"; do
    if is_valid "$subject"; then
      printf 'FAIL: accepted an invalid subject: %s\n' "$subject" >&2
      failures=$((failures + 1))
    fi
  done
  if [[ "$(first_subject_line <<<$'# comment\n\ndocs: explain native mode\n\nBody text.')" != "docs: explain native mode" ]]; then
    printf 'FAIL: message file subject not found\n' >&2
    failures=$((failures + 1))
  fi
  if ((failures > 0)); then
    printf '%s self-test case(s) failed\n' "$failures" >&2
    return 1
  fi
  printf 'self-test passed (%s cases)\n' $((${#valid[@]} + ${#invalid[@]} + 1))
}

main() {
  [[ $# -eq 1 ]] || usage
  case "$1" in
    -h | --help) usage ;;
    --self-test) self_test; return ;;
  esac
  local subject
  subject="$(subject_of "$1")"
  if is_valid "$subject"; then
    return 0
  fi
  printf 'Not a Conventional Commits subject: %s\n' "$subject" >&2
  format_help
  return 1
}

main "$@"

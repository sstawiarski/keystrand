#!/usr/bin/env bash
set -euo pipefail

# Adds blank lines around multi-line declarations and after multi-line control-flow blocks.
# SwiftFormat spaces imports and MARK comments and collapses consecutive blank lines.
# ast-grep locates declarations and blocks that still need blank lines.
# Usage: scripts/format.sh [--check] [path ...]
#   With no path, formats Package.swift, Keystrand, Sources, Tests, and scripts.
#   --check changes no files. It prints each place that needs a change and exits 1 if there is one.

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
readonly ROOT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf "Error: '%s' is required but not installed.%s\n" "$1" "${2:-}" >&2
    exit 1
  }
}

# One tab-separated row per match: rule id, file, first and last line (0-based), and the text after the
# match on its last line.
find_multiline_nodes() {
  ast-grep scan --config "$ROOT/sgconfig.yml" --filter '^blank-line-' \
    --info=blank-line-around-declaration --info=blank-line-after-block --json=stream "$@" |
    jq -r '[.ruleId, .file, .range.start.line, .range.end.line,
      ((.lines | split("\n") | last) as $line | (.text | split("\n") | last | length) as $n | $line[$n:])]
      | @tsv'
}

# If check=1, reports missing blank lines and exits 1; otherwise inserts them.
insert_blank_lines() {
  awk -v check="$1" '
    BEGIN { FS = "\t" }

    {
      rule[NR] = $1
      first[NR] = $3 + 1
      last[NR] = $4 + 1
      after[NR] = $5
      if (!($2 in rows)) files[++file_count] = $2
      rows[$2] = rows[$2] " " NR
    }

    END {
      for (f = 1; f <= file_count; f++) format_file(files[f])
      if (check) exit (gap_total > 0)
      if (gap_total > 0) printf "Added %d blank lines in %d files.\n", gap_total, changed_files
    }

    function trim(s) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t\r]+$/, "", s)
      return s
    }

    function is_comment(s) {
      s = trim(s)
      return s ~ /^\/\// || s ~ /^\/\*/ || s ~ /^\*/ || s ~ /\*\/$/
    }

    # The blank line goes above the comments that document the declaration. None is needed when the
    # line above opens a scope, a closure, a case, or an #if branch.
    function mark_before(start,   above, text) {
      above = start - 1
      while (above >= 1 && is_comment(lines[above])) above--
      if (above < 1) return
      text = trim(lines[above])
      if (text == "" || text ~ /[{(\[:]$/ || text ~ /(^|[ \t])in$/ || text ~ /^#(if|else|elseif)([ \t]|$)/) return
      gap[above + 1] = 1
    }

    # None is needed when code follows the match on its last line, or when the next line closes a
    # scope, starts the next case, or ends an #if branch.
    function mark_after(end, rest,   text) {
      rest = trim(rest)
      if (rest != "" && rest !~ /^\/\//) return
      if (end >= line_count) return
      text = trim(lines[end + 1])
      if (text == "" || text ~ /^[})\]]/ || text ~ /^#(else|elseif|endif)([ \t]|$)/) return
      if (text ~ /^(case[ \t.]|default[ \t]*:|@unknown[ \t])/) return
      gap[end + 1] = 1
    }

    function format_file(path,   row, ids, id_count, k, id, i, gaps) {
      line_count = 0
      delete lines
      delete gap
      while ((getline row < path) > 0) lines[++line_count] = row
      close(path)

      id_count = split(rows[path], ids, " ")
      for (k = 1; k <= id_count; k++) {
        id = ids[k]
        if (rule[id] == "blank-line-around-declaration") mark_before(first[id])
        mark_after(last[id], after[id])
      }

      gaps = 0
      for (i = 1; i <= line_count; i++) {
        if (!(i in gap)) continue
        gaps++
        if (check) printf "%s:%d: add a blank line above this line\n", path, i
      }
      if (gaps == 0) return
      gap_total += gaps
      changed_files++
      if (check) return

      for (i = 1; i <= line_count; i++) {
        if (i in gap) print "" > path
        print lines[i] > path
      }
      close(path)
    }
  '
}

main() {
  require_cmd swiftformat " Install it with: brew install swiftformat"
  require_cmd ast-grep " Install it with: brew install ast-grep"
  require_cmd jq

  local check=0
  if [[ "${1:-}" == "--check" ]]; then
    check=1
    shift
  fi

  local paths=("$@")
  if [[ ${#paths[@]} -eq 0 ]]; then
    cd "$ROOT"
    paths=(Package.swift Keystrand Sources Tests scripts)
  fi

  local status=0
  if (( check )); then
    swiftformat --config "$ROOT/.swiftformat" --lint "${paths[@]}" || status=1
  else
    swiftformat --config "$ROOT/.swiftformat" "${paths[@]}"
  fi
  find_multiline_nodes "${paths[@]}" | insert_blank_lines "$check" || status=1
  return "$status"
}

main "$@"

#!/bin/zsh
# Launches the built app, waits, captures only its main window, and quits it.
# Usage: scripts/snapshot.sh <out.png> [app launch args...]
# Example: scripts/snapshot.sh /tmp/browser.png --open 127.0.0.1:6390
# Env: APP (default dist/Keystrand.app), WAIT seconds before capture (default 6),
#      KEYSTRAND_DATA_DIR (default: a fresh temp dir, so launches never touch the real store).
set -u
ROOT="${0:A:h:h}"
OUT="$1"; shift
APP="${APP:-$ROOT/dist/Keystrand.app}"
WAIT="${WAIT:-6}"
BIN="$APP/Contents/MacOS/Keystrand"
[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 2; }
export KEYSTRAND_DATA_DIR="${KEYSTRAND_DATA_DIR:-$(mktemp -d /tmp/keystrand-snap.XXXXXX)}"
KEYSTRAND_DISABLE_AUTODISCOVERY=1 "$BIN" "$@" >/dev/null 2>&1 &
PID=$!
sleep "$WAIT"
WID=$(swift "$ROOT/scripts/windowid.swift" "$PID" 2>/dev/null)
if [ -z "$WID" ]; then echo "no Keystrand window found" >&2; kill $PID 2>/dev/null; exit 1; fi
screencapture -x -o -l "$WID" -t png "$OUT"
STATUS=$?
kill $PID 2>/dev/null
[ $STATUS -eq 0 ] && echo "captured window $WID to $OUT"
exit $STATUS

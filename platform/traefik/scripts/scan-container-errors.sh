#!/bin/sh
# Count error-like lines per pod/container in kubelet container logs, for the
# last N minutes, and alarm when any container crosses a threshold.
#
# Runs on hetzner-adiwave-vera1 as root. Read-only: never modifies logs.
#
# Usage:  scan-container-errors.sh [--verbose] [window_minutes] [threshold_count] [top_n]
# Defaults: 60 minutes, threshold 50 matching lines, top 10 offenders.
#
#   --verbose  also prints each matching line with 3 lines before and after,
#              prefixed with the full path of the source log file. Output can
#              contain user data, tokens or stack traces: run it as root on the
#              node only, and do not paste it into tickets or chat.
#
# Log source: /var/log/pods/<namespace>_<pod>_<uid>/<container>/*.log
# (CRI format: "<RFC3339 timestamp> <stream> <tag> <message>").
#
# Cron example (every 15 minutes, alarm goes to syslog; no verbose output):
#   */15 * * * * out=$(/usr/local/sbin/scan-container-errors.sh 15 50 10); case "$out" in *ALARM*) echo "$out" | logger -t container-errors -p user.crit;; esac
#
# Matched patterns (edit PATTERN to tune):
#   Java:    Exception, Caused by:, OutOfMemoryError, StackOverflowError, NullPointerException
#   JS/TS:   TypeError, ReferenceError, SyntaxError, UnhandledPromiseRejection, Uncaught
#   Python:  Traceback (most recent call last)
#   Go:      panic:
#   Generic: FATAL, ERROR

VERBOSE=0
if [ "$1" = "--verbose" ]; then
  VERBOSE=1
  shift
fi

WINDOW_MIN="${1:-60}"
THRESHOLD="${2:-50}"
TOP_N="${3:-10}"
MAX_LINES=200
LOG_GLOB="/var/log/pods/*/*/*.log"
CUTOFF=$(date -u -d "-${WINDOW_MIN} min" +%Y-%m-%dT%H:%M:%S)
PATTERN='Exception|Caused by:|OutOfMemoryError|StackOverflowError|NullPointerException|TypeError|ReferenceError|SyntaxError|UnhandledPromiseRejection|Uncaught|Traceback \(most recent call last\)|panic:|FATAL|ERROR'

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

for f in $LOG_GLOB; do
  [ -f "$f" ] || continue
  # Pod directory: <namespace>_<pod>_<uid>; container is the next directory.
  pod=$(echo "$f" | awk -F/ '{print $5}')
  container=$(echo "$f" | awk -F/ '{print $6}')
  # CRI timestamps are UTC ISO-8601, so string comparison against CUTOFF is valid.
  count=$(awk -v cut="$CUTOFF" '$1 >= cut' "$f" | grep -cE "$PATTERN")
  [ "$count" -gt 0 ] && echo "$count $pod $container $f" >> "$TMP"
done

echo "Container error scan: last ${WINDOW_MIN} min since ${CUTOFF}Z, threshold ${THRESHOLD}"
if [ ! -s "$TMP" ]; then
  echo "OK no matching error lines"
  exit 0
fi

sort -rn "$TMP" | head -n "$TOP_N" | awk '{printf "%6d  %s  [%s]  %s\n", $1, $2, $3, $4}'

if [ "$VERBOSE" = "1" ]; then
  sort -rn "$TMP" | head -n "$TOP_N" | while read -r count pod container file; do
    echo ""
    echo "=== $pod [$container]: $count matching lines in $file"
    # Keep only lines inside the window, then show matches with 3 lines of context.
    # Line numbers refer to the window-filtered stream, not the original file.
    awk -v cut="$CUTOFF" '$1 >= cut' "$file" \
      | grep -nE -B3 -A3 "$PATTERN" \
      | head -n "$MAX_LINES" \
      | cut -c1-400 \
      | sed "s|^|src: $file  |"
  done
fi

if sort -rn "$TMP" | head -n 1 | awk -v t="$THRESHOLD" '$1 >= t {found=1} END {exit !found}'; then
  echo "ALARM at least one container reached ${THRESHOLD} error lines in ${WINDOW_MIN} min"
  exit 1
fi
exit 0

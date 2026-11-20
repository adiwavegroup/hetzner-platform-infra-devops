#!/bin/sh
# Alarm when the Traefik access log reaches a size threshold.
#
# Runs on the Hetzner host (hetzner-adiwave-vera1), reads the file on the
# access-logs PV. Exit 0 = below threshold, exit 1 = at/above threshold.
#
# Usage:  access-log-size-check.sh [file] [threshold_bytes]
# Defaults: /mnt/access-logs/access.log, 1 GiB (1073741824 bytes).
#
# Cron example (every 15 minutes, alarm goes to syslog and stderr):
#   */15 * * * * /usr/local/sbin/access-log-size-check.sh || true
#
# Read-only: never modifies or truncates the log.

LOG_FILE="${1:-/mnt/access-logs/access.log}"
THRESHOLD="${2:-1073741824}"

if [ ! -f "$LOG_FILE" ]; then
  echo "access-log-size-check: $LOG_FILE not found" >&2
  exit 2
fi

SIZE=$(stat -c %s "$LOG_FILE" 2>/dev/null || stat -f %z "$LOG_FILE")
MOUNT_DIR=$(dirname "$LOG_FILE")
FREE_KB=$(df -Pk "$MOUNT_DIR" | awk 'NR==2 {print $4}')

if [ "$SIZE" -ge "$THRESHOLD" ]; then
  MSG="ALARM access log $LOG_FILE is ${SIZE} bytes (threshold ${THRESHOLD}); disk free on $MOUNT_DIR: ${FREE_KB} KiB"
  echo "$MSG" >&2
  command -v logger >/dev/null 2>&1 && logger -t access-log-size-check -p user.crit "$MSG"
  exit 1
fi

echo "OK access log $LOG_FILE is ${SIZE} bytes (threshold ${THRESHOLD}); disk free on $MOUNT_DIR: ${FREE_KB} KiB"
exit 0

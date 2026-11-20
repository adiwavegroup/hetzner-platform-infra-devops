# /etc/profile.d/access-log-login-banner.sh
#
# Shows the Traefik access log size at interactive root login on
# hetzner-adiwave-vera1. Read-only. Silent for non-root users and when
# the log file does not exist.
#
# Install on the node (as root):
#   cp access-log-login-banner.sh /etc/profile.d/access-log-login-banner.sh
#   chmod 0644 /etc/profile.d/access-log-login-banner.sh
#
# Runs for login shells (ssh root@host). Not run for `ssh root@host <command>`.

if [ "$(id -u)" = "0" ] && [ -f /mnt/access-logs/access.log ]; then
  LOG_FILE=/mnt/access-logs/access.log
  SIZE_BYTES=$(stat -c %s "$LOG_FILE" 2>/dev/null || stat -f %z "$LOG_FILE")
  SIZE_MB=$((SIZE_BYTES / 1048576))
  if [ "$SIZE_BYTES" -ge 1073741824 ]; then
    FLAG="  ** ALARM: reached 1 GB **"
  else
    FLAG=""
  fi
  printf '\nWelcome Administrator, current on disk %s size is %s MB%s\n\n' "$LOG_FILE" "$SIZE_MB" "$FLAG"
fi

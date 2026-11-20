# /etc/profile.d/access-log-login-banner.sh
#
# At interactive root login on hetzner-adiwave-vera1:
#   1. shows the Traefik access log size (read live)
#   2. shows /root/summary.txt, written every 2 hours by build-root-summary.sh (max 50 lines)
# Silent for non-root users. Read-only.
#
# Install on the node (as root):
#   cp access-log-login-banner.sh /etc/profile.d/access-log-login-banner.sh
#   chmod 0644 /etc/profile.d/access-log-login-banner.sh

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

if [ "$(id -u)" = "0" ] && [ -r /root/summary.txt ]; then
  head -n 50 /root/summary.txt
  echo ""
fi

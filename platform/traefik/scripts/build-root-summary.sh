#!/bin/sh
# Build /root/summary.txt (max 50 lines) with a snapshot of cluster and node health.
# Run every 2 hours from root's crontab. Written atomically; never prints secrets.
# Shown at root login by /etc/profile.d/access-log-login-banner.sh.
#
# Cron (root crontab, `crontab -e`):
#   KUBECONFIG=/root/.kube/config
#   0 */2 * * * /usr/local/sbin/build-root-summary.sh >/dev/null 2>&1

OUT=/root/summary.txt
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
TMP=$(mktemp /root/.summary.XXXXXX) || exit 1
trap 'rm -f "$TMP"' EXIT

{
  echo "Generated: $(date '+%Y-%m-%d %H:%M %Z') on $(hostname)"

  echo "--- Pods not Running/Completed (all namespaces, top 15) ---"
  kubectl get pods -A --no-headers 2>&1 | awk '$4 != "Running" && $4 != "Completed"' | head -n 15

  echo "--- Pods with restarts (top 10) ---"
  kubectl get pods -A --no-headers 2>&1 | awk '$5+0 > 0' | sort -k5 -rn | head -n 10

  echo "--- Traefik ---"
  kubectl -n traefik get pods --no-headers 2>&1 | head -n 3

  echo "--- Certificates not Ready ---"
  NOT_READY=$(kubectl get certificate -A --no-headers 2>/dev/null | awk '$3 != "True"' | wc -l | tr -d ' ')
  echo "count: $NOT_READY"

  echo "--- Access log ---"
  ls -lh /mnt/access-logs/access.log 2>&1 | awk '{print $5, $9}'
  echo "TLS 1.2 requests in log: $(grep -c '"TLSVersion":"1.2"' /mnt/access-logs/access.log 2>/dev/null)"

  echo "--- Disk free on /mnt ---"
  df -h /mnt | tail -n 1

  echo "--- Container errors, last 120 min (top 5) ---"
  /usr/local/sbin/scan-container-errors.sh 120 50 5 2>&1 | head -n 8
} > "$TMP"

# Hard cap: header + 47 body lines + footer = 49 lines (under the 50-line limit).
{
  echo "=== K8S pods status summary ==="
  head -n 47 "$TMP"
  echo "=== end summary ==="
} > "$OUT.new" && chmod 0600 "$OUT.new" && mv "$OUT.new" "$OUT"

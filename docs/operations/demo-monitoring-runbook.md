# Demo-window monitoring runbook

**Purpose:** detect trouble during a production demo **without changing the cluster.**
Everything here is read-only except writing log files under `/root/demo-monitor/`.

## Node tooling

`jq` (1.8.2) and `helm` (v4.2.3) **are installed** on the node. Both were absent when this runbook
was first drafted and were added during the freeze window.

The monitor script below still uses `python3` rather than `jq`. That is deliberate and worth
keeping: `python3` ships with the node image, so the monitor cannot break if tooling is
reinstalled, reimaged or replaced on a future node. Use `jq` freely for interactive work.

**Workstation `kubectl` is blocked.** The allowed `/32` no longer matches the workstation's egress
(it changed, and current egress is IPv6 while the v6 rule was removed). SSH is unaffected, so run
everything node-local:

```bash
ssh -o IdentitiesOnly=yes -i ~/.ssh/hetzner-adiwave-vera/hetzner-adiwave-vera root@88.99.149.31
```

## Freeze — during the demo window, do not

Migrate, delete or restart Traefik, cert-manager, the registry, shared observability, Argo CD,
storage classes or firewall rules. No Helm upgrades, no namespace moves, no Argo CD ownership
transfers, and **no artificial load generation** — synthetic traffic cannot explain a control-plane
loop that is currently absent, and can itself destabilise the demo.

## 1. Passive sync monitor

Detects a return of the historical repeated-sync behaviour without touching anything.

```bash
mkdir -p /root/demo-monitor

while true; do
  {
    echo "===== $(date -Is) ====="
    kubectl -n argocd get applications \
      -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'
    kubectl -n argocd get applications -o json | python3 -c '
import json,sys
for a in json.load(sys.stdin)["items"]:
    st = a.get("status", {}) or {}
    op = st.get("operationState", {}) or {}
    print("\t".join([
        a["metadata"]["name"],
        op.get("phase", "-"),
        op.get("startedAt", "-"),
        op.get("finishedAt", "-"),
        (op.get("syncResult", {}) or {}).get("revision", "-")[:12],
    ]))
'
  } >> /root/demo-monitor/argocd-state.log 2>&1
  sleep 60
done
```

Run it detached so it survives the SSH session:

```bash
nohup bash /root/demo-monitor/monitor.sh > /dev/null 2>&1 &
```

### Reading it

The signal is **sync frequency**, not sync status. The historical loop produced ~12 completed syncs
per hour per app while `status` read `Synced` almost the whole time — status sampling could not see
it, which is why the loop went unnoticed for so long.

Count **distinct sync completions**, not lines. Every sample re-prints each app's *last*
`operationState`, so a naive `grep -c Succeeded` counts `apps × samples` and climbs forever even
when nothing is syncing — it reads 48 after four quiet samples:

```bash
# distinct (application, finishedAt) pairs = actual sync completions
awk -F'\t' 'NF>=4 && $4!="-" {print $1, $4}' /root/demo-monitor/argocd-state.log | sort -u | wc -l

# most recent completion per application
awk -F'\t' 'NF>=4 && $4!="-" {a[$1]=$4} END {for (k in a) printf "%-30s %s\n", k, a[k]}' \
  /root/demo-monitor/argocd-state.log | sort
```

A healthy baseline is exactly **one distinct completion per application** — 12 total — and it stays
at 12 while nothing changes. Each new completion adds one.

More than ~2 completions per hour for an app **with no Git change** means the loop is back.
If it returns, capture the diff rather than inferring the cause:

```bash
# rollback artifact FIRST
kubectl -n argocd get application <app> -o yaml > /root/demo-monitor/<app>-before.yaml

# let the diff become visible instead of being healed away
kubectl -n argocd patch application <app> --type=json \
  -p='[{"op":"replace","path":"/spec/syncPolicy/automated/selfHeal","value":false}]'

# ... wait for OutOfSync, then read what actually differs ...
kubectl -n argocd get application <app> -o json | python3 -c '
import json,sys
for r in json.load(sys.stdin)["status"].get("resources", []):
    if r.get("status") != "Synced":
        print(r.get("kind"), r.get("namespace"), r.get("name"), r.get("status"))
'

# ALWAYS restore
kubectl -n argocd patch application <app> --type=json \
  -p='[{"op":"replace","path":"/spec/syncPolicy/automated/selfHeal","value":true}]'
```

Then fix **only the observed field** — not a field you believe is responsible.

Do not claim a root cause without an observed diff. A previous attempt inferred one from apply
counts alone and was wrong — disabling self-heal showed no diff at all for 500 seconds.

**Do not restart the Argo CD controller** merely because the previous loop disappeared near a
controller restart. Roughly 12 hours of log was rotated away around that restart, so causation
cannot be established from it — and restarting to "fix" a recurrence would destroy the live
evidence needed to actually diagnose it, exactly as it did the first time.

Current classification, unchanged: **historically observed · currently absent · root cause
unresolved · not caused by proven `/status` drift.**

## 2. Cluster health snapshot

```bash
kubectl get nodes
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
kubectl -n argocd get applications
kubectl top node
kubectl top pods -A --sort-by=cpu | head -30
```

Expect **12 Applications, all Synced/Healthy**, and no pods outside Running/Completed.

## 3. Demo-critical endpoints

Read-only. Safe to repeat.

```bash
for u in https://adiwave.com/ https://www.adiwave.com/ https://vera.adiwave.com/ \
         https://portal.adiwave.com/ https://auth.adiwave.group/.well-known/openid-configuration \
         https://status.adiwave.group/ https://grafana.adiwave.group/ https://argocd.adiwave.group/; do
  printf '%-64s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$u")"
done
```

Verified good at compile time:

```
adiwave.com 200 · www 200 · vera 200 · portal 307 · status 200
auth /.well-known/openid-configuration 200 (issuer https://auth.adiwave.group) · jwks 200
grafana 302 (login redirect) · argocd 200
```

`https://auth.adiwave.group/` returning **403 on the bare root is normal** — check the OIDC
discovery document, not the root path.

### Stripe

Use a **real unsigned payload**, not an empty body. An empty body is a weaker test and exercised a
different code path (fixed in vera #67):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST https://adiwave.com/api/v1/payment/webhooks/stripe \
  -H 'Content-Type: application/json' \
  --data '{"id":"evt_1","object":"event","type":"payment_intent.succeeded","data":{"object":{}}}'
```

**Expect `400`** (`Missing Stripe-Signature header`). A `200` here is a defect. Never send a
fabricated *signed* event to production.

### Granite, if shown

```bash
for h in granite-security.org sichocolate.com media.granite-security.org \
         s3.granite-security.org garage.granite-security.org; do
  printf '%-36s https=%s http=%s\n' "$h" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://$h/)" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://$h/)"
done
```

`media` → 404 and `s3` → 403 are the **Garage backends' own answers**, not routing faults. Every
`http://` must be `301`.

## 4. Evidence preservation

Taken before the demo; re-run after if anything looked wrong:

```bash
kubectl get all -A -o yaml                 > /root/demo-monitor/all-resources-before-demo.yaml
kubectl get gateway,httproute -A -o yaml   > /root/demo-monitor/gateway-api-before-demo.yaml
kubectl -n argocd get applications -o yaml > /root/demo-monitor/applications-before-demo.yaml
kubectl get nodes -o wide                  > /root/demo-monitor/nodes-before-demo.txt
```

Record the exact Git revisions of all four repositories alongside them, so any later question about
"what was running" has a definite answer.

## 5. If something breaks mid-demo

Prefer the smallest reversible action. In order:

1. **Confirm the blast radius** — one host, one tenant, or everything? `curl` the list above.
2. **Check Applications** before touching any workload.
3. **Do not restart Traefik.** It binds `:80`/`:443` for every tenant; a restart converts a
   one-tenant problem into a total outage.
4. **Do not sync or migrate anything** to "fix" it during the demo.
5. Capture `kubectl -n argocd get application <app> -o yaml` and pod logs, then decide afterwards.

The one genuinely safe recovery lever is the SSH path with node-local `kubectl` — it is the reason
the workstation lockout is inconvenient rather than critical.

## Known-safe baseline at compile time

```
12/12 Applications Synced/Healthy · 277 tracked resources · 0 OutOfSync
all Granite HTTPRoutes Accepted=True (two untracked orphans removed)
routing validator PASS, all namespaces: 4 gateways · 17 HTTPS listeners · 31 routes
TLS valid to Oct 20-21 2026
repeated-sync loop: absent for 6+ hours with selfHeal enabled; cause unresolved
```

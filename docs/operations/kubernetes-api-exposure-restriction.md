# Restricting public access to the Kubernetes API (`:6443`)

**Applied to production:** 2026-07-31 · **Status:** stage 1 complete (temporary `/32`)
**Scope:** firewall rules only. Nothing else.

## The exposure

```
ufw allow 6443/tcp from Anywhere          (v4 and v6)
curl -sk https://88.99.149.31:6443/version  →  200
```

The Kubernetes control plane was reachable from the entire internet. Anonymous discovery responding
is normal; the reachability is not. It meant the API server's attack surface was every authentication
path, every apiserver CVE, and any leaked or stolen kubeconfig — including the
`kubernetes-admin@cluster.local` context sitting in at least one workstation kubeconfig.

Sequenced **after** the registry NodePort deliberately: the registry was leaking reusable credentials
in cleartext, whereas the API still required successful authentication before exposing anything.

## The question that decided whether this was safe

**Node-local components do not use `127.0.0.1`.** Every one of them targets the public address:

```
/etc/kubernetes/*.conf   server: https://88.99.149.31:6443
kubelet                  server: https://88.99.149.31:6443
```

So the change would have broken kubelet, controller-manager and scheduler — *unless* that traffic
bypasses the port rule. It does, and this was verified rather than assumed:

```
$ ip route get 88.99.149.31
local 88.99.149.31 dev lo src 88.99.149.31

$ iptables -S ufw-before-input | grep ' -i lo'
-A ufw-before-input -i lo -j ACCEPT
```

Traffic from the node to its own public IP is routed over **loopback**, and ufw accepts `lo`
unconditionally *before* any port rule is evaluated. Pods reaching the API are covered separately by
the existing `allow in on cali+` rules.

**Had `ufw-before-input` lacked that loopback accept, removing the global rule would have taken the
cluster down.** This is the check to repeat on any future node.

## Administrator source address

```
icanhazip.com    195.231.47.36
ifconfig.me      195.231.47.36
$SSH_CLIENT      195.231.47.36     ← authoritative: this is what ufw evaluates
```

Confirmed no VPN was supplying it — the workstation's configured VPN services were all
`Disconnected`.

**`$SSH_CLIENT` is evidence, not proof.** It reports the source address observed *for that SSH
connection*; a proxy or bastion in between would make it report the intermediary — still correct for
that connection, but not necessarily the address `kubectl` egresses from. The decisive proof came
afterwards: workstation `kubectl` kept working once the `/32` was the only rule, which is what
established that the same `/32` covers `kubectl` traffic and not merely SSH.

## The change

```bash
# 1. add the allowlist FIRST
ufw allow from 195.231.47.36/32 to any port 6443 proto tcp \
    comment 'temporary Kubernetes administrator (workstation egress) - replace with VPN'

# 2. delete the global rules by exact number, re-listing between deletions
ufw status numbered | grep 6443     # [ 2] Anywhere · [11] /32 · [13] Anywhere (v6)
ufw --force delete 2                # v4 global
ufw status numbered | grep 6443     # RENUMBERED: [10] /32 · [12] Anywhere (v6)
ufw --force delete 12               # v6 global
```

**ufw renumbers after every deletion**, so the list is re-read between them. Deleting by a stale
number would have removed the `/32` and locked out administration.

Final state — exactly one rule:

```
[10] 6443/tcp  ALLOW IN  195.231.47.36  # temporary Kubernetes administrator - replace with VPN
```

## Verification

| Check | Result |
|---|---|
| Workstation `kubectl get --raw=/readyz` | **ok** |
| Workstation `get nodes` | `node1 Ready control-plane 11d v1.35.4` |
| Workstation `get pods -A` | 68 pods, **0** not Running/Completed |
| Workstation `get applications -n argocd` | **12** |
| **Node-local** `/readyz` | **ok** |
| **Node-local** `kube-system` not Running | **0** |
| From an unrelated egress (third-party proxy) | **522, connection timed out — blocked** |
| From the allowed address | **200** |
| `kube-system` restarts over 90s | **33 → 33, stable** |

The node-local checks are the load-bearing ones: they prove the control plane kept talking to itself
after the global rule was removed.

## IPv6 — closed explicitly, not by assumption

The host **does** have a globally routable IPv6 address (`2a01:4f8:10a:2d49::2/64`) and the API
listens on `*:6443`, which includes IPv6. So this could not be left implicit.

```
/etc/default/ufw          IPV6=yes
ip6tables INPUT           policy DROP
ufw6-user-input           rules for 22 and 80 only — no 6443
```

Tested from a workstation with **working IPv6**, isolating the variable:

| Test | Result |
|---|---|
| IPv6 to a public control (`ipv6.google.com`) | **200** — the workstation has IPv6 |
| IPv6 to the node on an **open** port (`:80`) | **404** — route and reachability fine, Traefik answered |
| IPv6 to the node on **`:6443`** | **000 — blocked** |

Same host, same IPv6 path, different port: that isolates the block to the firewall rather than
routing or a missing address. Note the administrator `/32` is IPv4-only, so **nobody reaches the API
over IPv6, including the administrator** — correct here, since the kubeconfig uses the IPv4 endpoint.

## Rollback

```bash
ufw allow 6443/tcp
```

SSH on `:22` is untouched, so the node remains reachable and node-local `kubectl` works regardless of
whether workstation access does. That is the real safety net — not the ability to reconnect.

## Deliberately unchanged

API-server `bind-address` · Kubernetes certificates and SANs · kubeconfigs · Argo CD · Kubespray
configuration · SSH rules · Calico and service CIDRs · the registry.

## Stage 2 — this `/32` is interim, and its weaknesses are known

1. **`195.231.47.36` is probably not static.** A DHCP lease change or ISP re-address locks out
   workstation `kubectl`. Recovery is SSH plus node-local `kubectl`, then re-adding the new address —
   inconvenient, not catastrophic, but not a resting state.
2. **A `/32` is not a person.** If that address is shared (CGNAT, office NAT), everyone behind it is
   allowed to *reach* the API. They still need credentials, but the network control is coarser than
   it appears.

Durable options, in preference order:

- **WireGuard or Tailscale**, with `:6443` allowed only from the tunnel interface or subnet. Best fit
  for workstation-native `kubectl`.

  **A certificate SAN change is probably avoidable, and worth evaluating before touching
  certificates.** It is required only if the kubeconfig starts addressing the API through a *new* VPN
  IP or hostname absent from the current certificate. Routing the existing endpoint through the
  tunnel avoids it entirely:

  ```
  kubeconfig server stays   https://88.99.149.31:6443
  WireGuard routes          88.99.149.31/32 through the tunnel
  ufw allows 6443           only on the WireGuard interface / VPN source range
  ```

  Because the endpoint string is unchanged, the existing SAN remains valid. Whether routing the
  server's own public address through the tunnel suits the topology needs checking — but it should be
  ruled out before any Kubespray-aligned certificate operation is contemplated.
- **Bastion / SSH with node-local `kubectl`.** No certificate implications; less convenient.
- **A genuinely static reviewed egress address**, only if one exists.

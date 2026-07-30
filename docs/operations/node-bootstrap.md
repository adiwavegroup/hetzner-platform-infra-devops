# Node bootstrap — reverse-engineered from the live host

**Reconstructed:** 2026-07-30 from `/root/.bash_history` (669 lines), `/home/k8sadmin/.bash_history`
(46 lines), live `ufw` state, live Helm releases and live Kubernetes resources.

**Out of scope:** the initial Kubespray cluster build. That has its own repository and must not be
re-executed. This document begins at "Kubespray has produced a working cluster".

## Host

```
Linux node1 6.12.96+deb13-amd64 SMP PREEMPT_DYNAMIC Debian 6.12.96-1 (2026-07-20) x86_64
```

Debian 13 (Trixie). **One Hetzner dedicated server running one Kubernetes node that performs both
control-plane and workload duties**, single public IP `88.99.149.31`.

There is no **node-level** high availability. Rollout and voluntary-disruption controls still work —
they simply cannot survive loss of the only node. See `archdesign/health-exceptions.md` for what
`maxSurge`, PodDisruptionBudgets and anti-affinity do and do not buy here.

## What history could and could not reconstruct

| | Source |
|---|---|
| Firewall rules | root history + live `ufw status` |
| Registry install | root history (`kubectl apply`, `htpasswd`, secret creation) |
| Registry secrets | history — **values redacted, never captured** |
| Traefik install | **NOT in any history** — zero `helm` commands on the node |
| cert-manager install | **NOT in any history** |
| Argo CD install | **NOT in any history** |

**The Helm layer was installed from a workstation, not the node.** That is why the node's history
cannot reproduce it, and why `archdesign/snapshots/2026-07-30/*.yaml` were extracted with
`helm get values` from the live releases instead — the deployed state is the only trustworthy record.

## 1. Firewall (ufw)

Live state, verified:

```
Status: active
Default: deny (incoming), allow (outgoing), allow (routed)

22/tcp     ALLOW IN  Anywhere
6443/tcp   ALLOW IN  Anywhere          # ← see security findings
10.233.0.0/18 ALLOW IN 10.233.0.0/18   # k8s internal cluster traffic
10.233.0.0/18 ALLOW IN Anywhere        # k8s service+pod CIDR
80/tcp     ALLOW IN  Anywhere
443/tcp    ALLOW IN  Anywhere
30500/tcp  ALLOW IN  Anywhere          # ← REMOVED 2026-07-31, see below
```

> **`30500/tcp` was removed on 2026-07-31.** It exposed the registry over plaintext HTTP with
> reusable Basic credentials. See
> [`registry-nodeport-exposure-closure.md`](registry-nodeport-exposure-closure.md). Do not re-add it
> when rebuilding a node — the Traefik route at `registry.adiwave.com` is the only required path.

Reconstructed sequence (Calico rules came from history; the rest from live state):

```bash
ufw allow 22/tcp
ufw allow 6443/tcp
ufw allow from 10.233.0.0/16
ufw allow in  on cali+
ufw allow out on cali+
ufw allow 80/tcp
ufw allow 443/tcp
# ufw allow 30500/tcp   ← DO NOT re-add; removed 2026-07-31 (plaintext credential exposure)
ufw reload
```

## 2. Platform components — recorded for the future transfer PRs

> These commands are **evidence of how to reproduce what is deployed**, not an install procedure to
> run from this repository today. This repository owns nothing yet; each component gets its own
> ownership-transfer PR. The values referenced below are read-only snapshots under
> `archdesign/snapshots/2026-07-30/`.

```bash
# Traefik — chart traefik-41.0.2, app v3.7.6
helm repo add traefik https://traefik.github.io/charts
helm upgrade --install traefik traefik/traefik \
  --version 41.0.2 --namespace traefik --create-namespace \
  -f archdesign/snapshots/2026-07-30/traefik-user-values.yaml

# cert-manager — chart cert-manager-v1.21.0
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --version v1.21.0 --namespace cert-manager --create-namespace \
  -f archdesign/snapshots/2026-07-30/cert-manager-user-values.yaml
```

Then the `letsencrypt-prod` ClusterIssuer (ACME
`https://acme-v02.api.letsencrypt.org/directory`) — **currently managed by nothing**, and needs a
manifest in this repository.

The Traefik values contain a non-obvious mechanism worth understanding before touching them: two init
containers copy the Traefik binary out of the image and run `setcap cap_net_bind_service=+ep` on it,
so the DaemonSet can bind :80/:443 with `hostNetwork` while still running as UID 65532. Removing
either init container breaks port binding.

## 3. Private registry

Applied by hand; **no GitOps owner**. Live state diverges from the manifest that created it — the
running Deployment has no `REGISTRY_HTTP_TLS_CERTIFICATE`/`_KEY`, so it serves plain HTTP behind
Traefik TLS termination while the `registry-tls` volume remains mounted and unused.

```bash
mkdir -p /tmp/auth
htpasswd -Bc /tmp/auth/.htpasswd <username>          # value never captured
kubectl create secret generic registry-auth --from-file=/tmp/auth/.htpasswd -n default
kubectl create secret tls registry-tls --cert=/tmp/registry.crt --key=/tmp/registry.key -n default
kubectl apply -f registry-deploy.yaml
```

Secrets are recorded as *shape only*. **No credential, hash or key material was read, printed or
stored** — and reconstruction must mint fresh credentials rather than attempt recovery.

## 4. Security findings — from this reconstruction

Both verified from the public internet, not inferred.

### 4.1 The Kubernetes API server is exposed to the whole internet

```
curl -sk https://88.99.149.31:6443/version   →   200
{"major":"1","minor":"35", ...}
```

`ufw allow 6443/tcp from Anywhere`. Anonymous discovery responding is normal in itself; the exposure
is not. It means the control plane is reachable by anyone, so its attack surface is every
authentication path, every API-server CVE, and any leaked or stolen kubeconfig — including the
`kubernetes-admin@cluster.local` context that currently sits in at least one workstation kubeconfig.

Recommended: restrict :6443 to known administrative sources, or front it with a VPN/bastion. This is
independent of the Cloudflare work and, in my assessment, higher priority than any of it.

### 4.2 The registry NodePort bypasses TLS entirely

```
curl http://88.99.149.31:30500/v2/   →   401
```

The registry is reachable two ways: `https://registry.adiwave.com` through Traefik (TLS terminated,
certificate `registry-adiwave-com-tls`), **and** directly on `http://88.99.149.31:30500` in plaintext.

The second path still enforces htpasswd auth — which is the problem. **HTTP Basic credentials are
base64, not encrypted**, so any client or CI job configured against the NodePort transmits registry
credentials in cleartext across the public internet, and anyone on-path can read them. The 401 proves
the path is live and accepting authentication attempts.

**RESOLVED 2026-07-31.** `ufw allow 30500/tcp` removed after proving every consumer uses
`registry.adiwave.com`: 7 pod images, both `imagePullSecrets`, and CI all reference the TLS host, and
no `containerd` config pinned the NodePort. Verified by forcing a real image pull. See
[`registry-nodeport-exposure-closure.md`](registry-nodeport-exposure-closure.md).

### 4.3 Ancillary

- `registry:2` is an unpinned tag; the resolved digest is unrecorded, so "reproducible" is currently
  aspirational for the registry.
- `hostPath: /mnt/registry` pins the registry to this node, unreplicated, with no verified backup, and
  `REGISTRY_STORAGE_DELETE_ENABLED=true` with no garbage-collection history found.
- Single node means control-plane and workload failure domains are identical.

## 5. What replication still cannot reproduce

Honest limits of this reverse-engineering:

- **Secret values** — deliberately never read. Reconstruction mints new credentials.
- **Kubespray configuration** — separate repository, out of scope by instruction.
- **Argo CD install** — raw manifests, absent from history; the applied version is unknown and needs
  establishing from the live resources before it can be pinned.
- **Observability** — six Applications with no single source repo; provenance unestablished.
- **Any action taken from a workstation** rather than on the node, which includes the entire Helm
  layer.

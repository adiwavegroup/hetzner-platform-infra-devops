# Closing the public plaintext registry path (NodePort 30500)

**Applied to production:** 2026-07-31 · **Status:** closed and verified
**Scope:** one firewall rule. Nothing else.

## The exposure

The private registry was reachable two ways:

```
https://registry.adiwave.com   → Traefik, TLS terminated, cert registry-adiwave-com-tls
http://88.99.149.31:30500      → NodePort, PLAINTEXT, open to the whole internet
```

The second path still enforced htpasswd auth — **which is what made it dangerous, not what made it
safe**. HTTP Basic is base64, not encryption. Any client, CI job or human pointed at the NodePort
transmitted **reusable registry credentials in cleartext across the public internet**, readable by
anyone on-path. `curl http://88.99.149.31:30500/v2/` returned `401`, proving the path was live and
accepting authentication attempts.

Prioritised ahead of the open Kubernetes API (`:6443`) for one reason: the API still requires
successful authentication before anything is exposed, whereas this path was leaking the credentials
themselves.

## Evidence that `registry.adiwave.com` is the only required path

Gathered read-only, before changing anything:

| Check | Result |
|---|---|
| Pod images referencing the registry | **7** via `registry.adiwave.com`, **0** via `:30500` or the node IP |
| Pod specs mentioning `30500` | **0** |
| `containerd` / `docker` node config | no pin to the NodePort |
| `imagePullSecrets` — `veracrm/registry-credentials` | `auths: ["registry.adiwave.com"]` |
| `imagePullSecrets` — `me-funnel/registry-credentials` | `auths: ["registry.adiwave.com"]` |
| CI workflow | `REGISTRY_HOST=registry.adiwave.com`; no NodePort reference in any workflow |

Secret *hosts* were read; **no credential value was read, printed or stored.**

The one thing this cannot prove is a negative about humans — a laptop or an unrecorded script could
have been pushing to `:30500`. Rollback is one command, so that residual risk was accepted rather
than chased.

## The change

```bash
ufw --force delete allow 30500/tcp     # removed both the v4 and v6 rules
```

**Deliberately unchanged**, per the narrow-security-PR rule: the `registry-service` Service (still
`NodePort`, still port 30500), its namespace (`default`), the PV/PVC and `hostPath /mnt/registry`,
the `registry:2` image, the TLS model, the secret names, and the credentials.

Only the *public* path was closed. The NodePort still exists and is still reachable from inside the
node; it is simply no longer exposed to the internet.

## Verification — 2026-07-31

| Check | Before | After |
|---|---|---|
| `http://88.99.149.31:30500/v2/` | `401` (reachable) | **`000`** (closed) |
| `https://registry.adiwave.com/v2/` | `401` | **`401`** (unchanged, auth enforced) |
| Real image pull — `veracrm-bff` pod deleted and recreated | — | **`1/1 Running` in 72s, no `ImagePullBackOff`** |
| `adiwave.com` · `vera.adiwave.com` · `registry.adiwave.com` | 200 | **200** |
| `portal.adiwave.com` | 307 | **307** |
| Stripe webhook | 400 (backend reached) | **400** |

The image pull is the load-bearing check: a passing `curl` only proves the endpoint answers, whereas
deleting a running pod forces kubelet to authenticate and fetch through the TLS path for real.

## Rollback

```bash
ufw allow 30500/tcp
```

Immediate and complete. The Service, storage and credentials were never touched, so there is nothing
else to restore.

## Follow-ups, deliberately not bundled here

- **Kubernetes API `:6443` is still open to the internet** — needs a proven administrative access
  path (allowlist, VPN or bastion) established *before* the ufw change, or it locks out cluster
  administration.
- The registry Service could become `ClusterIP` now that no external consumer uses the NodePort, but
  that is a design change and belongs in the registry ownership-transfer PR, not a security fix.
- `registry:2` remains an unpinned tag with no recorded digest.
- `hostPath` storage is still node-pinned, unreplicated and unbacked-up, with
  `REGISTRY_STORAGE_DELETE_ENABLED=true` and no garbage-collection history.

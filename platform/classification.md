# Classification: every tracked file under `sample-shop/k8s/hetzner/platform/`

**Date:** 2026-07-31 · **Method:** file contents read, each claim checked against the live cluster
**Result:** 2 files imported · 2 left in place · 1 superseded

Five files are tracked in that directory. Each is classified as shared platform configuration,
Granite-only, system-owned/unresolved, or documentation.

| File | Class | Action |
|---|---|---|
| `traefik-values.yaml` | **shared platform** | imported → `platform/traefik/values.yaml` |
| `cluster-issuer.yaml` | **shared platform** (issuer only) | imported → `platform/cert-manager/clusterissuer-letsencrypt-prod.yaml` |
| `coredns-custom.yaml` | **system-owned mechanism, Granite-only content** | **left in place** — provenance unresolved |
| `coredns-custom-example.yaml` | same, template | **left in place** |
| `OWNERSHIP.md` | documentation | left in place; superseded by this repository |

---

## Imported

### `traefik-values.yaml` → `platform/traefik/values.yaml`

Cluster-scoped by effect: one `hostNetwork` DaemonSet owns the node's `:80`/`:443` for **veracrm,
granite, me-funnel and the registry**. Nothing about it is Granite-specific.

Three-way equality proven at import:

```
source file  ==  imported copy    parsed YAML identical (1356 chars), 63 non-comment lines exact
imported copy ==  live Helm release  `helm get values traefik -n traefik`, canonically identical
```

Only comment lines were added. No value, hostname, namespace, port, secret reference or version
differs.

### `cluster-issuer.yaml` → `platform/cert-manager/clusterissuer-letsencrypt-prod.yaml`

Cluster-scoped, and the **only** `ClusterIssuer` on the cluster. All 17 `Certificate` objects
across `veracrm`, `granite`, `me-funnel` and `default` are issued by it, all `Ready=True`.

**This is the issuer, not the controller.** The cert-manager installation (Helm release
`cert-manager`, revision 1, chart `cert-manager-v1.21.0`) has no established installing repository.
Importing this manifest does **not** migrate cert-manager; that is a separate transfer.

#### Cross-tenant coupling found during classification

The live solver — unchanged in the import — resolves ACME challenges through a **Granite-owned**
Gateway:

```yaml
solvers:
  - http01:
      gatewayHTTPRoute:
        parentRefs:
          - name: granite-gateway
            namespace: granite
            kind: Gateway
```

So certificate renewal for **every** tenant depends on an object owned by one tenant. It works
today — all 17 certificates issued successfully, including `adiwave.com`, `me.adiwave.group` and
`registry.adiwave.com` — but the dependency is invisible from any consuming repository, which is
exactly the class of hidden coupling this repository exists to surface.

```
renewals begin   2026-09-20 (earliest: adiwave.com, granite-security.org, registry, sichocolate.com)
current expiry   2026-10-20 .. 2026-10-25
```

Not urgent, and deliberately **not changed here** — copying exactly is the point, and re-pointing a
solver is a behavioural change. But `granite-gateway` must not be renamed or deleted without
re-pointing this solver first, or renewals fail silently for all tenants until certificates expire.

---

## Left in place

### `coredns-custom.yaml` and `coredns-custom-example.yaml`

**Not imported**, for two independent reasons — either alone would be sufficient.

**The mechanism is system-owned.** The file's own comment states it: kubeadm/Kubespray clusters
auto-import any ConfigMap named `coredns-custom` in `kube-system`, because the Corefile has
`import /etc/coredns/custom/*.override` baked in. The ConfigMap exists live in `kube-system`.
Kubespray's ownership of CoreDNS has not been disproven, and absorbing a Kubespray-owned resource
because a copy happens to sit in an application repository is precisely the mistake this migration
must avoid.

**The content is Granite-only.** It is split-horizon DNS for `granite-security.org` and
`sichocolate.com`, pointing them at the in-cluster Traefik Service so Granite backends resolve
their own OIDC issuer internally instead of hairpinning through Cloudflare. No other tenant appears
in it. Shared *mechanism*, tenant-specific *content* — which makes it a poor fit for either
repository as it stands.

**Recorded as unresolved.** Resolving it means establishing whether Kubespray manages CoreDNS on
this cluster, then deciding whether the platform repository should own a shared `coredns-custom`
into which each tenant contributes entries. Neither belongs in a pre-demo import.

### `OWNERSHIP.md`

Documentation added to sample-shop to stop the platform files being deleted prematurely. It has
done its job and stays until the source directory is removed at cutover. Its content is superseded
by this repository's `archdesign/` and `platform/README.md`.

---

## Not moved, and not candidates

Confirmed Granite-only, consumed exclusively by namespace `granite`, and correctly staying in
sample-shop: `Gateway/granite-gateway`, all Granite HTTPRoutes, Granite Services and workloads,
Granite Kafka and database resources, and the Granite Argo CD Application definition.

## References to the old paths, for the cutover PR

Nothing in this repository references the sample-shop paths except as documented provenance.

Within sample-shop, the files referencing `k8s/hetzner/platform/...` paths, enumerated rather than
assumed:

```
docs/archive/aws/instructions.md                 documentation (archived)
docs/archive/observability/observability.md      documentation (archived)
docs/instructions/install.md                     documentation -- install procedure
k8s/hetzner/cloudify.md                          documentation -- install procedure
k8s/hetzner/sichocolate.md                       documentation -- overlay switching
plans/plan.md                                    documentation
k8s/hetzner/app/config-patch.yaml                comment reference only
k8s/hetzner/app-multi/gateway.yaml               comment reference only
k8s/hetzner/app-chocolate/gateway.yaml           comment reference only
k8s/hetzner/platform/*                           the files themselves
```

**No manifest depends on these paths functionally.** The three YAML hits are comments. The Gateways
bind the issuer **by name**, not by file path:

```
k8s/hetzner/app/gateway.yaml:19          cert-manager.io/cluster-issuer: letsencrypt-prod
k8s/hetzner/app-multi/gateway.yaml:19    cert-manager.io/cluster-issuer: letsencrypt-prod
k8s/hetzner/app-chocolate/gateway.yaml:13 cert-manager.io/cluster-issuer: letsencrypt-prod
```

So the file move cannot break certificate issuance — the binding is a cluster-scoped object name,
which is unchanged.

These references are updated in the deletion PR, not now: while the source files remain
authoritative, documentation pointing at them is still correct.

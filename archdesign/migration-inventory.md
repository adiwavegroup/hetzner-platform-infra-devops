# Shared-platform migration inventory

**Compiled:** 2026-07-31 · **Method:** read-only discovery via node-local `kubectl`
**Status:** inventory only — **no live change has been made**

This is the evidence base for moving shared infrastructure into
`adiwavegroup/hetzner-platform-infra-devops`. Nothing here has been migrated. Every row records
what is *actually running*, established from the cluster rather than from any repository's claim
about itself.

## Classification rule applied

A resource belongs to the platform repository when **any** of these hold: it is cluster-scoped;
used by more than one tenant; controls shared ingress, certificates, registry, observability or
GitOps; its failure affects more than one application; or it exposes a platform service such as
Argo CD, Grafana or Vault.

It stays with an application when it is namespace-local and consumed only by that application.

## Live cluster facts

```
Argo CD Applications        12, all Synced/Healthy at time of compilation
GatewayClass                traefik -> traefik.io/gateway-controller
Gateways                    default/registry-gateway · granite/granite-gateway
                            me-funnel/me-gateway · veracrm/veracrm-gateway
```

Helm releases, from `helm list -A` (jq 1.8.2 and helm v4.2.3 were installed on the node during
compilation, so this is the CLI's own record rather than an inference from release secrets):

```
NAME          NAMESPACE     REV  CHART                 APP VERSION  UPDATED
cert-manager  cert-manager  1    cert-manager-v1.21.0  v1.21.0      2026-07-21 17:33 CEST
traefik       traefik       2    traefik-41.0.2        v3.7.6       2026-07-21 17:27 CEST
```

Only these two components are Helm-managed. Everything else is either an Argo CD Application or a
hand-applied manifest.

---

## A. Shared components — migrate to the platform repository

### A1. Traefik — **highest blast radius, move LAST**

| | |
|---|---|
| Live | namespace `traefik`, Helm release `traefik` **revision 2**, chart `traefik-41.0.2`, app `v3.7.6` |
| Workload | `DaemonSet/traefik`, `hostNetwork`, binds node `:80`/`:443` |
| Current source | `Granite-Security/sample-shop` → `k8s/hetzner/platform/traefik-values.yaml` |
| Argo CD managed | **No** |
| Target | `platform/traefik/` |
| Consumers | **veracrm, granite, me-funnel, registry** — every public hostname |
| Risk | Only one controller can exist. Two reconcilers = a fight over one port binding on a single-node cluster. A mistake takes down every host at once. |
| Prerequisites | Phases 1–4 complete; exact chart version and values captured from the live release; every consumer's acceptance test defined *before* transfer |
| Rollback | Re-apply the previous Helm values from the release secret; keep the sample-shop file until proven |
| Deletion eligibility | **Not eligible.** `infrastructure-ownership.yaml` still records `currentOwner: sample-shop/...`, `status: migration-required` |

**Verified: the repository file matches what is deployed.** The release is at revision 2, so the
sample-shop file could easily have drifted from it. It has not. `helm get values traefik -n traefik`
compared against `k8s/hetzner/platform/traefik-values.yaml`, canonically normalised (recursive key
sort, so ordering differences cannot mask or fabricate a diff):

```
25 keys live · 25 keys in file · 0 live-only · 0 file-only · 0 differing values
canonical form IDENTICAL (1354 chars both sides)
```

This materially de-risks Phase 5: the file is a faithful starting point, not a guess. It does **not**
remove the requirement to reconstruct from the live release — verify the equality again immediately
before the transfer, because it is a fact about today, not a guarantee.

No credential-like values appear in the deployed values (checked for password/token/secret/apikey
patterns: zero matches), so this comparison was safe to run and record.

### A2. cert-manager

| | |
|---|---|
| Live | namespace `cert-manager`, Helm release `cert-manager` revision 1, chart `cert-manager-v1.21.0`, app `v1.21.0` |
| Current source | **UNKNOWN** — release exists, installing repository never established |
| Argo CD managed | No |
| Target | `platform/cert-manager/` |
| Consumers | every public hostname across all four Gateways |
| Risk | Certificate objects are **generated and owner-referenced to Gateways**, so they exist in no repository. Adoption must not recreate them — re-issuance risks Let's Encrypt rate limits. |
| Prerequisites | Provenance established; `letsencrypt-prod` ClusterIssuer preserved byte-for-byte |
| Rollback | Helm rollback to the recorded revision |
| Deletion eligibility | Not eligible — nothing to delete; provenance must be *established*, not transferred |

Current certificate expiries (all comfortably distant, so there is no time pressure):

```
adiwave.com          Oct 20 16:48:50 2026 GMT
vera.adiwave.com     Oct 20 16:48:47 2026 GMT
portal.adiwave.com   Oct 20 17:05:11 2026 GMT
auth.adiwave.group   Oct 21 10:35:43 2026 GMT
```

### A3. Registry

| | |
|---|---|
| Live | namespace `default`, `Deployment/registry`, image `registry:2` (unpinned tag, digest unrecorded) |
| Service | `registry-service`, NodePort 30500 — **public firewall path already closed** |
| Storage | `hostPath /mnt/registry`, PV/PVC, Retain |
| Routing | `Gateway/registry-gateway`, TLS terminated at Traefik, plain HTTP behind it |
| Current source | manual `kubectl apply` — no repository |
| Target | `platform/registry/` |
| Consumers | veracrm (7 pods), me-funnel, CI push |
| Risk | Adoption while CI pushes could disrupt image pulls. `hostPath` is node-pinned and unbacked-up. |
| Prerequisites | Adopt **exactly as running** — no namespace move, no ClusterIP change, no TLS change, no storage redesign, no GC |
| Rollback | Re-apply exported manifests; storage untouched throughout |
| Deletion eligibility | N/A — no old source file exists to delete |

### A4. Global observability

| | |
|---|---|
| Live | namespace `infra-global-observability`, 6 Argo CD Applications |
| Current source | **`adiwavegroup/vera`** (values) + upstream chart repos — multi-source Applications |
| Target | `platform/observability/` |

Exact chart versions, from the live Applications:

```
observability-kps              kube-prometheus-stack  87.19.1   prometheus-community
observability-loki             loki                    7.1.0    grafana
observability-tempo            tempo                   1.24.4   grafana
observability-alloy            alloy                   1.11.0   grafana
observability-veracrm-grafana  grafana                10.5.15   grafana
observability-granite-grafana  grafana                10.5.15   grafana
```

| | |
|---|---|
| Consumers | veracrm and granite dashboards; `grafana.adiwave.group`, `grafana.granite-security.org` |
| Risk | Lowest of the shared set — no ingress-path dependency for other tenants. Good first real transfer. |
| Prerequisites | Values files moved with chart versions **pinned unchanged** |
| Rollback | Point the Applications back at the vera repo |
| Deletion eligibility | Eligible once platform Applications reconcile and both Grafanas pass acceptance |

### A5. Argo CD itself

| | |
|---|---|
| Live | namespace `argocd`, **v3.4.5** coherent across all five components |
| Current source | bootstrap by hand; ApplicationSet CRD vendored at `bootstrap/argocd/v3.4.5/` |
| Argo CD managed | **No** — not self-managed |
| Target | `platform/argocd/` |
| Consumers | all 12 Applications, therefore every tenant |
| Risk | Self-management can lock you out of the tool needed to fix it. Requires documented, *tested* bootstrap recovery first. |
| Deletion eligibility | Not eligible until bootstrap recovery is proven |

### A6. Platform-service routes currently in tenant repositories

These live in the `veracrm` namespace and are owned by `adiwavegroup/vera` → `infra/k8s`, but they
expose **platform** services:

```
HTTPRoute/veracrm-argocd    -> argocd.adiwave.group    (Argo CD)
HTTPRoute/veracrm-grafana   -> grafana.adiwave.group   (shared Grafana)
HTTPRoute/veracrm-vault     -> vault.adiwave.group     (Vaultwarden)
HTTPRoute/veracrm-status    -> status.adiwave.group    (status board)
```

Namespace-local by object, platform by function. Flagged for ownership review; **no change proposed
before the other phases land**, since moving a route means moving the hostname's blast radius.

---

## B. Stays with the tenant

**`adiwavegroup/vera`** — workloads in `veracrm`; Services; app ConfigMaps and Secret references;
`infra/platform` (Postgres, Kafka, OpenBao, OTel collector — consumed only by veracrm);
`infra/vault`; veracrm-only domain routes and `Gateway/veracrm-gateway`; app dashboards; app CI/CD.

**`Granite-Security/sample-shop`** — workloads in `granite`; Services and app config;
`Gateway/granite-gateway` and granite HTTPRoutes; granite databases/Kafka; granite domains and
redirects; app dashboards.

> `infra/vault` (Vaultwarden) is a human password manager, arguably a platform service. Left with
> vera for now: single-namespace, no other tenant depends on it. Revisit after Phase 6.

---

## C. Do NOT absorb

`kube-system` (Kubespray-owned) · Calico · CoreDNS · kube-proxy · `local-path-storage` until
provenance is verified · dormant Rook/Ceph (**parked by business decision** pending 20 paying
customers — not abandoned; teardown needs its own destructive-change plan) · generated
`Certificate` objects (owner-referenced, exist in no repository) · tenant workloads that merely
share the cluster.

One flagged anomaly, unrelated to migration: the **`me-funnel`** Application tracks
`targetRevision: develop`, while every other Application tracks `main`. Worth a decision, not part
of this migration.

---

## D. Ordering rationale

```
1 foundation      structure, root Application, AppProjects, validation   no live adoption
2 observability   lowest blast radius, already GitOps -- proves the pattern
3 registry        self-contained; public path already closed
4 cert-manager    must precede Traefik: certificates are Gateway-referenced
5 Traefik         LAST -- one controller, host ports, every hostname
6 Argo CD         self-management only after tested bootstrap recovery
7 deletion        only after each component is actively reconciled and accepted
```

Observability first is deliberate: it is the only shared component already under Argo CD, so the
transfer exercises the mechanics with the smallest possible blast radius.

## E. Rules binding every transfer

1. One live resource has exactly **one** Git owner.
2. Never let two repositories or Applications reconcile the same resource.
3. **One component per PR.**
4. Export live state before reconstruction.
5. Reconstruct from live state and Helm release metadata — **not historical YAML alone**. For
   Traefik the two currently agree exactly (verified above), but that is an observation to re-check
   at transfer time, not a standing assumption.
6. Preserve exact versions, namespaces, names, hostnames, ports, storage, TLS behaviour and secret
   references during adoption.
7. Adoption must not redesign or improve anything.
8. `prune=false` during adoption.
9. No automated self-heal until ownership and rendered/live equivalence are proven.
10. Do not delete the old source until the platform source is actively reconciling and all
    consumers pass acceptance.
11. Every cross-tenant transfer needs evidence for **veracrm, granite, me-funnel and the registry** —
    not only the tenant that prompted it.
12. `kubectl diff` is supporting evidence. The owning Application's status and reconciliation
    behaviour are the acceptance criteria.

Rule 12 was learned the hard way: a Gateway API normalization produced a completely empty
`kubectl diff -k` while the Application stayed `OutOfSync` with three genuinely divergent routes.

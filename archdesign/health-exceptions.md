# Health exceptions — classified before any ownership transfer

**Verified:** 2026-07-30 · **Cluster:** `kubernetes-admin@cluster.local` · read-only

**No ownership transfer starts until every item here is classified.** Adopting a broken component
into GitOps makes the breakage look like a migration defect.

## Cluster topology — corrected

> **One physical Hetzner server running one Kubernetes node that performs both control-plane and
> workload duties.** Public and internal IP `88.99.149.31`.

Not "one master and one worker". Application pods schedule on `node1`, so the control-plane taint has
either been removed or every workload tolerates it.

**The cluster has no node-level high availability.** Rollout and voluntary-disruption controls remain
useful; they simply cannot protect against failure of the only node. An earlier draft of this document
overstated that as "protect nothing", which is wrong:

- **`maxSurge: 1` is still useful.** Kubernetes can start the replacement pod alongside the existing
  one on the same node, given spare CPU/memory, no port conflict and no exclusive volume attachment —
  so it genuinely reduces downtime during an ordinary rollout. It is not a multi-node-only feature.
  `maxUnavailable: 0` + `maxSurge: 1` remains a sound singleton strategy **after** verifying capacity
  and storage constraints. (Note Traefik deliberately uses the opposite — `maxSurge: 0`,
  `maxUnavailable: 1` — because a `hostNetwork` surge pod cannot bind the same ports.)
- **PodDisruptionBudgets still constrain voluntary evictions**, but do not protect against node
  failure, kernel panic, disk failure or power loss. On one node, a singleton with `minAvailable: 1`
  will also **block `kubectl drain` from completing** — worth knowing before a maintenance window.
- **Anti-affinity:** `requiredDuringSchedulingIgnoredDuringExecution` with two replicas leaves the second
  permanently Pending here; `preferredDuringSchedulingIgnoredDuringExecution` gives no benefit today
  but prepares manifests for the planned multi-node cluster. Neither supplies availability now.

---

## 1. Argo CD ApplicationSet controller — CrashLoopBackOff · ROOT CAUSE FOUND

```
argocd-applicationset-controller-fb85f95b8-5kxlh   0/1  CrashLoopBackOff   1597 restarts   7d22h
```

```
no matches for kind "ApplicationSet" in version "argoproj.io/v1alpha1"
if kind is a CRD, it should be installed before calling Start
$ kubectl -n argocd get applicationsets
  error: the server doesn't have a resource type "applicationsets"
```

**The ApplicationSet CRD was never installed.** This is an incomplete Argo CD installation — a partial
manifest set — not a runtime fault. The controller has crash-looped ~1,600 times waiting for a
resource type that does not exist, and no `ApplicationSet` objects exist that would need it.

Ordinary `Application` reconciliation is unaffected, which is why nobody noticed: the twelve existing
Applications work. But the installation is not healthy and its provenance is unknown.

**Decide during the Argo CD ownership PR, not before:** install the CRD (if ApplicationSets are wanted
— likely, given the planned tenants below), or scale the controller to zero (if they are not).
Adopting it in its current state would import a crash loop into GitOps.

**Classification:** incomplete install · blocks the Argo CD ownership transfer · not urgent for uptime.

## 2. Granite Kafka — 20 restarts · liveness, not OOM

```
kafka-8bb7bd9d9-t7bdf   1/1  Running   20 restarts (117m ago)   8d
Last State: Terminated · Reason: Error · Exit Code: 143
```

**Exit 143 is SIGTERM (128+15), not OOMKilled (137).** So the kubelet asked it to stop — the signature
of a **failing liveness probe**, not memory exhaustion. Roughly one restart every ~10 hours over 8
days.

**Classification:** application-owned (Granite Security namespace), **not** a platform component.
Needs a probe-timing or broker-startup review by that application's owner. Does not block platform
ownership transfer, but the platform migration must not be blamed for it later — hence recording it
now, with a timestamp, before anything moves.

## 3. Kernel discrepancy — RESOLVED, no conflict

| Source | Value |
|---|---|
| `uname -r` on host | `6.12.96+deb13-amd64` |
| `node.status.nodeInfo.kernelVersion` | `6.12.96+deb13-amd64` |

They now agree. The earlier `6.12.95` reading was a **stale node status**: `nodeInfo` is populated by
kubelet at startup and not refreshed on kernel upgrade, so the node advertised the pre-upgrade kernel
until kubelet restarted (`ActiveEnterTimestamp: Thu 2026-07-30 16:22:28 CEST`).

**Classification:** resolved. Worth remembering as a general trap — `kubectl get node` reports what
kubelet saw when it started, not what the host is running now.

## 4. Rook Ceph — intentionally dormant · PARKED BY DECISION, NOT ABANDONED

```
CephCluster rook-ceph   /var/lib/rook   Ready   "Cluster created successfully"   HEALTH_WARN
```

But every workload is scaled to **zero**:

```
ceph-csi-controller-manager     0/0
rook-ceph-crashcollector-node1  0/0
rook-ceph-exporter-node1        0/0
rook-ceph-mgr-a                 0/0
rook-ceph-mon-a                 0/0
```

The only pod present is a `Completed` `rook-ceph-osd-prepare-node1` job. **No monitor, manager, OSD or
operator is running.**

And nothing consumes it:

```
PVCs by storageClass:  local-path: 15 · local-path-retain: 1 · (none): 1
```

**Zero PVCs use Ceph.** All persistent storage is Rancher `local-path` — node-local, which matches the
single-node topology.

**Classification: intentionally dormant — deliberately on ice, NOT abandoned, and NOT for removal.**

This is a business decision, not drift. Ceph needs a real quorum to be worth running, and this is one
node with zero paying customers. The plan is explicit:

> Phase 1 goes live and reaches **20 paying customers** → the business plan funds **four additional
> machines, bringing the cluster to five nodes**. Until then the effort is not warranted.

**Five nodes is the chosen business and resilience target, not Ceph's technical minimum.** Rook
documents three or more nodes as the basis for a resilient production storage platform, and Ceph
recommends at least three monitors for production quorum — a majority of three tolerates one failure.
Five monitors tolerate two, which is a capacity and resilience choice rather than a requirement. An
earlier draft of this document stated five as the minimum; that was wrong, and it turned a business
threshold into an inaccurate technical constraint.

Monitor count, OSD placement, failure domains and replication policy will be designed **at that
milestone**, not inferred now.

So the workloads are scaled to zero on purpose and all storage runs on Rancher `local-path`, which is
the correct choice for a single node.

**Do not restart the operator, and do not tear it down.** An earlier draft of this document said
"removal must be CR-first" — that was wrong twice over: it should not be removed at all, and even if
it were, that phrasing understated the danger.

If teardown is ever genuinely wanted, it needs its own destructive-change plan first, covering at
minimum: `metadata.finalizers` on the `CephCluster` (**deleting a CR whose controller is absent leaves
it terminating indefinitely**, because finalizers require a controller to complete cleanup),
`spec.dataDirHostPath`, `spec.cleanupPolicy` — which **can deliberately erase host paths and wipe OSD
devices**, and must never be enabled just to clear a namespace — plus which disks were previously
touched, Helm and CRD ownership, `/var/lib/rook` contents, and rollback evidence.

**Action now: none.** Leave it dormant, revisit at the 5-machine milestone.

---

## Namespace ownership classification

### Shared platform → `adiwavegroup/hetzner-platform-infra-devops`

| Namespace | Component | Initial action |
|---|---|---|
| `argocd` | Argo CD | **Repair CRD first**, document bootstrap, then self-manage |
| `cert-manager` | cert-manager v1.21.0 | Adopt existing Helm release unchanged |
| `default` | Registry | Adopt unchanged; namespace move is a **later** PR |
| `infra-global-observability` | Prometheus/Grafana/Loki/Tempo/Alloy | Establish provenance, then adopt |
| `traefik` | Shared edge, chart 41.0.2 | Transfer Helm ownership |
| `local-path-storage` | Rancher local-path provisioner | **Identify installer** — likely Kubespray; verify before claiming |
| `rook-ceph` | Ceph, **intentionally dormant** | **No action** — parked until the 5-machine milestone |
| `infra-vault` | Vaultwarden | Decide: shared platform, or its own application? |

### Kubespray / bootstrap — **do not move under Argo CD**

`kube-system` — Calico, CoreDNS, kube-proxy, node-local DNS, control-plane static pods. Shared, but
owned by the cluster bootstrap. Adopting these into GitOps would put Argo CD in the path of its own
network and DNS.

### Application-owned

| Namespace | Application | Repository |
|---|---|---|
| `granite` | Granite Security | `Granite-Security/sample-shop` |
| `me-funnel` | Me Funnel | `listellodavide/girl-dates-invitation-funnel` |
| `veracrm` | VeraCRM | `adiwavegroup/vera` |

The Kafka and PostgreSQL instances inside `granite` and `veracrm` are **application-specific
infrastructure**, not shared platform services. Appearing in two namespaces is not an argument for
consolidating them — that would create exactly the cross-tenant coupling this repository exists to
remove.

## Planned tenants — the case for fixing ApplicationSet

Additional Argo CD-managed namespaces are expected for `tailwindating.com`, `calmapago.com` and
`graelyn.com`.

This changes the ApplicationSet decision in §1. Three more tenants, each needing the same
Gateway/HTTPRoute/certificate/namespace shape, is precisely the repetition ApplicationSets exist to
generate — so **installing the missing CRD is likely the right call rather than scaling the controller
to zero**. Decide it in the Argo CD ownership PR with the tenant roadmap in view.

It also sharpens three existing constraints:

- **One Traefik, one `:80`/`:443`, six tenants.** Its blast radius grows with every tenant, and it is
  still owned by an application repository.
- **`ufw allow 6443/tcp from Anywhere`** — every new tenant adds another reason the control plane
  should not be internet-reachable.
- **Registry `hostPath` on a single node** — more tenants, same unreplicated, unbacked-up volume.

## Inventory scope

`kubectl get pods -A` shows execution units, not the deployed system. `architecture.md` records
**stable objects only** — Deployment, StatefulSet, DaemonSet, Service, Gateway, HTTPRoute, namespace,
ports, ownership. **Pod names belong only in generated, timestamped runtime inventory**, never in
hand-maintained architecture text.

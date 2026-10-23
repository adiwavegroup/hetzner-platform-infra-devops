# GANDALF tenant onboarding

**Status:** namespace applied on 2026-10-21 (empty), everything else still a proposal · **Date:** 2026-10-20
**Owner repository for the workload:** `axiomsynergy/gandalf` (design: its ADR 011, `docs/adr/011-cd-gitops.md`)
**Public host:** `https://gandalf.axiomsynergy.ai/` · **Namespace:** `gandalf`

GANDALF is, per its owner's design in the private repository `axiomsynergy/gandalf` (`docs/architecture.md` and `docs/adr/011-cd-gitops.md` on its `main`; this repository cannot corroborate it), a Rust modular monolith (tonic gRPC API), a React static bundle, an Envoy gRPC-Web gateway and PostgreSQL with forced row-level security. Treat that stack as owner-supplied requirements, not as facts verified here. It is a new tenant on the shared single-node cluster described in [`archdesign/architecture.md`](../../archdesign/architecture.md). This document records what that needs from the shared platform and what stays with the application team, following [`archdesign/governance.md`](../../archdesign/governance.md).

## What was done, and what was not
| Item | State |
|---|---|
| `platform/tenants/gandalf/namespace.yaml` | written, reviewed in this PR, **not applied** |
| Live namespace `gandalf` | **created on 2026-10-21, see the execution record at the end.** History of the first attempt: **not created by this change; live existence not verified.** On 2026-10-20 `kubectl --context kubernetes-admin@cluster.local get ns` timed out against `88.99.149.31:6443`; the API is restricted to an administrator `/32` (see PR 0 in the [migration plan](platform-migration-pr-plan.md)). A login attempt through the owner's SSH alias for the node (`vera1`) was refused with `Permission denied (publickey)` because no key was loaded in the agent; no other user or key was tried and no firewall change was made. |
| Argo CD Application for GANDALF | not written, not applied |
| Registry namespace, credentials, DNS record, certificate | not touched |

The repository owner authorized creating the `gandalf` namespace on 2026-10-20 and chose node-local `kubectl` over SSH as the way to do it. Creation is blocked only by administrative access: the SSH key must be loaded (`ssh-add`) or the API allowlist updated.

## Which side owns what
Per the governance rules, namespace-scoped resources stay with the application team; shared components need consultation of both organizations.

| Concern | Owner | Change needed from the shared platform? |
|---|---|---|
| Namespace object `gandalf` | recorded here | yes, one new empty namespace (this PR) |
| Workloads, Services, ConfigMaps, NetworkPolicies, migration Job | GANDALF repository | no |
| `Gateway` and `HTTPRoute` for `gandalf.axiomsynergy.ai` | GANDALF repository | no new controller. They attach to the existing `GatewayClass` `traefik`, as the other tenants do |
| TLS certificate | cert-manager via the existing `letsencrypt-prod` ClusterIssuer, requested by Gateway annotation as the other tenants do | no change to the issuer. One more `Certificate` is generated |
| Traefik (`hostNetwork`, `:80`/`:443`) | shared | no change proposed. **Acceptance for this onboarding includes every existing tenant** |
| Image registry | shared | **requested by the GANDALF owner on 2026-10-20, pending joint review under `archdesign/governance.md`: a new registry `registry.axiomsynergy.ai` with a `gandalf/` repository namespace**, not the existing `registry.adiwave.com`. It is a new shared component: Deployment with a pinned image, storage with a stated capacity and backup owner (the existing registry uses an unbacked-up 200Gi `hostPath` volume), `Gateway` and certificate through `letsencrypt-prod`, DNS record, push and pull credentials, no NodePort. Separate PR in this repository, not part of this one |
| Argo CD | shared | **decision needed**: how a new tenant Application is registered. the migration plan proposes restricted `AppProject`s (PR 1); whether any exist today, and which project the existing tenant Applications use, is **not verified here** and needs a read-only inventory |
| DNS for `axiomsynergy.ai` | GANDALF owner | outside this repository. Not verified whether the record exists |
| Firewall, `:6443`, NodePorts | shared | none requested. GANDALF needs no new public port |

## Decisions needed before anything beyond the namespace
1. **Registry:** requested by the GANDALF owner (new `registry.axiomsynergy.ai`, see above); it needs the joint review before provisioning. The DNS record exists as of 2026-10-21 (see the execution record).
2. **Argo CD registration:** one `Application` (`gandalf`) in namespace `argocd`, applied by hand once, reading the GANDALF repository with a read-only deploy key. Proposal only. For orientation, an unverified external report: a comment in `adiwavegroup/vera` at commit `3d74c7693f829a5cd871f6a97432f00c99abed57`, file `infra/argocd/application.yaml`, says its read-only key is generated on the server and stays there. This repository does not document key generation, custody or permissions for any tenant, and that claim was not checked against the cluster, so the approach needs review. Confirm which `AppProject` applies once the inventory exists.
3. **Resource budget** for GANDALF on the shared node (no CPU or memory numbers are invented here). A `ResourceQuota` and `LimitRange` follow once agreed.
4. **PostgreSQL:** in-cluster (which storage class; the cluster has `local-path-storage` and `rook-ceph` namespaces) or external; backup owner; migration identity separate from the application role.
5. **Secrets:** `infra-vault` is Vaultwarden, a human password manager (`archdesign/health-exceptions.md`), not a workload secret store. OpenBao is part of VERA's tenant platform, "consumed only by veracrm" (`archdesign/migration-inventory.md`); reusing it would add a cross-tenant dependency and needs consultation first. For the first environment the simpler option is hand-applied Secrets in the `gandalf` namespace; decide with the platform owners.
6. **Network policy enforcement:** record whether the CNI enforces NetworkPolicy. It was listed as unverified in the original brief and is not established in this repository.

## Procedure when access is restored (not executed)
1. Confirm `kubectl --context kubernetes-admin@cluster.local get applications -n argocd` returns the expected 12 Applications, and record the state of every existing tenant (`veracrm`, `granite`, `me-funnel`): Applications Synced and Healthy, public hosts answering.
2. Check that the namespace does not already exist: `kubectl get ns gandalf` must answer `NotFound`. If it exists, **stop**: record its labels, annotations, creation time and contents, and consult the owners before any adoption. Do not apply over it.
3. `kubectl apply -f platform/tenants/gandalf/namespace.yaml --dry-run=server`, then without `--dry-run`. Keep the output: it must say `created`, and `kubectl get ns gandalf -o jsonpath='{.metadata.creationTimestamp}'` is recorded as the proof that this procedure created it.
4. Re-check step 1 unchanged, and `kubectl get ns gandalf --show-labels`.
5. Record the commands and outputs in this file under a dated heading.

**Rollback:** only for a namespace this procedure created (step 3 recorded `created`): `kubectl delete namespace gandalf` while it is empty. Never delete a namespace that existed beforehand, and do not delete it after workloads exist without the application owner.

## Acceptance for the namespace PR
```
manifest parses and passes --dry-run=server        (not yet run: no access)
12 Applications Synced/Healthy before and after
no change to Traefik, cert-manager, registry or Argo CD objects
```
Later GANDALF changes (Gateway, certificate, Application, registry credential) are separate PRs with their own evidence that covers every tenant attached to the shared `GatewayClass`.

## Not verified
Everything cluster-side: whether the namespace exists is unverified (this change does not create it), pod security admission support and the CNI's NetworkPolicy enforcement are unconfirmed, DNS and registry capacity are unconfirmed, and how a tenant Application is registered is undocumented here beyond the repositories named in `archdesign/architecture.md` §1.1 (the `me-funnel` Application reads a personal repository).

## Execution record, 2026-10-21
Executed by the repository owner (the command was typed by the owner in the Claude Code session, after the classifier blocked an agent-run apply) over SSH to the node `hetzner-adiwave-vera1` (certificate login as `root`), using the node-local `kubectl`.

1. Before: `kubectl get ns` listed 16 namespaces (`argocd`, `cert-manager`, `ctrlgrc-apps-dev`, `ctrlgrc-mesh-dev`, `default`, `granite`, `infra-global-observability`, `infra-vault`, `kube-node-lease`, `kube-public`, `kube-system`, `local-path-storage`, `me-funnel`, `rook-ceph`, `traefik`, `veracrm`). `kubectl get ns gandalf` answered `NotFound`.
2. `git show gandalf-devops:platform/tenants/gandalf/namespace.yaml | ssh root@100.116.242.84 'kubectl apply --dry-run=server -f -'` printed `namespace/gandalf created (server dry run)`.
3. The same pipe without `--dry-run` printed `namespace/gandalf created`. `kubectl get ns gandalf --show-labels` then showed `Active`, labels `app.kubernetes.io/part-of=gandalf`, `kubernetes.io/metadata.name=gandalf`, `pod-security.kubernetes.io/audit=restricted`, `pod-security.kubernetes.io/warn=restricted`. `creationTimestamp` is `2026-10-21T16:07:55Z`. `kubectl get all -n gandalf` reports no resources.
4. Applications afterwards, from `kubectl get applications -n argocd`: 15 exist (not the 12 this procedure expected). Synced/Healthy: `ctrlgrc-mesh-dev`, `granite`, `me-funnel`, `veracrm-openbao-injector`, `veracrm-platform`. `veracrm` is OutOfSync/Healthy. `ctrlgrc-apps-dev` is Synced/Degraded. Ten others report sync `Unknown`, health Healthy.

**Not established:** a snapshot before the change was not taken (step 1 of the procedure was skipped for Applications), so these states are what exists after the change, not proof that nothing moved. The `veracrm` OutOfSync and `ctrlgrc-apps-dev` Degraded states cannot be attributed to this change from this evidence; an empty namespace touches no other object, but that was not tested. The public hosts of the other tenants were not probed. `https://gandalf.axiomsynergy.ai/` has no certificate or route yet (a TLS verification failure is expected until a Gateway and Certificate exist).

DNS update from the GANDALF owner, 2026-10-21 (Cloudflare, DNS only): `gandalf.axiomsynergy.ai` and `registry.axiomsynergy.ai`, both A `88.99.149.31`. The registry host is **`registry.axiomsynergy.ai`**; the `.com` name used earlier in this document was wrong, the owner has no `.com` domain.

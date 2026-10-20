# GANDALF tenant onboarding

**Status:** proposal plus one manifest, nothing applied · **Date:** 2026-10-20
**Owner repository for the workload:** `axiomsynergy/gandalf` (design: its ADR 011, `docs/adr/011-cd-gitops.md`)
**Public host:** `https://gandalf.axiomsynergy.ai/` · **Namespace:** `gandalf`

GANDALF is, per its owner's design in the private repository `axiomsynergy/gandalf` (`docs/architecture.md` and `docs/adr/011-cd-gitops.md` on its `main`; this repository cannot corroborate it), a Rust modular monolith (tonic gRPC API), a React static bundle, an Envoy gRPC-Web gateway and PostgreSQL with forced row-level security. Treat that stack as owner-supplied requirements, not as facts verified here. It is a new tenant on the shared single-node cluster described in [`archdesign/architecture.md`](../../archdesign/architecture.md). This document records what that needs from the shared platform and what stays with the application team, following [`archdesign/governance.md`](../../archdesign/governance.md).

## What was done, and what was not
| Item | State |
|---|---|
| `platform/tenants/gandalf/namespace.yaml` | written, reviewed in this PR, **not applied** |
| Live namespace `gandalf` | **not created by this change; live existence not verified.** On 2026-10-20 `kubectl --context kubernetes-admin@cluster.local get ns` timed out against `88.99.149.31:6443`; the API is restricted to an administrator `/32` (see PR 0 in the [migration plan](platform-migration-pr-plan.md)). A login attempt through the owner's SSH alias for the node (`vera1`) was refused with `Permission denied (publickey)` because no key was loaded in the agent; no other user or key was tried and no firewall change was made. |
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
| Image registry | shared | **requested by the GANDALF owner on 2026-10-20, pending joint review under `archdesign/governance.md`: a new registry `registry.axiomsynergy.com` with a `gandalf/` repository namespace**, not the existing `registry.adiwave.com`. It is a new shared component: Deployment with a pinned image, storage with a stated capacity and backup owner (the existing registry uses an unbacked-up 200Gi `hostPath` volume), `Gateway` and certificate through `letsencrypt-prod`, DNS record, push and pull credentials, no NodePort. Separate PR in this repository, not part of this one |
| Argo CD | shared | **decision needed**: how a new tenant Application is registered. the migration plan proposes restricted `AppProject`s (PR 1); whether any exist today, and which project the existing tenant Applications use, is **not verified here** and needs a read-only inventory |
| DNS for `axiomsynergy.ai` | GANDALF owner | outside this repository. Not verified whether the record exists |
| Firewall, `:6443`, NodePorts | shared | none requested. GANDALF needs no new public port |

## Decisions needed before anything beyond the namespace
1. **Registry:** requested by the GANDALF owner (new `registry.axiomsynergy.com`, see above); it needs the joint review before provisioning. Still to confirm: the domain is `.com` while the product host is `gandalf.axiomsynergy.ai`, and who owns the DNS for it.
2. **Argo CD registration:** one `Application` (`gandalf`) in namespace `argocd`, applied by hand once, reading the GANDALF repository with a read-only deploy key. Proposal only: VERA's own `infra/argocd/application.yaml` (repository `adiwavegroup/vera`) states that its key was generated on the server and never left it; this repository does not document key generation, custody or permissions for any tenant, so the approach needs review. Confirm which `AppProject` applies once the inventory exists.
3. **Resource budget** for GANDALF on the shared node (no CPU or memory numbers are invented here). A `ResourceQuota` and `LimitRange` follow once agreed.
4. **PostgreSQL:** in-cluster (which storage class; the cluster has `local-path-storage` and `rook-ceph` namespaces) or external; backup owner; migration identity separate from the application role.
5. **Secrets:** `infra-vault` is Vaultwarden, a human password manager (`archdesign/health-exceptions.md`), not a workload secret store. OpenBao is part of VERA's tenant platform, "consumed only by veracrm" (`archdesign/migration-inventory.md`); reusing it would add a cross-tenant dependency and needs consultation first. For the first environment the simpler option is hand-applied Secrets in the `gandalf` namespace; decide with the platform owners.
6. **Network policy enforcement:** record whether the CNI enforces NetworkPolicy. It was listed as unverified in the original brief and is not established in this repository.

## Procedure when access is restored (not executed)
1. Confirm `kubectl --context kubernetes-admin@cluster.local get applications -n argocd` returns the expected 12 Applications, and record the state of every existing tenant (`veracrm`, `granite`, `me-funnel`): Applications Synced and Healthy, public hosts answering.
2. `kubectl apply -f platform/tenants/gandalf/namespace.yaml` (server-side validation first with `--dry-run=server`).
3. Re-check step 1 unchanged, and `kubectl get ns gandalf --show-labels`.
4. Record the commands and outputs in this file under a dated heading.

**Rollback:** `kubectl delete namespace gandalf` while it is empty. Do not delete it after workloads exist without the application owner.

## Acceptance for the namespace PR
```
manifest parses and passes --dry-run=server        (not yet run: no access)
12 Applications Synced/Healthy before and after
no change to Traefik, cert-manager, registry or Argo CD objects
```
Later GANDALF changes (Gateway, certificate, Application, registry credential) are separate PRs with their own evidence that covers every tenant attached to the shared `GatewayClass`.

## Not verified
Everything cluster-side: whether the namespace exists is unverified (this change does not create it), pod security admission support and the CNI's NetworkPolicy enforcement are unconfirmed, DNS and registry capacity are unconfirmed, and how a tenant Application is registered is undocumented here beyond the repositories named in `archdesign/architecture.md` §1.1 (the `me-funnel` Application reads a personal repository).

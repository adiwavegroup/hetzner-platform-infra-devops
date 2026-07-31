# Shared-platform governance

**Date:** 2026-07-31 · **Status:** active

Two organizations run workloads on one cluster. This defines who decides what, and — critically —
which repository the cluster actually reconciles from.

## Repositories

```
Canonical repository          adiwavegroup/hetzner-platform-infra-devops
Co-governed organizational copy   Granite-Security/hetzner-platform-infra-devops
Live Argo CD source           canonical Adiwave repository ONLY
```

**Co-governed, not co-owned in the deployment sense.** Granite Security participates fully in
decisions; the cluster reconciles from exactly one place. Two reconciling sources would produce
fights that look like drift and resolve nondeterministically — the failure this document exists to
prevent.

## Rules

1. **Both organizations review shared-platform decisions.** Neither can unilaterally change
   infrastructure the other depends on.
2. **One repository is authoritative for live reconciliation** — the canonical Adiwave repository.
3. **Granite proposals return to the canonical repository through PRs.** Discussion may happen in
   either copy; the merge that changes production happens in one.
4. **Canonical `main` is synchronized into the Granite copy.** The copy follows; it does not lead.
5. **Feature branches may diverge. The two `main` branches must not.** A divergent `main` in the copy
   makes it unclear which document describes production.
6. **No Argo CD Application may point at the Granite copy** for resources already owned by the
   canonical source.
7. **Emergency production changes are recorded in the canonical repository first** — or, when an
   incident genuinely forces action first, immediately afterwards. Platform state must never live
   only in operator history. *(This rule exists because it was broken once: the Argo CD
   ApplicationSet CRD was applied to production about an hour before its repository record existed.)*
8. **Cross-tenant changes require evidence covering every consuming application** — not only the one
   that prompted the change.

## Changes requiring consultation from both organizations

Anything below is shared and can break another tenant:

- **Traefik and the `GatewayClass`** — one `hostNetwork` controller owns `:80`/`:443` for every tenant
- **cert-manager** and the `letsencrypt-prod` ClusterIssuer
- **The shared registry** (`registry.adiwave.com`)
- **Argo CD** — bootstrap, upgrade, self-management, `AppProject`s
- **Platform firewall policy** — including `:6443` and any NodePort exposure
- **Shared observability**
- **Namespace or ownership transfers**

Everything namespace-scoped stays with its application team: workloads, Services, `Gateway`/`HTTPRoute`
resources, application NetworkPolicies, config, dashboards, DNS and routing contracts for their own
domains, and their own Kafka topics and event contracts.

## Acceptance evidence for a shared-platform change

**Every application attached to the shared `GatewayClass` is part of the acceptance test.** A change
is not proven because the tenant who made it still works.

Current tenants: `veracrm` (adiwave.com, adiwave.group) · `granite` (granite-security.org,
sichocolate.com) · `me-funnel` (me.adiwave.group). Planned: `tailwindating.com`, `calmapago.com`,
`graelyn.com`.

## Operational rule — what counts as proof

> **`kubectl diff` is supporting evidence. The owning Argo CD Application's comparison and
> reconciliation behaviour are the final acceptance criteria.**

Established the hard way on 2026-07-31: a Gateway API normalization produced a completely empty
`kubectl diff -k`, and `veracrm` remained `OutOfSync` regardless — Argo CD normalizes differently.
Three cross-namespace routes were still divergent. Had the empty diff been accepted as proof, the
change would have shipped looking complete.

The corollary, from the same week: a green dashboard is not a working signal. After the false drift
was removed, detection was proven by **injecting** harmless drift on a Git-owned inert field and
observing `OutOfSync` within 10s and self-heal within 20s. Removing false positives and restoring
signal are different achievements, and only the second one is worth having.

## Linked impact PRs

A shared-platform change must be visible in every affected application repository, even when no
application manifest changes. An impact PR may contain only documentation and validation evidence,
and should record: namespace, public hostnames, `GatewayClass`, registry dependency, expected
behaviour change, whether application manifests changed, and a link to the platform PR.

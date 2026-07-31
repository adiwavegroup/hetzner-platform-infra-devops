# Post-demo migration: one PR per component

**Status:** plan only · **Precondition:** the demo has finished
**Evidence base:** [`archdesign/migration-inventory.md`](../../archdesign/migration-inventory.md)

Nothing here may be executed before the demo. Each PR below is independently revertible and has its
own acceptance evidence. **Never combine two components in one PR.**

Acceptance for every PR is the same shape, and `kubectl diff` is never sufficient on its own:

```
owning Argo CD Application: Synced/Healthy
rendered == live for every adopted object
every consuming tenant verified, not only the one that prompted the change
rollback rehearsed, not merely described
```

---

## PR 0 — Durable administrative access  *(blocks every live transfer)*

**No live ownership transfer may begin until this lands.**

Workstation `kubectl` is currently blocked: the allowed `/32` was `195.231.47.36`, the workstation's
IPv4 egress is now `82.192.131.24`, and its current egress is IPv6 — whose global rule was removed
during the stage-1 API restriction. This was not theoretical; it happened **within a day** of the
`/32` being added.

SSH plus node-local `kubectl` is the working recovery path, and it is why the lockout was
inconvenient rather than critical. But a live migration must not begin while administrative access
depends on an address that can change without warning: the moment you most need `kubectl` is
mid-transfer, and that is exactly when a DHCP lease change would remove it.

Target: WireGuard or Tailscale, with `:6443` allowed only from the tunnel interface or subnet.
**Verify API certificate SAN compatibility before depending on a new address** — a SAN change is a
separate Kubespray-aligned operation, not part of a firewall PR.

**Acceptance:** `kubectl` works from the workstation over the tunnel; the temporary `/32` is removed
only *after* tunnel access is proven; SSH remains untouched as the fallback.

---

## PR 1 — Foundation (no live adoption)

**Adds:** `platform/` directory structure, root Application manifest (**not applied**), restricted
`AppProject`s, render/diff validation workflow.

**Touches live state:** nothing. No Application is applied; no resource is adopted.

Validation workflow must install its own dependencies explicitly rather than relying on the runner
image — the vera routing validator hid a broken parser for its entire existence precisely because a
dependency happened to be present everywhere it ran.

**Acceptance:** manifests render; CI green; `kubectl get applications` still returns 12.
**Rollback:** revert the PR — nothing was applied.

---

## PR 2 — Global observability

The first real transfer, chosen because it is the only shared component already under Argo CD and
has the smallest blast radius.

**Moves:** the 6 Applications and their values from `adiwavegroup/vera` to the platform repository,
with chart versions pinned **exactly** as deployed:

```
kube-prometheus-stack 87.19.1 · loki 7.1.0 · tempo 1.24.4
alloy 1.11.0 · grafana 10.5.15 (veracrm) · grafana 10.5.15 (granite)
```

**Transfer the existing Applications IN PLACE. Do not create duplicates.**

An earlier draft of this section said to create platform Applications and then remove the vera-side
ones. That is wrong, and wrong in the one way this whole migration is designed to prevent: between
those two steps, two Applications reconcile the same live objects. Corrected sequence:

```
copy values into the platform repository
→ render and compare offline
→ freeze the Vera source
→ update the EXISTING Applications' source references (in place)
→ hard refresh
→ verify Synced/Healthy
→ verify Grafana, Prometheus, Loki, Tempo, Alloy
→ remove the Vera files only after acceptance
```

Application **names, namespaces, chart versions, sync policies and destinations stay unchanged.**
Only `source.repoURL` / `path` moves. At no point do two reconcilers exist, because at no point
does a second Application exist.

**Acceptance:** `grafana.adiwave.group` and `grafana.granite-security.org` both load and render
existing dashboards; Prometheus targets unchanged; Loki and Tempo still ingest; **no pod restarts**.
**Rollback:** re-point the Applications at the vera repository.
**Deletion:** vera-side sources removed only after the above passes.

---

## PR 3 — Registry

**Adopts exactly as running.** Explicitly preserved: namespace `default`; `registry:2`; the NodePort
Service object (the *public firewall path* stays closed — the Service is unchanged); `hostPath
/mnt/registry`; Retain reclaim policy; Traefik TLS termination with plain HTTP behind it; secret
names; credentials.

**Forbidden in this PR:** namespace move, ClusterIP conversion, storage redesign, image pinning,
garbage collection, credential rotation. Each is a separate, later decision.

**Acceptance:** the load-bearing test is a **real image pull** — delete a running pod and confirm
kubelet re-pulls through the TLS path. A passing `curl` only proves the endpoint answers.
Plus: `https://registry.adiwave.com/v2/` still `401`; CI push succeeds.
**Rollback:** re-apply exported manifests; storage was never touched.

---

## PR 3b — ACME solver decoupling  *(issues #8 and #10)*

**Must land before cert-manager and Traefik ownership transfer.**

The only ClusterIssuer on the cluster resolves ACME challenges through `granite-gateway` in
namespace `granite`, so certificate renewal for **every** tenant depends on an object owned by one
tenant's application repository. Transferring cert-manager or Traefik while that is true compounds
the risk: both phases touch the same machinery.

Target: a minimal **platform-owned** Gateway or dedicated ACME listener.

Issue #10 (ACME contact email — currently a personal address receiving expiry warnings for every
hostname across both organizations) may ride in this same PR, since both change the same issuer,
**provided it does not trigger certificate recreation**.

**Acceptance:**

```
platform-owned Gateway/listener accepts ACME temporary HTTPRoutes
ClusterIssuer solver references the platform-owned Gateway
staging issuance succeeds
all existing Certificates stay Ready
existing notAfter values UNCHANGED during cutover   <- proves nothing was reissued
granite-gateway is no longer a certificate-renewal dependency
```

Renewals begin **2026-09-20**, so this has a real deadline, not just an ordering preference.

---

## PR 4 — cert-manager

**Establishes provenance first.** The installing repository was never recorded, so this PR begins by
reconstructing values from the live Helm release secret, not from any file.

Preserved: version `v1.21.0`, namespace `cert-manager`, `letsencrypt-prod` ClusterIssuer semantics.

**Certificates must not be recreated.** They are generated and owner-referenced to each Gateway, so
they exist in no repository; re-issuance risks Let's Encrypt rate limits. Adoption covers the
controller and issuer only.

**Acceptance:** every existing `Certificate` stays `Ready` with **unchanged `notAfter`** — an
unchanged expiry is the proof nothing was reissued. Renewal path verified against a staging issuer,
not production.
**Rollback:** Helm rollback to the recorded revision.

---

## PR 5 — Traefik  *(highest risk — last)*

Preserved: exactly **one** controller; namespace `traefik`; chart and version as deployed;
`hostNetwork` on `:80`/`:443`; `GatewayClass/traefik` and `controllerName`.

**Reconstruct from Helm release v2, not from the sample-shop file.** The release has been upgraded
once, so the repository file is not authoritative for what is running.

**Forbidden:** launching a second controller "to test"; changing `forwardedHeaders.trustedIPs` in
this PR; any overlap where both sample-shop and the platform repository reconcile Traefik.

**Acceptance — every tenant, no exceptions:**

```
veracrm    adiwave.com · www · vera · portal · auth.adiwave.group · status · grafana · argocd
granite    granite-security.org · sichocolate.com · media/s3/garage.granite-security.org
me-funnel  me.adiwave.group
registry   registry.adiwave.com (401)
webhooks   Stripe endpoint reachable, unsigned payload rejected 400
redirects  every http:// -> 301 https://, deep paths preserved
listeners  every Gateway listener still claimed (routing validator PASS, all namespaces)
```

**Rollback:** re-apply the previous Helm values from the release secret. Rehearse this **before**
merging, not after something breaks.

---

## PR 6 — Argo CD

Pinned bootstrap at **v3.4.5**, namespace `argocd`, plus the vendored ApplicationSet CRD already at
`bootstrap/argocd/v3.4.5/` with its recorded SHA256.

**Self-management only after bootstrap recovery is documented *and tested*** — restoring Argo CD
with Argo CD unavailable must be a rehearsed procedure, not a belief. No version change here; an
upgrade is a separate approved PR.

---

## PR 7 — Deletion

Only after each component above is actively reconciled from the platform repository and every
consumer has passed acceptance.

Per component: set `currentOwner` to the platform repository and `status: transferred` in
`infrastructure-ownership.yaml`; delete the old source; prove no references remain; keep the
rollback commit and exported manifests.

This is when `sample-shop/k8s/hetzner/platform/` is finally removed — and not before. That
directory currently holds the **only** record of the configuration terminating TLS for every public
hostname on the cluster.

---

## Ownership review, deferred deliberately

Four routes in `adiwavegroup/vera` → `infra/k8s` expose platform services
(`argocd`/`grafana`/`vault`/`status`). Namespace-local by object, platform by function. Moving a
route moves a hostname's blast radius, so this is reviewed **after** PR 5, not bundled into it.

## Not part of this migration

The `me-funnel` Application tracks `targetRevision: develop` while every other Application tracks
`main`. Flagged during discovery; needs a decision on its own.

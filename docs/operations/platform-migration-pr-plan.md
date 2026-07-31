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

**Sequence:** create platform Applications with `prune=false` and self-heal **off** → confirm they
report `Synced` against unchanged live objects → only then remove the vera-side Applications.
At no point may both sides reconcile the same object.

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

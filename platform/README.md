# `platform/` — canonical source for shared cluster configuration

Configuration used by **more than one Kubernetes tenant** lives here. Tenant repositories
(`adiwavegroup/vera`, `Granite-Security/sample-shop`) keep only what their own namespace consumes.

## Nothing in this directory is live yet

**No Argo CD Application targets this path.** Verified against the cluster: of the 12 Applications,
none reference this repository. Files here are canonical *copies*, established so the ownership
cutover is a controlled step rather than an improvisation.

Live state is still controlled by:

| Component | Actually controlled by |
|---|---|
| Traefik | the existing Helm release (`traefik`, ns `traefik`, revision 2) |
| ClusterIssuer | the object applied by hand from sample-shop |

Deleting the sample-shop originals now would remove the only source of truth for configuration
that terminates TLS for every public hostname on this cluster. They stay until cutover completes.

## Contents

```
platform/
├── traefik/
│   └── values.yaml                            Helm values, verified == live release
├── cert-manager/
│   └── clusterissuer-letsencrypt-prod.yaml    shared issuer (NOT the controller)
├── classification.md                          every file under the old directory, classified
└── README.md
```

## The rule that matters most

**One live resource has exactly one Git owner.** The dangerous state is two repositories
reconciling the same resource — for Traefik that means two controllers contending for the node's
`:80`/`:443`, which takes down every tenant at once.

Transition order, never overlapping:

```
now        sample-shop source exists · platform copy exists
           only the existing Helm release controls live state
cutover    freeze sample-shop source → transfer ownership in place → platform becomes sole source
after      verify every tenant → update the ownership ledger → delete the sample-shop source
```

## Adoption must not improve anything

Copies are verbatim. No upgrades, no image pinning, no namespace moves, no storage or TLS redesign,
no Cloudflare changes. Every one of those is a separate decision after ownership is settled — and
each would invalidate the equality proof that makes the cutover safe.

See [`../archdesign/migration-inventory.md`](../archdesign/migration-inventory.md) for what runs
where, and [`../docs/operations/platform-migration-pr-plan.md`](../docs/operations/platform-migration-pr-plan.md)
for the per-component sequence.

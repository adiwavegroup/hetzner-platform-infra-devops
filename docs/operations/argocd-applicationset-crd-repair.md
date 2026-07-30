# Argo CD ApplicationSet CRD repair

**Applied to production:** 2026-07-30 · **Status:** repaired and verified
**Scope:** install one missing CRD. Nothing else.

## The defect

`argocd-applicationset-controller` had been in `CrashLoopBackOff` for 7d22h with **1,615 restarts**:

```
no matches for kind "ApplicationSet" in version "argoproj.io/v1alpha1"
if kind is a CRD, it should be installed before calling Start
$ kubectl -n argocd get applicationsets
  error: the server doesn't have a resource type "applicationsets"
```

**The ApplicationSet CRD was never installed** — an incomplete Argo CD installation, not a runtime
fault. Only `applications.argoproj.io` and `appprojects.argoproj.io` existed.

Ordinary `Application` reconciliation was unaffected throughout, which is why it went unnoticed: the
twelve existing Applications kept working while a core controller crashed every ten seconds.

## Establishing the release — do not infer from one image

Every Argo CD component was checked, not just the crashing one, because a mixed-version installation
would make any single image a misleading source of truth:

```bash
kubectl -n argocd get deploy,statefulset \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

```
argocd-applicationset-controller   quay.io/argoproj/argocd:v3.4.5
argocd-notifications-controller    quay.io/argoproj/argocd:v3.4.5
argocd-repo-server                 quay.io/argoproj/argocd:v3.4.5
argocd-server                      quay.io/argoproj/argocd:v3.4.5
argocd-application-controller      quay.io/argoproj/argocd:v3.4.5
argocd-dex-server                  ghcr.io/dexidp/dex:v2.45.0          (bundled dependency)
argocd-redis                       public.ecr.aws/docker/library/redis:8.2.3-alpine  (bundled)
```

**Coherent release: Argo CD v3.4.5.** So the CRD comes from that exact tag — never `stable`, which
would trade a loud crash loop for a quiet version mismatch.

## Source and integrity

```
https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.5/manifests/crds/applicationset-crd.yaml
```

Vendored at `bootstrap/argocd/v3.4.5/applicationset-crd.yaml` (23,175 lines), with
`bootstrap/argocd/v3.4.5/SHA256SUMS`:

```
51f69883c692698fbcf3c82455c07c0f6413899ac9d96565a9e8395c0196f58d  applicationset-crd.yaml
```

Verify before applying:

```bash
cd bootstrap/argocd/v3.4.5 && sha256sum -c SHA256SUMS      # or: shasum -a 256 -c SHA256SUMS
```

## Procedure

**Server-side apply is required, not stylistic.** This CRD is ~23k lines and exceeds the
client-side `last-applied-configuration` annotation limit.

```bash
kubectl apply --server-side --dry-run=server -f bootstrap/argocd/v3.4.5/applicationset-crd.yaml
kubectl apply --server-side              -f bootstrap/argocd/v3.4.5/applicationset-crd.yaml
```

### `Established` needs a retry — this is a real trap

Immediately after apply, `kubectl wait` fails on a **successful** apply, because the API server has
not yet populated `.status`:

```
error: .status.conditions accessor error: <nil> is of the type <nil>, expected []interface{}
```

That is a race, not a failure, and it will make an automated runbook report a phantom error. Use a
retry-safe form:

```bash
for i in $(seq 1 12); do
  kubectl get crd applicationsets.argoproj.io \
    -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null | grep -q True && break
  sleep 5
done
kubectl wait --for=condition=Established crd/applicationsets.argoproj.io --timeout=60s
```

Then:

```bash
kubectl -n argocd rollout status deployment/argocd-applicationset-controller --timeout=120s
kubectl -n argocd get pods
kubectl -n argocd get applicationsets
```

## Recovery evidence — 2026-07-30

| Check | Result |
|---|---|
| Component release coherence | all five Argo CD containers on `v3.4.5` |
| Server-side dry run | `serverside-applied (server dry run)` |
| CRD condition | `NamesAccepted=True Established=True` |
| Resource type served | `kubectl get applicationsets` → `No resources found` (was: type does not exist) |
| Controller rollout | `successfully rolled out`, **1/1 Running** |
| Controller log | `Starting Controller` · `Starting workers, worker count 10` |
| Restart count | **frozen at 1615** across 135s of sampling — previously climbing every ~10s |
| ApplicationSets created | **zero** |
| Existing Applications | **all 12 Healthy**, unchanged |

The three `OutOfSync` Applications (`granite`, `veracrm`, `veracrm-observability`) are the
**pre-existing CRD-defaulted-field drift**, untouched by this work and tracked separately. They were
`OutOfSync` before and remain so; all are Healthy.

## Deliberately out of scope

No Argo CD upgrade · no self-management · **no `ApplicationSet` created** · no tenant templates ·
no `AppProject`s · no ownership transfer · no changes to existing Applications · no pruning changes.

Each belongs to its own PR with its own rollback boundary.

## Rollback

```bash
kubectl delete crd applicationsets.argoproj.io
```

Safe **only while zero `ApplicationSet` resources exist** — deleting a CRD deletes every custom
resource of that kind. Verify `kubectl get applicationsets -A` is empty first. The outcome of
rollback is the previous state: the controller returns to `CrashLoopBackOff`, and ordinary
`Application` reconciliation continues unaffected.

Once the first `ApplicationSet` is created, this rollback is **no longer safe** and the CRD must be
treated as load-bearing.

## Note on ordering — the gap this document closes

The production apply happened **before** this repository record existed. That inverted the intended
order and briefly recreated the exact problem this repository exists to solve: platform state living
only in operator history. The Git counterpart should lead, or at minimum accompany, the change.

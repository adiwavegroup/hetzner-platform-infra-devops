# Kubernetes node hostname: `kubernetes.io/hostname`

Status: **Verified 2026-11-20** against the live cluster.

## Summary

The single control-plane node has two different names that must not be confused:

| Name | Value | Where it comes from |
| --- | --- | --- |
| OS hostname | `hetzner-adiwave-vera1` | `hostname` on the Debian host |
| Kubernetes node name | `node1` | `kubectl get nodes` (NAME column) |
| `kubernetes.io/hostname` label | `node1` | node label, read by scheduling and `nodeAffinity` |

Anything that selects this node by `kubernetes.io/hostname` (`nodeSelector`, `nodeAffinity`, PV `nodeAffinity`) must use **`node1`**, not the OS hostname.

## Why the names differ

The kubelet sets `kubernetes.io/hostname` from its own node name at registration, not from the OS hostname. The node was registered as `node1`, so the label is `node1`.

Changing the Kubernetes node name is not a small edit: it means re-registering the node, which disrupts every public hostname on this single node. Do not rename the node to match the OS hostname. Fix the manifests instead.

## Where this matters

- `platform/traefik/access-logs-storage.yaml`: the PersistentVolume `nodeAffinity` must be `node1`. The previous value `hetzner-adiwave-vera1` matched no node, which would leave the access-log PVC unbound and the Traefik pod Pending.

## Verify

Run on the node (as root):

```sh
hostname                                              # OS name: hetzner-adiwave-vera1
kubectl get nodes                                     # Kubernetes node name: node1
kubectl get node node1 -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}{"\n"}'   # node1
```

Re-run these after any node re-install or kubelet change. If the label ever differs from `node1`, update `access-logs-storage.yaml` to the new label value before applying.

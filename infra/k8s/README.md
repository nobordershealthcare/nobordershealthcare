# infra/k8s — Kubernetes Manifests

## Files

| File | Resources |
|---|---|
| `storageclass-gp3.yaml` | `StorageClass` gp3 (AWS EBS CSI) |
| `namespace.yaml` | `Namespace` noborders · `PeerAuthentication` STRICT (namespace-wide) · `NetworkPolicy` anonymizer port isolation |
| `redis-cluster.yaml` | `ConfigMap` redis.conf · headless `Service` · `StatefulSet` 3 masters, no persistence |
| `anonymizer-deployment.yaml` | `ServiceAccount` · `ConfigMap` vault-agent.hcl · `Deployment` 3 replicas |
| `anonymizer-hpa.yaml` | `HorizontalPodAutoscaler` min 3 / max 20 |
| `scylladb-statefulset.yaml` | headless `Service` · `StatefulSet` 3 nodes, 100Gi gp3 per node |
| `gatekeeper-deployment.yaml` | `ServiceAccount` · `Deployment` 2 replicas · `PeerAuthentication` STRICT |

---

## Before `kubectl apply` — 3 prerequisites

**1. `vault-agent-templates` ConfigMap**
The anonymizer Vault Agent init container expects two Consul Template files:

```bash
kubectl create configmap vault-agent-templates \
  --from-file=aes-key.tpl=./vault/templates/aes-key.tpl \
  --from-file=redis-acl.tpl=./vault/templates/redis-acl.tpl \
  -n noborders
```

Each `.tpl` file renders a secret from Vault KV to `/secrets/` on the pod's tmpfs volume.

**2. AWS EBS CSI driver installed**
The `gp3` StorageClass requires the EBS CSI driver. Verify:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

If missing, install via the cluster add-on (EKS) or Helm before applying StorageClass.

**3. Node topology labels match your region**
ScyllaDB uses `requiredDuringSchedulingIgnoredDuringExecution` nodeAffinity — pods will
not schedule if the label values don't match. Check first (see section below).

---

## Deploy order

```bash
# 1. StorageClass first — ScyllaDB PVCs reference it at creation time
kubectl apply -f infra/k8s/storageclass-gp3.yaml

# 2. Namespace + policies before any workloads
kubectl apply -f infra/k8s/namespace.yaml

# 3. Redis before anonymizer (anonymizer reads Redis on startup)
kubectl apply -f infra/k8s/redis-cluster.yaml
kubectl rollout status statefulset/redis-cluster -n noborders

# 4. Anonymizer + HPA
kubectl apply -f infra/k8s/anonymizer-deployment.yaml
kubectl apply -f infra/k8s/anonymizer-hpa.yaml
kubectl rollout status deployment/anonymizer -n noborders

# 5. ScyllaDB (slow to reach Ready — allow 3-5 min per node)
kubectl apply -f infra/k8s/scylladb-statefulset.yaml
kubectl rollout status statefulset/scylladb -n noborders

# 6. Gatekeeper last — depends on anonymizer being reachable
kubectl apply -f infra/k8s/gatekeeper-deployment.yaml
kubectl rollout status deployment/gatekeeper -n noborders
```

---

## Redis cluster init (one-time, after StatefulSet is Running)

All three pods must be in `Running` state before running this:

```bash
kubectl exec -it redis-cluster-0 -n noborders -- \
  redis-cli --cluster create \
    redis-cluster-0.redis-cluster.noborders.svc.cluster.local:6379 \
    redis-cluster-1.redis-cluster.noborders.svc.cluster.local:6379 \
    redis-cluster-2.redis-cluster.noborders.svc.cluster.local:6379 \
    --cluster-replicas 0
```

Type `yes` at the confirmation prompt. Verify afterwards:

```bash
kubectl exec -it redis-cluster-0 -n noborders -- redis-cli cluster info | grep cluster_state
# expected: cluster_state:ok
```

**Re-init after full cluster restart**: because Redis uses `emptyDir` (no persistence),
`nodes.conf` is lost on pod restart. Re-run the init command any time all three pods
restart simultaneously. Single-pod restarts rejoin the cluster automatically via gossip.

---

## Node label check — verify before ScyllaDB deploy

```bash
kubectl get nodes --show-labels | grep -E 'topology.kubernetes.io/(region|zone)'
```

ScyllaDB `nodeAffinity` in `scylladb-statefulset.yaml` expects one of these region values:

| Cloud | Region label key | Values in manifest |
|---|---|---|
| AWS | `topology.kubernetes.io/region` | `eu-west-1`, `eu-west-2`, `eu-west-3` |
| GCP | `topology.kubernetes.io/region` | `europe-west1`, `europe-west2`, `europe-west4` |
| Azure | `topology.kubernetes.io/region` | `westeurope`, `northeurope` |

If your labels differ, edit `scylladb-statefulset.yaml` lines 37–41 before applying.
This constraint is a hard GDPR Art.44 requirement — pods must not schedule outside the EU.

---

## Operational notes

**`reclaimPolicy: Retain` is intentional.**
ScyllaDB PVCs use `Retain` rather than `Delete`. If a StatefulSet or PVC is deleted
(accidentally or during maintenance), the underlying EBS volume is preserved and can be
reattached. Changing this to `Delete` risks permanent data loss with no recovery path.
To actually decommission a node, manually delete the PV and EBS volume after confirming
the data is replicated to the remaining nodes.

**Anonymizer pod rotation at 10k requests.**
Pods carry the annotation `max-requests: "10000"`. This is read by the rotation
controller (to be implemented as a separate operator or CronJob). Until that controller
exists, pods are replaced only by normal rolling updates or HPA scale events.

**Redis ACL.**
`rename-command CONFIG ""` and `rename-command DEBUG ""` are set in `redis.conf`.
These commands are disabled at the Redis level, not just at the application ACL level,
as required by CLAUDE.md. Verify after init:

```bash
kubectl exec -it redis-cluster-0 -n noborders -- redis-cli CONFIG GET maxmemory
# expected: (error) ERR unknown command 'config'
```

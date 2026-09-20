# Multi-Cluster Kubernetes Observability — Phase 0

> **Single-cluster PoC** · Zero-instrumentation HTTP & network observability powered by [Grafana Beyla](https://grafana.com/docs/beyla/) (eBPF), Prometheus, and Grafana — running on a local K3s cluster.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Repository Layout](#repository-layout)
4. [Bring-Up (Step-by-Step)](#bring-up-step-by-step)
5. [Verify the Pipeline](#verify-the-pipeline)
6. [Generate Traffic](#generate-traffic)
7. [Open Grafana](#open-grafana)
8. [Tear-Down](#tear-down)
9. [Dashboard Panels](#dashboard-panels)
10. [Known Caveats & Limitations](#known-caveats--limitations)
11. [Roadmap](#roadmap)

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  K3s Cluster (single node)                                           │
│                                                                      │
│  namespace: demo                                                     │
│  ┌────────────┐  nginx proxy  ┌────────────┐  nginx proxy  ┌──────┐│
│  │  frontend  │ ────────────► │  backend   │ ────────────► │ auth ││
│  │ nginx:alpine│ :8080        │ nginx:alpine│ :8080        │http- ││
│  └────────────┘               └────────────┘               │echo  ││
│                                                             └──────┘│
│  namespace: beyla                                                    │
│  ┌──────────────────────────────────────────────────────┐           │
│  │  Beyla DaemonSet  (grafana/beyla:2.1.0)              │           │
│  │  · eBPF auto-discovers port 8080 across all hops     │           │
│  │  · Emits L4 network + L7 HTTP metrics per service    │           │
│  │  · Prometheus exporter → :9090/metrics               │           │
│  └──────────────────────────────────────────────────────┘           │
│                │                                                     │
│                │ pod-IP discovery (kubernetes_sd)                   │
│                ▼                                                     │
│  namespace: monitoring                                               │
│  ┌──────────────┐   PromQL   ┌──────────────┐                      │
│  │  Prometheus  │ ◄────────► │   Grafana    │                      │
│  │  v2.53.0     │            │  (latest)    │                      │
│  │  :9090       │            │  :3000       │                      │
│  │  cluster=    │            │              │                      │
│  │  cluster-01  │            │              │                      │
│  └──────────────┘            └──────────────┘                      │
│   NodePort 30900              NodePort 30300                        │
└──────────────────────────────────────────────────────────────────────┘
```

**Three-hop service chain:** `traffic-gen` → `frontend` (nginx) → `backend` (nginx) → `auth` (http-echo).  
Beyla captures L7 HTTP spans at each hop without any code changes.

Beyla runs in `system_wide` discovery mode due to a WSL2 kernel limitation in PID namespace resolution (`bpf_get_ns_current_pid_tgid`), which otherwise causes child container HTTP spans to be dropped. To prevent storing host-wide metrics, Prometheus uses `metric_relabel_configs` to drop non-demo namespaces (`kube-system`, `monitoring`), and Grafana dashboard queries are scoped to `service_namespace="demo"`. Additionally, `traffic-gen` runs as a self-healing `Deployment` that automatically survives node and K3s restarts.

**Key design choices:**

| Decision | Rationale |
|---|---|
| Beyla as DaemonSet | One pod per node; captures all host-PID traffic without touching app code |
| `hostPID: true` + `hostNetwork: true` | Required for eBPF to attach to host process namespaces |
| `memlock-init` initContainer | Raises `RLIMIT_MEMLOCK` to unlimited; K3s/containerd caps it at 64 MiB by default, which blocks eBPF map creation |
| Narrow ClusterRole RBAC | Beyla gets only `get/list/watch` on pods/services/nodes — no cluster-admin |
| Prometheus `external_labels: cluster: cluster-01` | Tags every metric with a cluster identity for Phase 1 remote_write federation |
| Provisioned ConfigMaps for Grafana | Dashboard and datasource survive Grafana restarts; no manual import needed |
| No Helm/kustomize | Plain Kubernetes YAML; easiest to understand, grep, and diff |

---

## Prerequisites

| Tool | Minimum version | Notes |
|---|---|---|
| [K3s](https://k3s.io/) | v1.28+ | `curl -sfL https://get.k3s.io \| sh -` |
| `kubectl` | matching cluster | Configured with `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` or symlinked to `~/.kube/config` |
| `curl` | any | Used by `verify.sh` |
| Linux kernel | **5.8+** | Required for the `BPF` capability and uprobe/kprobe attach used by Beyla |

> **WSL2 users:** After a WSL2 restart the node IP changes. Re-check it with:
> ```bash
> kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
> ```

---

## Repository Layout

```
multicluster-k8s/
├── beyla/
│   ├── namespace.yaml              # namespace: beyla
│   ├── clusterrole.yaml            # ServiceAccount + ClusterRole + ClusterRoleBinding
│   └── daemonset.yaml              # Beyla ConfigMap + DaemonSet
│
├── prometheus/
│   ├── namespace.yaml              # namespace: monitoring (shared with Grafana)
│   ├── rbac.yaml                   # ServiceAccount + ClusterRole + ClusterRoleBinding
│   ├── configmap.yaml              # prometheus.yml — scrape config + cluster=cluster-01 label
│   └── deployment.yaml             # Deployment + NodePort Service (:30900)
│
├── grafana/
│   ├── datasource-configmap.yaml   # Prometheus datasource (uid: prometheus)
│   ├── dashboard-provider-configmap.yaml
│   ├── dashboard-configmap.yaml    # Phase 0 dashboard — 4 panels (L4 bytes, req rate, latency, errors)
│   └── deployment.yaml             # Deployment + NodePort Service (:30300)
│
├── sample-apps/
│   ├── namespace.yaml              # namespace: demo
│   ├── auth.yaml                   # hashicorp/http-echo — leaf service ("Hello from auth")
│   ├── backend.yaml                # nginx:alpine proxy → auth:8080  (middle hop)
│   └── frontend.yaml               # nginx:alpine proxy → backend:8080 (entry hop)
│
└── scripts/
    ├── verify.sh                   # End-to-end health check (colour-coded pass/fail)
    └── traffic-gen.sh              # Runs an in-cluster curl loop to generate HTTP traffic
```

---

## Bring-Up (Step-by-Step)

Run every command from the **repo root**. Order matters — apply namespaces before workloads, RBAC before pods.

### 1 — Sample Applications

```bash
kubectl apply -f sample-apps/namespace.yaml
kubectl apply -f sample-apps/auth.yaml
kubectl apply -f sample-apps/backend.yaml
kubectl apply -f sample-apps/frontend.yaml

# Wait for all three to be ready
kubectl rollout status deployment/auth     -n demo
kubectl rollout status deployment/backend  -n demo
kubectl rollout status deployment/frontend -n demo
```

### 2 — Prometheus

```bash
kubectl apply -f prometheus/namespace.yaml
kubectl apply -f prometheus/rbac.yaml
kubectl apply -f prometheus/configmap.yaml
kubectl apply -f prometheus/deployment.yaml

kubectl rollout status deployment/prometheus -n monitoring
```

### 3 — Grafana Beyla (eBPF agent)

```bash
kubectl apply -f beyla/namespace.yaml
kubectl apply -f beyla/clusterrole.yaml
kubectl apply -f beyla/daemonset.yaml

kubectl rollout status daemonset/beyla -n beyla
```

> ⏱ The `memlock-init` initContainer takes ~5 s on first pull. If Beyla crashes with `permission denied` on eBPF map creation, verify your kernel is ≥ 5.8.

### 4 — Grafana

```bash
kubectl apply -f grafana/datasource-configmap.yaml
kubectl apply -f grafana/dashboard-provider-configmap.yaml
kubectl apply -f grafana/dashboard-configmap.yaml
kubectl apply -f grafana/deployment.yaml

kubectl rollout status deployment/grafana -n monitoring
```

> **Already applied Grafana before?** Re-apply the ConfigMaps then restart the Deployment so Grafana re-reads provisioning:
> ```bash
> kubectl apply -f grafana/datasource-configmap.yaml \
>               -f grafana/dashboard-configmap.yaml
> kubectl rollout restart deployment/grafana -n monitoring
> ```

---

## Verify the Pipeline

```bash
chmod +x scripts/verify.sh
bash scripts/verify.sh
```

Expected output (all green):

```
=== Phase 0 Pipeline Verification ===

[1] Cluster
  ✅ PASS  Node is Ready

[2] Sample Apps (namespace: demo)
  ✅ PASS  backend pod Running
  ✅ PASS  frontend pod Running
  ✅ PASS  auth pod Running
  ✅ PASS  backend service exists
  ✅ PASS  frontend service exists
  ✅ PASS  auth service exists

[3] Grafana Beyla (namespace: beyla)
  ✅ PASS  beyla DaemonSet exists
  ✅ PASS  beyla pod Running
  ✅ PASS  beyla /metrics returns 200

[4] Prometheus (namespace: monitoring)
  ✅ PASS  prometheus pod Running
  ✅ PASS  beyla target is UP in Prometheus

[5] Grafana (namespace: monitoring)
  ✅ PASS  grafana pod Running
  ✅ PASS  grafana /api/health returns ok

=== Summary ===
  Passed: 13  Failed: 0

All checks passed! Pipeline is healthy.
```

---

## Generate Traffic

The traffic generator runs an in-cluster pod that hits `frontend:8080` every 0.5 s,  
driving requests through the full **frontend → backend → auth** chain.

```bash
chmod +x scripts/traffic-gen.sh
bash scripts/traffic-gen.sh
```

Tail the request log:

```bash
kubectl logs -f traffic-gen -n demo
```

Stop and clean up:

```bash
kubectl delete pod traffic-gen -n demo
```

---

## Open Grafana

1. Get your node IP:

   ```bash
   kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
   ```

2. Open in browser:

   | Service | URL | Credentials |
   |---|---|---|
   | Grafana | `http://<NODE_IP>:30300` | `admin` / `admin` |
   | Prometheus | `http://<NODE_IP>:30900` | — |

3. Navigate to **Dashboards → Phase 0 — Beyla L4 + L7 Observability**.  
   All four panels should show live data within ~15 s of the traffic generator starting.

---

## Tear-Down

Remove everything in reverse order:

```bash
# Traffic generator (if running)
kubectl delete pod traffic-gen -n demo --ignore-not-found

# Grafana
kubectl delete -f grafana/

# Prometheus
kubectl delete -f prometheus/

# Beyla
kubectl delete -f beyla/

# Sample apps
kubectl delete -f sample-apps/
```

Or nuke all three namespaces at once:

```bash
kubectl delete namespace demo beyla monitoring
```

---

## Dashboard Panels

The dashboard (`uid: phase0-beyla`) contains four panels. All query the Prometheus datasource (`uid: prometheus`).

| # | Panel | Layer | Metric |
|---|---|---|---|
| 1 | **Network Flow Bytes/sec** | L4 | `rate(beyla_network_flow_bytes_total[1m])` — full-width row |
| 2 | **HTTP Request Rate** | L7 | `rate(http_server_request_duration_seconds_count[1m])` per service |
| 3 | **HTTP Latency p50 / p95 / p99** | L7 | `histogram_quantile` over `http_server_request_duration_seconds_bucket` |
| 4 | **HTTP Error Rate (5xx/sec)** | L7 | Filtered on `http_response_status_code=~"5.."` — should be zero |

> **Note:** The "TCP Connections/sec" panel was removed. Beyla only exposes byte counters (`beyla_network_flow_bytes_total`), not a connection-count metric, so the panel was misleading.

---

## Known Caveats & Limitations

| Issue | Impact | Workaround / Fix |
|---|---|---|
| **`emptyDir` storage** for Prometheus & Grafana | All metric history and Grafana state wiped on pod restart | Fine for PoC; add a PVC in Phase 1 for persistence |
| **`admin/admin` Grafana credentials** | Harmless locally | Set `GF_SECURITY_ADMIN_PASSWORD` env var before any external exposure |
| **`verify.sh` access URLs hardcode a WSL2 IP** | URLs break after WSL2 restart | Use `kubectl get node -o jsonpath=...` (see above) to get the current IP |
| **Single-node cluster** | No HA; Beyla DaemonSet runs one pod | Sufficient for Phase 0 PoC |
| **Prometheus retention: 2 h** | Long demos will lose early data | Increase `--storage.tsdb.retention.time` if needed |

---

## Roadmap

- **Phase 1** — Multi-cluster federation: second K3s cluster, Prometheus `remote_write` using the `cluster-01` label, Thanos sidecar
- **Phase 2** — Distributed tracing: Beyla OpenTelemetry trace export, Grafana Tempo
- **Phase 3** — Alerting: Prometheus AlertManager rules for p99 latency SLOs and 5xx error-rate thresholds
- **Phase 4** — Persistent storage: local-path PVCs for Prometheus and Grafana

---

> **Status (Phase 0):** Architecture is correct, RBAC is scoped, resource limits are set throughout, and the three-hop service chain gives Beyla's L7 tracing something real to show. Run `verify.sh` first, then `traffic-gen.sh`, and all four Grafana panels should populate within one scrape interval (15 s).

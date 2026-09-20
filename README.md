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
┌──────────────────────────────────────────────────────────────────┐
│  K3s Cluster (single node)                                       │
│                                                                  │
│  namespace: demo                                                 │
│  ┌──────────────┐    HTTP proxy    ┌──────────────┐             │
│  │   frontend   │ ───────────────► │   backend    │             │
│  │  nginx:alpine│ :8080            │  http-echo   │ :8080       │
│  └──────────────┘                  └──────────────┘             │
│                                                                  │
│  namespace: beyla                                                │
│  ┌─────────────────────────────────────────────────┐            │
│  │  Beyla DaemonSet  (grafana/beyla:2.1.0)         │            │
│  │  · eBPF hooks — auto-discovers port 8080        │            │
│  │  · Emits L4 network + L7 HTTP metrics           │            │
│  │  · Prometheus exporter → :9090/metrics          │            │
│  └─────────────────────────────────────────────────┘            │
│                │                                                 │
│                │ pod-IP discovery (kubernetes_sd)                │
│                ▼                                                 │
│  namespace: monitoring                                           │
│  ┌──────────────┐   PromQL   ┌──────────────┐                  │
│  │  Prometheus  │ ◄────────► │   Grafana    │                  │
│  │  v2.53.0     │            │  (latest)    │                  │
│  │  :9090       │            │  :3000       │                  │
│  └──────────────┘            └──────────────┘                  │
│   NodePort 30900              NodePort 30300                    │
└──────────────────────────────────────────────────────────────────┘
```

**Key design choices:**

| Decision | Rationale |
|---|---|
| Beyla as DaemonSet | One pod per node; captures all host-PID traffic without touching app code |
| `hostPID: true` + `hostNetwork: true` | Required for eBPF to attach to host process namespaces |
| `memlock-init` initContainer | Raises `RLIMIT_MEMLOCK` to unlimited; K3s/containerd caps it at 64 MiB by default, which blocks eBPF map creation |
| Narrow ClusterRole RBAC | Beyla gets only `get/list/watch` on pods/services/nodes — no cluster-admin |
| Prometheus pod-SD in `beyla` namespace | Scrapes Beyla pods by IP without needing a headless service |
| Provisioned ConfigMaps for Grafana | Dashboard and datasource survive Grafana restarts; no manual import needed |

---

## Prerequisites

| Tool | Minimum version | Notes |
|---|---|---|
| [K3s](https://k3s.io/) | v1.28+ | `curl -sfL https://get.k3s.io \| sh -` |
| `kubectl` | matching cluster | Configured with `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` or symlinked to `~/.kube/config` |
| `curl` | any | Used by `verify.sh` |
| Linux kernel | **5.8+** | Required for BPF capability and uprobe/kprobe attach used by Beyla |

> **WSL2 users:** Enable `KUBECONFIG` and make sure WSL2 can reach the NodePort IP printed by `verify.sh`. The IP can change after a WSL2 restart — re-check with `ip addr show eth0`.

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
│   ├── configmap.yaml              # prometheus.yml scrape config
│   └── deployment.yaml             # Deployment + NodePort Service (:30900)
│
├── grafana/
│   ├── datasource-configmap.yaml   # Prometheus datasource (uid: prometheus)
│   ├── dashboard-provider-configmap.yaml
│   ├── dashboard-configmap.yaml    # Phase 0 dashboard JSON (5 panels)
│   └── deployment.yaml             # Deployment + NodePort Service (:30300)
│
├── sample-apps/
│   ├── namespace.yaml              # namespace: demo
│   ├── backend.yaml                # hashicorp/http-echo — simple HTTP responder
│   └── frontend.yaml               # nginx proxy → backend, on :8080
│
└── scripts/
    ├── verify.sh                   # End-to-end health check (colour-coded pass/fail)
    └── traffic-gen.sh              # Runs an in-cluster curl loop to generate HTTP traffic
```

---

## Bring-Up (Step-by-Step)

Run every command from the repo root. Order matters — apply namespaces before workloads.

### 1 — Sample Applications

```bash
kubectl apply -f sample-apps/namespace.yaml
kubectl apply -f sample-apps/backend.yaml
kubectl apply -f sample-apps/frontend.yaml

# Wait for pods
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

# DaemonSet — wait for the pod to be ready (initContainer runs first)
kubectl rollout status daemonset/beyla -n beyla
```

> ⏱ The `memlock-init` initContainer takes ~5 s on first pull. If Beyla crashes with `permission denied` on eBPF map creation, check that your kernel is ≥ 5.8 and `SYS_RESOURCE` / `BPF` capabilities are not stripped by your container runtime.

### 4 — Grafana

```bash
kubectl apply -f grafana/datasource-configmap.yaml
kubectl apply -f grafana/dashboard-provider-configmap.yaml
kubectl apply -f grafana/dashboard-configmap.yaml
kubectl apply -f grafana/deployment.yaml

kubectl rollout status deployment/grafana -n monitoring
```

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
  ✅ PASS  backend service exists
  ✅ PASS  frontend service exists

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

[6] Traffic Generator
  ...

=== Summary ===
  Passed: 11  Failed: 0

All checks passed! Pipeline is healthy.
```

Manually confirm Beyla metrics are flowing into Prometheus:

```bash
# Port-forward Prometheus and query beyla metrics
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &
curl -s 'http://localhost:9090/api/v1/query?query=beyla_network_flow_bytes_total' | jq .status
```

---

## Generate Traffic

The traffic generator runs as an in-cluster pod sending HTTP requests to `frontend:8080` every 0.5 s.

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
   kubectl get node -o wide
   # or for WSL2:
   ip addr show eth0 | grep 'inet '
   ```

2. Open in browser:

   | Service | URL | Credentials |
   |---|---|---|
   | Grafana | `http://<NODE_IP>:30300` | `admin` / `admin` |
   | Prometheus | `http://<NODE_IP>:30900` | — |

3. Navigate to **Dashboards → Phase 0 — Beyla L4 + L7 Observability**.  
   You should see live data within ~15 s after the traffic generator starts.

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

Or nuke the three namespaces directly:

```bash
kubectl delete namespace demo beyla monitoring
```

---

## Dashboard Panels

| # | Panel | Layer | Metric / Query |
|---|---|---|---|
| 1 | **Network Flow Bytes/sec** | L4 | `rate(beyla_network_flow_bytes_total[1m])` |
| 2 | **TCP Connections/sec** ⚠️ | L4 | Falls back to byte-rate (see caveats) |
| 3 | **HTTP Request Rate** | L7 | `rate(http_server_request_duration_seconds_count[1m])` |
| 4 | **HTTP Latency p50/p95/p99** | L7 | `histogram_quantile` over `http_server_request_duration_seconds_bucket` |
| 5 | **HTTP Error Rate (5xx)** | L7 | Filtered on `http_response_status_code=~"5.."` |

---

## Known Caveats & Limitations

| Issue | Impact | Workaround / Fix |
|---|---|---|
| **Panel 2 — "TCP Connections/sec"** uses byte-rate fallback | Misleading label; not a true connection count | Rename or remove the panel until Beyla exposes a connection-count metric |
| **emptyDir storage** for Prometheus & Grafana | All metric history and Grafana state are wiped on pod restart | Acceptable for PoC; add a PVC for persistence in Phase 1 |
| **`admin/admin` Grafana credentials** | Fine locally; never expose externally | Change via `GF_SECURITY_ADMIN_PASSWORD` env var before any external access |
| **`verify.sh` hardcodes WSL2 IP** (`172.23.95.187`) | Printed access URLs break after WSL2 restart | Replace with `$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')` |
| **Single-node cluster** | No HA; Beyla DaemonSet has only one pod | Sufficient for Phase 0 PoC |

---

## Roadmap

- **Phase 1** — Multi-cluster federation: add a second K3s cluster, cross-cluster Prometheus remote-write, and Thanos sidecar
- **Phase 2** — Distributed tracing: enable Beyla's OpenTelemetry trace export, add Grafana Tempo
- **Phase 3** — Alerting: add Prometheus AlertManager rules for p99 latency SLOs and error-rate thresholds
- **Phase 4** — Persistent storage: replace `emptyDir` with local-path PVCs; add Grafana backup

---

> **Bottom line (as of Phase 0):** Architecture is correct, RBAC is properly scoped, and resource limits are set throughout. The datasource `uid` fix (see commit) is the only thing between this and fully live data. Run `verify.sh`, start `traffic-gen.sh`, and watch the Grafana dashboard populate in real time.

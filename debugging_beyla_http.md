# Grafana Beyla Missing HTTP Metrics — Diagnostic, Root Cause Analysis & Resolution Report

## Executive Summary

- **Environment**: Single-cluster local Kubernetes (K3s v1.28+) on WSL2 Ubuntu 22.04 (Kernel: `6.6.x microsoft-standard-WSL2`).
- **Workload**: 3-hop microservice chain in `demo` namespace: `traffic-gen` → `frontend` (nginx:8080) → `backend` (nginx:8080) → `auth` (http-echo:8080).
- **Core Problem**: Grafana Beyla (eBPF DaemonSet) successfully captured L4 network metrics (`beyla_network_flow_bytes_total`), but failed to export any L7 HTTP application metrics (`http_server_request_duration_seconds_count` returned empty results).
- **Root Cause**: On WSL2's customized kernel, the eBPF helper `bpf_get_ns_current_pid_tgid()` fails to resolve child PID namespace inodes for container processes, defaulting to `Namespace: 1`. Beyla's internal `CommonPIDsFilter` attempted to look up the span's reported namespace against its container discovery map (`4026533185`), causing every L7 HTTP span to be rejected and dropped.
- **Resolution**: Enabled `discovery.system_wide: true` in `beyla/daemonset.yaml` to switch Beyla from `PIDsFilter` to `IdentityPidsFilter`, bypassing the broken kernel namespace resolution. Side effects were mitigated by configuring Prometheus `metric_relabel_configs` to drop non-demo namespaces and converting `traffic-gen` into a self-healing Kubernetes `Deployment`.

---

## 1. Chronological Troubleshooting Journey

### Phase A: Initial Baseline & Symptoms
Following initial cluster bootstrap, Beyla attached its eBPF programs and exported L4 network metrics to Prometheus:
- `beyla_network_flow_bytes_total`: **Working** (visible in Prometheus and Grafana).
- `http_server_request_duration_seconds_count`: **Missing** (0 time series returned for demo services).

### Phase B: Unsuccessful Workarounds & App Crash Fixes

#### Attempt 1: Port-Based Discovery Configuration
- **Hypothesis**: Beyla was failing to discover HTTP services due to unset port filters.
- **Action**: Configured `open_port: 8080` in `beyla/daemonset.yaml`.
- **Outcome**: Failed. Beyla logs continued to report that captured HTTP spans were dropped by `CommonPIDsFilter`.

#### Attempt 2: Namespace-Scoped Discovery Configuration
- **Hypothesis**: Restricting discovery strictly to the `demo` Kubernetes namespace would align PID discovery tables.
- **Action**: Configured `discovery.services: [{k8s_namespace: demo, open_ports: 8080}]`.
- **Outcome**: Failed. While Beyla correctly discovered the target container PIDs, incoming HTTP spans were still dropped at runtime.

#### Attempt 3: Frontend Pod OOMKilled Remediation
- **Symptom**: During traffic generation, `traffic-gen` reported HTTP `000` connection drops and `kubectl get pods -n demo` revealed `frontend` with restart count > 0.
- **Root Cause**: `frontend` (nginx) was constrained to a `32Mi` memory limit and crashed under load.
- **Action**: Increased memory limit in `sample-apps/frontend.yaml` to `128Mi`.
- **Outcome**: `frontend` stabilized and served HTTP 200 responses reliably across the chain, but L7 metrics remained absent from Prometheus.

---

## 2. Root Cause Analysis (eBPF Kernel Limitation)

Enabling Beyla debug logging (`BEYLA_LOG_LEVEL: DEBUG`) revealed the exact point of failure:

```text
level=DEBUG msg="filtered spans from processes that did not match discovery"
component=ebpfCommon.CommonPIDsFilter function=PIDsFilter.Filter
inLen=2 outLen=0
pids="map[4026533185:map[1:{...} 212015:{...}]]"
spans="[{Type:HTTP Method:GET Path:/ Host:10.42.0.94 HostPort:8080 Status:200
  Pid:{HostPID:20713 UserPID:1 Namespace:1}}]"
```

### Mechanism of the Failure

1. **Discovery Mapping**: Beyla's userspace discovery agent correctly inspected containerd and mapped the container's real PID namespace inode:
   $$\text{Inode: } 4026533185 \longrightarrow \text{PIDs: } \{1, 212015\}$$
2. **eBPF Probe Execution**: When an HTTP request occurred, Beyla's socket/uprobe eBPF program executed on the host. To tag the span with process metadata, the eBPF program invoked the kernel helper:
   ```c
   bpf_get_ns_current_pid_tgid(...)
   ```
3. **WSL2 Kernel Defect**: Under the Microsoft WSL2 custom Linux kernel (`microsoft-standard-WSL2`), `bpf_get_ns_current_pid_tgid` cannot resolve child container PID namespace inodes and returns `Namespace: 1` (the host root namespace or error sentinel).
4. **Lookup Rejection**: Beyla's `PIDsFilter.Filter` executes:
   ```go
   lookup pids[span.Namespace][span.HostPID]  // pids[1][20713]
   ```
   Because `pids` was indexed under `4026533185`, the lookup for `1` returned `nil`, and the filter dropped 100% of captured HTTP spans.

---

## 3. The Resolution

### Bypass via `discovery.system_wide: true`

In Grafana Beyla source code (`pkg/internal/ebpf/common/pids.go`):

```go
func CommonPIDsFilter(c *services.DiscoveryConfig) ServiceFilter {
    if c.SystemWide {
        return &IdentityPidsFilter{  // <-- accepts ALL spans, no PID/namespace check
            detectOTel: c.ExcludeOTelInstrumentedServices,
        }
    }
    // else: returns PIDsFilter (relies on PID namespace inode resolution)
}
```

Setting `discovery.system_wide: true` switches Beyla to `IdentityPidsFilter`. This filter passes all captured spans directly to the metric pipeline without performing the broken PID namespace lookup.

**Configuration applied to `beyla/daemonset.yaml`:**
```yaml
    discovery:
      system_wide: true
```

Following this change, Beyla debug logs immediately confirmed successful metric generation:
```text
level=DEBUG msg="storing new metric label set" component=prom.Expirer
labelValues="[GET 200 / ... demo/ ... frontend 8080 demo]"
```

---

## 4. Tightening System-Wide Side Effects

While `system_wide: true` resolved metric capture, it introduced two operational side effects:

### 1. Prometheus Ingestion Noise
In system-wide mode, Beyla instruments all host processes (including `kube-system` components like `coredns` and `traefik`, plus `monitoring/grafana`).

- **Solution**: Added `metric_relabel_configs` to the `beyla` scrape job in `prometheus/configmap.yaml`:
  ```yaml
        metric_relabel_configs:
          - source_labels: [service_namespace]
            regex: '(kube-system|monitoring)'
            action: drop
  ```
- **Result**: Prometheus discards non-demo infrastructure metrics at scrape time, keeping storage focused strictly on the application workloads.

### 2. Traffic Generator Self-Healing
The initial `traffic-gen` was an ephemeral Pod (`restartPolicy: Never`), leaving metrics stalled in Prometheus whenever K3s restarted.

- **Solution**: Converted `traffic-gen` into a Kubernetes `Deployment` (`apps/v1`, 1 replica, `restartPolicy: Always`) in `sample-apps/traffic-gen.yaml` and updated `scripts/traffic-gen.sh`.
- **Result**: The traffic generator automatically restarts and resumes load generation after cluster and node restarts without requiring manual execution.

---

## 5. Architectural Recommendation for Phase 1 (Multi-Cluster / Native Linux)

> [!NOTE]
> The `discovery.system_wide: true` configuration is a **workaround specifically tailored for WSL2**.
>
> In Phase 1, when deploying across native Linux VMs (e.g. AWS EC2, GCP GCE, or bare-metal Linux with standard distribution kernels), `bpf_get_ns_current_pid_tgid()` functions correctly and returns valid child namespace inodes.
>
> **Action item for Phase 1**: Before adopting `system_wide: true` in multi-cluster environments, re-test granular namespace-scoped discovery (`discovery.services: [{k8s_namespace: demo}]`). Granular discovery should be preferred whenever native kernel support is available, as it eliminates unnecessary host-wide instrumentation overhead.

---

## 6. Verification Summary

| Verification Target | Command / Check | Result |
|---|---|---|
| **L4 Network Metrics** | `beyla_network_flow_bytes_total` | ✅ PASS |
| **L7 HTTP Metrics** | `http_server_request_duration_seconds_count{service_namespace="demo"}` | ✅ PASS (`frontend`, `backend`, `auth`) |
| **Namespace Isolation** | `http_server_request_duration_seconds_count{service_namespace=~"kube-system|monitoring"}` | ✅ PASS (0 results; dropped by relabel) |
| **Traffic Gen Resilience** | `kubectl get deployment traffic-gen -n demo` | ✅ PASS (Self-healing Deployment active) |
| **End-to-End Suite** | `bash scripts/verify.sh` | ✅ PASS (All checks healthy) |

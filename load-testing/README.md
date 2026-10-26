# Multi-Cluster Kubernetes k6 Load Generation Suite

A production-grade, multi-scenario load testing suite using **[Grafana k6](https://k6.io/)** designed specifically for validating microservice performance, **Grafana Beyla eBPF zero-instrumentation telemetry**, and **Kubernetes Horizontal Pod Autoscaling (HPA)**.

---

## 1. Architecture & Traffic Flow

The test suite executes outside the Kubernetes cluster to simulate real-world external clients:

```
[External Client / k6 Test Runner]
                │
                │  HTTP GET / (NodePort 30080)
                ▼
      ┌──────────────────┐
      │  frontend :8080  │  (Kubernetes Service: NodePort 30080)
      └─────────┬────────┘
                │  HTTP GET /api/data (ClusterIP :8080)
                ▼
      ┌──────────────────┐
      │  backend :8080   │  (Kubernetes Service: ClusterIP 8080)
      └─────────┬────────┘
                │  HTTP GET /auth/verify (ClusterIP :8080)
                ▼
      ┌──────────────────┐
      │    auth :8080    │  (Kubernetes Service: ClusterIP 8080)
      └──────────────────┘
```

- **L4 eBPF Metrics:** Beyla tracks socket connections, bytes transmitted/received, and TCP handshake durations across all hops without application code changes.
- **L7 eBPF Metrics:** Beyla traces HTTP request rate, error rates, and duration (RED metrics) propagated across `frontend` → `backend` → `auth`.
- **HPA Autoscaling:** Each service is monitored by a Horizontal Pod Autoscaler configured to maintain 50% CPU target utilization (`minReplicas: 1`, `maxReplicas: 5`).

---

## 2. The 6 Kinds of Load Testing: Why, When & How

Understanding the purpose of each testing pattern is critical to choosing the right tool for the job:

| # | Test Type | Scenario File | Traffic Profile | Primary Purpose | What to Watch in Grafana / K8s |
|---|---|---|---|---|---|
| **1** | **Smoke Test** | `scenarios/1_smoke.js` | 2 VUs for 15s | Sanity check after deploy; verify all 3 hops return 200 OK | HTTP reqs ~10/s, 0% errors, HPA stays idle (1 replica) |
| **2** | **Load Test** | `scenarios/2_load.js` | 0 → 10 → 15 → 0 VUs over 3m | Measure baseline latency & throughput under expected daily peak traffic | Smooth bell curve, p95 latency < 50ms, CPU ~25% |
| **3** | **Spike Test** | `scenarios/3_spike.js` | 2 → 45 VUs in 10s, hold 1m | **Triggers HPA Pod Autoscaling**; simulates flash crowd or viral traffic | `kubectl get hpa -w` shows replicas scale 1 → 5; Grafana pod count jumps |
| **4** | **Stress Test** | `scenarios/4_stress.js` | 10 → 25 → 50 → 75 VUs | Find system breaking point, test latency degradation & graceful recovery | Watch p95/p99 latency rise; check if error rate stays below 10% |
| **5** | **Soak Test** | `scenarios/5_soak.js` | 10 VUs for 10m (or hours) | Detect memory leaks, TCP socket exhaustion, or eBPF buffer overflow | Pod memory line must stay flat (horizontal); 0 pod restarts |
| **6** | **Constant Rate** | `scenarios/6_constant_rate.js` | Fixed 40 RPS (open model) | Strict SLA verification independent of server response latency | Perfectly flat 40 req/s line in Grafana throughput panel |

---

## 3. Quick Start Commands

The runner script auto-detects the Kubernetes node IP and sets up the environment automatically:

```bash
# 1. Quick sanity check (15 seconds)
./load-testing/k6/run.sh smoke

# 2. Daily peak traffic curve (3 minutes)
./load-testing/k6/run.sh load

# 3. Trigger HPA Pod Autoscaling (1.5 minutes)
./load-testing/k6/run.sh spike

# 4. Stress test upper limits (2.5 minutes)
./load-testing/k6/run.sh stress

# 5. Soak test for stability & leaks (10 minutes)
./load-testing/k6/run.sh soak

# 6. Constant 40 requests/second arrival rate (2 minutes)
./load-testing/k6/run.sh constant

# --- Background Execution & Stopping ---

# Run any scenario in background (e.g. for long dashboard demos)
nohup ./load-testing/k6/run.sh load > k6.log 2>&1 &
# Or backward-compatible:
nohup ./load-testing/k6/run.sh ramp-up > k6.log 2>&1 &

# Check if k6 is running
./load-testing/k6/run.sh status

# Stop / kill all active k6 load traffic immediately
./load-testing/k6/run.sh stop
# (Alternative shell command: pkill -f k6)
```

### Passing Custom Overrides

You can pass standard k6 command-line flags directly to `run.sh`:

```bash
# Override duration: run load test for 5 minutes
./load-testing/k6/run.sh load --duration 5m

# Override concurrency: run smoke test with 10 VUs
./load-testing/k6/run.sh smoke --vus 10

# Point to a remote cluster or specific IP:
TARGET_URL=http://192.168.31.112:30080 ./load-testing/k6/run.sh spike
```

---

## 4. Live Demonstration: Watching HPA Autoscaling

To demonstrate **Kubernetes Autoscaling + eBPF Observability** live:

### Step 1: Open Terminal 1 (Watch HPA in real time)
```bash
kubectl get hpa,pods -n demo -w
```

### Step 2: Open Grafana in Browser
Navigate to `http://<NODE_IP>:30300` (default login: `admin` / `admin`).
Open the dashboard: **Phase 0 — Extended L4 + L7 Metrics**.
Locate the row: **HPA — Pod Autoscaling** and panel: **Pod Count Over Time (HPA Scaling)**.

### Step 3: Run the Spike Test in Terminal 2
```bash
./load-testing/k6/run.sh spike
```

### What You Will Observe:
1. **At T=00:15s:** Traffic suddenly bursts to 45 concurrent virtual users (~500 req/s).
2. **At T=00:30s:** `kubectl` shows CPU utilization leaping to `120%/50%`.
3. **At T=00:45s:** HPA initiates scale-up:
   ```
   horizontalpodautoscaler.autoscaling/frontend   cpu: 125%/50%   1   5   3   30s
   horizontalpodautoscaler.autoscaling/backend    cpu: 110%/50%   1   5   3   30s
   horizontalpodautoscaler.autoscaling/auth       cpu: 95%/50%    1   5   2   30s
   ```
4. **At T=01:10s:** Extra pods enter `Running` state; load balances across all new pods.
5. **At T=01:25s:** Test ends. Traffic drops to 0. CPU drops to `0%/50%`.
6. **At T=02:30s:** After the 60-second stabilization window, HPA gracefully scales back down to 1 replica.

---

## 5. k6 Fundamentals: How Scenarios Work

### 1. Closed Model vs Open Model
- **Closed Model (`vus` / `stages`):** Each virtual user (VU) executes a loop: send request → wait for response → sleep → repeat.
  - *Used in:* `smoke.js`, `load.js`, `spike.js`, `stress.js`, `soak.js`.
  - *Note:* If the server slows down, VUs spend more time waiting, naturally reducing request rate.
- **Open Model (`constant-arrival-rate`):** k6 sends a fixed number of requests per second regardless of how slow the server responds, spinning up extra VUs automatically if needed.
  - *Used in:* `6_constant_rate.js`.

### 2. Stages (Traffic Curves)
Stages define how virtual users ramp up and ramp down over time:
```javascript
export const options = {
  stages: [
    { duration: '30s', target: 10 }, // Ramp up to 10 VUs in 30 seconds
    { duration: '1m',  target: 10 }, // Hold steady at 10 VUs for 1 minute
    { duration: '15s', target: 0 },  // Gracefully scale down to 0 VUs
  ],
};
```

### 3. SLO Thresholds
Thresholds define automated pass/fail criteria for CI/CD pipelines:
```javascript
export const options = {
  thresholds: {
    // Fail if error rate is 1% or higher
    http_req_failed: ['rate<0.01'],
    // Fail if 95th percentile latency exceeds 200ms
    http_req_duration: ['p(95)<200'],
  },
};
```

---

## 6. Directory Layout

```
load-testing/
├── README.md                  # Comprehensive guide & reference (this file)
└── k6/
    ├── config.js              # Shared configuration, helper functions & tagging
    ├── run.sh                 # Intelligent CLI runner with auto IP detection & help
    └── scenarios/
        ├── 1_smoke.js         # Sanity check (2 VUs, 15s)
        ├── 2_load.js          # Daily peak curve (0 -> 10 -> 15 -> 0 VUs, 3m)
        ├── 3_spike.js         # Sudden surge (2 -> 45 VUs) for HPA demo (1.5m)
        ├── 4_stress.js        # Step-ladder capacity test (10 -> 75 VUs, 2.5m)
        ├── 5_soak.js          # Extended stability test for memory leaks (10m)
        ├── 6_constant_rate.js # Constant 40 RPS arrival rate (2m)
        ├── smoke.js           # Backward-compatibility alias
        └── ramp-up.js         # Backward-compatibility alias
```

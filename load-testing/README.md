# External Load Testing Suite (Grafana k6)

This directory contains external load testing scenarios for the 3-hop microservice architecture (`frontend` → `backend` → `auth`), designed to validate zero-instrumentation eBPF observability powered by **Grafana Beyla**.

---

## Architecture & Traffic Flow

Unlike internal load generation, this test suite runs **outside the Kubernetes cluster boundary**:

```
[Host / External Machine]
       │  (k6 virtual users)
       ▼
 [NodePort :30080]
       │
   (frontend :8080) ──► (backend :8080) ──► (auth :8080)
```

Beyla automatically intercepts and correlates both L4 flow metrics and L7 HTTP RED spans across all hops.

---

## Directory Structure

```
load-testing/
├── README.md                  # This file
└── k6/
    ├── run.sh                 # Intelligent runner (auto-detects node IP)
    └── scenarios/
        ├── smoke.js           # 10s light sanity check (2 VUs)
        └── ramp-up.js         # 3m staged traffic curve (0 -> 5 -> 15 -> 0 VUs)
```

---

## Quick Start

Run from the repository root:

### 1. Smoke Test (10s sanity check)
```bash
./load-testing/k6/run.sh smoke
```

### 2. Standard Staged Ramp-Up (3 minutes)
```bash
./load-testing/k6/run.sh ramp-up
```

### 3. Custom Duration & Concurrency Override
Any standard `k6` CLI flags can be passed after the scenario name:
```bash
# Run 10 VUs for 5 minutes
./load-testing/k6/run.sh smoke --duration 5m --vus 10

# Sustained background generation for long dashboard demos
nohup ./load-testing/k6/run.sh smoke --duration 1h --vus 5 > k6.log 2>&1 &
```

---

## Real-Time Observability

Open Grafana at `http://<NODE_IP>:30300` (`admin` / `admin`) to observe real-time metrics during test runs:

- **Dashboard:** `Phase 0 — Beyla L4 + L7 Observability`
- **Dashboard:** `Phase 0 — Extended L4 + L7 Metrics`

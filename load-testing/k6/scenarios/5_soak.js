/**
 * Scenario 5: Soak / Endurance Test (Reliability & Memory Leaks)
 * -------------------------------------------------------------
 * WHAT IT DOES:
 * Applies a steady, moderate load (8-10 Virtual Users) for an extended duration (10 minutes).
 * Can be run for hours by passing `--duration 1h` to run.sh.
 *   1. Ramp-up:   1m to reach 10 VUs
 *   2. Soak:      8m steady at 10 VUs
 *   3. Ramp-down: 1m graceful wind down
 *
 * WHEN TO USE:
 * - To check for slow memory leaks in Node.js / Go / Nginx containers.
 * - To ensure Beyla eBPF probes don't drop rings or overflow kernel buffers over time.
 * - To verify that long-term connection pools, file descriptors, and sockets don't exhaust.
 *
 * OBSERVABILITY EXPECTATION:
 * - Grafana:
 *     * Memory curves should stay strictly flat (horizontal). An upward slope indicates a memory leak.
 *     * Latency percentiles should stay steady throughout the entire run.
 * - Kubernetes:
 *     * Pod restarts (RESTARTS column in `kubectl get pods -n demo`) must remain 0.
 */

import { sleep } from 'k6';
import { sendRequest } from '../config.js';

export const options = {
  stages: [
    { duration: '1m', target: 10 },  // Ramp-up to soak level
    { duration: '8m', target: 10 },  // Sustained steady soak
    { duration: '1m', target: 0 },   // Cool down
  ],
  thresholds: {
    // SLO 1: Error rate strictly below 1% over the entire duration
    http_req_failed: ['rate<0.01'],
    // SLO 2: Latency must not degrade over time (p95 < 150ms)
    http_req_duration: ['p(95)<150'],
  },
};

export default function () {
  sendRequest('soak');
  // Natural user pacing between requests (150ms - 350ms)
  sleep(0.15 + Math.random() * 0.2);
}

/**
 * Scenario 4: Stress Test (Finding the Breaking Point)
 * -------------------------------------------------------------
 * WHAT IT DOES:
 * Steps up traffic progressively through multiple plateaus to find the system's
 * upper limit and test graceful degradation under extreme stress:
 *   1. Step 1 (Normal):    30s at 10 VUs
 *   2. Step 2 (Elevated):  30s at 25 VUs
 *   3. Step 3 (High):      30s at 50 VUs
 *   4. Step 4 (Extreme):   30s at 75 VUs
 *   5. Recovery:           30s ramp down to 0 VUs
 *
 * WHEN TO USE:
 * - To determine maximum throughput (requests per second) the cluster can handle.
 * - To observe how latency degrades as concurrency climbs.
 * - To verify that the system recovers gracefully once the stress ends.
 *
 * OBSERVABILITY EXPECTATION:
 * - Grafana:
 *     * Watch the Latency Percentiles (p50, p90, p95, p99) climb with each step.
 *     * Watch the CPU and memory consumption per pod across each tier.
 * - Kubernetes:
 *     * HPA will scale to its maximum limit (maxReplicas = 5).
 *     * If requests exceed pod limits, you will observe TCP connection queues and p99 spikes.
 */

import { sleep } from 'k6';
import { sendRequest } from '../config.js';

export const options = {
  stages: [
    { duration: '30s', target: 10 },  // Step 1: Normal load
    { duration: '30s', target: 25 },  // Step 2: Elevated load
    { duration: '30s', target: 50 },  // Step 3: High load
    { duration: '30s', target: 75 },  // Step 4: Extreme stress load
    { duration: '30s', target: 0 },   // Step 5: Recovery period
  ],
  thresholds: {
    // Under stress, we want to know if failure rate exceeds 10%
    http_req_failed: ['rate<0.10'],
    // Median latency should still remain respectable
    http_req_duration: ['p(50)<150'],
  },
};

export default function () {
  sendRequest('stress');
  // Moderate pacing between requests (50ms - 150ms)
  sleep(0.05 + Math.random() * 0.1);
}

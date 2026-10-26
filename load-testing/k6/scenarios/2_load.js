/**
 * Scenario 2: Load / Ramp-Up Test
 * -------------------------------------------------------------
 * WHAT IT DOES:
 * Simulates normal, expected daily traffic using a 3-stage curve:
 *   1. Ramp-up:   30s to smoothly reach 10 VUs
 *   2. Steady:    1m 30s sustained at 15 VUs (peak normal load)
 *   3. Ramp-down: 30s graceful wind down to 0 VUs
 *
 * WHEN TO USE:
 * - To establish your system baseline (latency, throughput, resource usage).
 * - To test how services handle typical peak hours.
 * - Standard regression testing in CI/CD before production deployment.
 *
 * OBSERVABILITY EXPECTATION:
 * - Grafana: Request rates form a smooth bell-curve peaking around 60-80 req/s.
 * - Beyla L7: Traces confirm end-to-end propagation through all 3 hops.
 * - Kubernetes: CPU utilization hovers around 20-35% (below HPA 50% scale threshold).
 */

import { sleep } from 'k6';
import { sendRequest } from '../config.js';

export const options = {
  stages: [
    { duration: '30s', target: 10 },  // Stage 1: Morning traffic ramp-up
    { duration: '1m30s', target: 15 }, // Stage 2: Normal peak traffic
    { duration: '30s', target: 0 },   // Stage 3: Evening traffic cool down
  ],
  thresholds: {
    // SLO 1: Less than 1% errors
    http_req_failed: ['rate<0.01'],
    // SLO 2: 95% of requests complete under 150ms
    http_req_duration: ['p(95)<150'],
    // SLO 3: 99% of requests complete under 300ms
    'http_req_duration{scenario:load}': ['p(99)<300'],
  },
};

export default function () {
  sendRequest('load');
  // Dynamic user pacing: random jitter between 100ms and 250ms
  sleep(0.1 + Math.random() * 0.15);
}

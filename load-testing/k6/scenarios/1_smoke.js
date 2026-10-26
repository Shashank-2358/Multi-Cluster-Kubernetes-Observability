/**
 * Scenario 1: Smoke Test
 * -------------------------------------------------------------
 * WHAT IT DOES:
 * Runs a minimal load (2 Virtual Users) for 15 seconds.
 *
 * WHEN TO USE:
 * - Immediately after deploying new Helm chart releases or pods.
 * - As a pre-flight sanity check before running heavy load tests.
 * - To verify frontend (30080) -> backend -> auth network connectivity.
 *
 * OBSERVABILITY EXPECTATION:
 * - Grafana: HTTP requests show ~10 req/s, 0% error rate, p95 < 10ms.
 * - Kubernetes: HPA stays idle at 1 replica (CPU < 5%).
 */

import { sleep } from 'k6';
import { sendRequest } from '../config.js';

export const options = {
  vus: 2,
  duration: '15s',
  thresholds: {
    // SLO 1: Error rate must be under 1%
    http_req_failed: ['rate<0.01'],
    // SLO 2: 95% of requests must complete under 200ms
    http_req_duration: ['p(95)<200'],
  },
};

export default function () {
  sendRequest('smoke');
  // Gentle pacing between requests (100ms - 200ms)
  sleep(0.1 + Math.random() * 0.1);
}

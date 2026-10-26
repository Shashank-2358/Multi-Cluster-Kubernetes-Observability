/**
 * Scenario 6: Constant Arrival Rate (Fixed Throughput / Open Model)
 * -------------------------------------------------------------
 * WHAT IT DOES:
 * Generates an exact, constant throughput of requests per second (default: 40 RPS)
 * using k6's advanced `constant-arrival-rate` executor.
 *
 * KEY CONCEPT (VU vs Arrival Rate):
 * - Closed Model (Standard VUs): If your server slows down, virtual users wait for responses,
 *   which accidentally DECREASES the request rate (unrealistic).
 * - Open Model (Arrival Rate): Real users keep arriving at fixed intervals regardless of how
 *   fast or slow your server is. k6 dynamically spawns extra VUs to maintain the exact target RPS.
 *
 * WHEN TO USE:
 * - When your SLA is defined in terms of Requests Per Second (RPS) (e.g., "Must handle 50 RPS").
 * - To measure how latency behaves under a perfectly steady, uniform request flow.
 *
 * OBSERVABILITY EXPECTATION:
 * - Grafana: Request rate panel will show a completely straight horizontal line at ~40 req/s.
 */

import { sendRequest } from '../config.js';

export const options = {
  scenarios: {
    constant_rate_test: {
      executor: 'constant-arrival-rate',
      rate: 40,               // Exactly 40 iterations (requests) per timeUnit
      timeUnit: '1s',         // per 1 second
      duration: '2m',         // Run for 2 minutes
      preAllocatedVUs: 10,    // Initial pool of VUs
      maxVUs: 60,             // Max VUs to spin up if latency spikes
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<200'],
  },
};

export default function () {
  sendRequest('constant-rate');
}

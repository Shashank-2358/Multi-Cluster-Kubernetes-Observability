/**
 * Scenario 3: Spike Test (HPA Autoscaling Trigger)
 * -------------------------------------------------------------
 * WHAT IT DOES:
 * Generates an abrupt, violent surge in traffic from 2 to 45 concurrent users,
 * sustains it for 1 minute, and then suddenly drops back down:
 *   1. Warmup:     10s at 2 VUs (idle baseline)
 *   2. Spike surge: 10s violent jump to 45 VUs
 *   3. Peak hold:   1m sustained at 45 VUs (pushes CPU > 50% target)
 *   4. Cool down:  15s sharp drop to 0 VUs
 *
 * WHEN TO USE:
 * - To demonstrate Kubernetes Horizontal Pod Autoscaler (HPA) scaling in real-time!
 * - To test system elasticity (e.g. Flash sales, breaking news, viral spikes).
 * - To check if sudden traffic spikes crash containers or cause cascading 503s.
 *
 * OBSERVABILITY EXPECTATION:
 * - Terminal: Run `kubectl get hpa -n demo -w` alongside this test!
 * - HPA Behavior:
 *     * 00:20s: CPU surges past 50% target (reaches 80% - 150%).
 *     * 00:35s: HPA scales frontend, backend, and auth from 1 -> 3 -> 5 replicas.
 *     * 01:25s: Traffic drops to 0. CPU drops to 0%.
 *     * 02:30s: After 60s scale-down stabilization window, replicas drop back to 1.
 * - Grafana: Watch the "Pod Count Over Time (HPA Scaling)" and "L4 Monitored Pods"
 *   panels jump from 3 pods up to 9-15 pods and back down!
 */

import { sleep } from 'k6';
import { sendRequest } from '../config.js';

export const options = {
  stages: [
    { duration: '10s', target: 2 },   // Step 1: Baseline idle traffic
    { duration: '10s', target: 45 },  // Step 2: VIOLENT SPIKE!
    { duration: '1m',  target: 45 },  // Step 3: Sustained heavy spike to trigger HPA
    { duration: '15s', target: 0 },   // Step 4: Instant drop to 0 (trigger scale down)
  ],
  thresholds: {
    // During a severe spike, allow up to 5% failure under extreme surge
    http_req_failed: ['rate<0.05'],
    // 90% of requests should still complete under 500ms
    http_req_duration: ['p(90)<500'],
  },
};

export default function () {
  sendRequest('spike');
  // Aggressive pacing (20ms - 50ms) to generate high CPU load on microservices
  sleep(0.02 + Math.random() * 0.03);
}

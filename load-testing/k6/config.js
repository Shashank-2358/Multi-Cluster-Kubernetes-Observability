import http from 'k6/http';
import { check } from 'k6';

/**
 * Shared configuration and helper utilities for k6 test scenarios.
 * Default target URL falls back to local NodePort 30080 if TARGET_URL env var is unset.
 */
export const TARGET_URL = __ENV.TARGET_URL || 'http://127.0.0.1:30080/';

/**
 * Standard HTTP GET helper with consistent headers, tagging, and checks.
 * Tagging allows Grafana / Beyla dashboards to filter metrics by test scenario.
 *
 * @param {string} scenarioName - Identifier for the scenario (e.g. 'smoke', 'spike')
 * @returns {object} k6 HTTP response
 */
export function sendRequest(scenarioName) {
  const params = {
    headers: {
      'User-Agent': `k6-${scenarioName}/v2.0`,
      'Accept': 'text/plain',
    },
    tags: {
      scenario: scenarioName,
    },
    timeout: '10s',
  };

  const res = http.get(TARGET_URL, params);

  check(res, {
    'status is 200': (r) => r.status === 200,
    'body received': (r) => r.body && r.body.length > 0,
  });

  return res;
}

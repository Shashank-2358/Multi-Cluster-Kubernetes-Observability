import http from 'k6/http';
import { check, sleep } from 'k6';

const TARGET_URL = __ENV.TARGET_URL || 'http://172.23.95.187:30080/';

export const options = {
  stages: [
    { duration: '30s', target: 5 },   // Ramp up to 5 concurrent users
    { duration: '2m',  target: 15 },  // Steady load: 15 concurrent users
    { duration: '30s', target: 0 },   // Graceful ramp-down
  ],
  thresholds: {
    // SLO: 99% of requests must succeed with HTTP 200
    http_req_failed: ['rate<0.01'],
    // SLO: 95% of requests must complete under 200ms
    http_req_duration: ['p(95)<200'],
  },
};

export default function () {
  const params = {
    headers: {
      'User-Agent': 'k6-external-ramp-test/v1.0',
      'Accept': 'text/plain',
    },
    tags: {
      scenario: 'ramp-up',
    },
  };

  const res = http.get(TARGET_URL, params);

  check(res, {
    'status is 200': (r) => r.status === 200,
    'body contains auth response': (r) => r.body && r.body.length > 0,
  });

  // Pacing: between 100ms and 300ms pause between requests per virtual user
  sleep(Math.random() * 0.2 + 0.1);
}

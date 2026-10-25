import http from 'k6/http';
import { check, sleep } from 'k6';

const TARGET_URL = __ENV.TARGET_URL || 'http://172.23.95.187:30080/';

export const options = {
  vus: 2,
  duration: '10s',
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  const params = {
    headers: {
      'User-Agent': 'k6-external-smoke-test/v1.0',
    },
    tags: {
      scenario: 'smoke',
    },
  };

  const res = http.get(TARGET_URL, params);

  check(res, {
    'status is 200': (r) => r.status === 200,
    'body received': (r) => r.body && r.body.length > 0,
  });

  sleep(0.2);
}

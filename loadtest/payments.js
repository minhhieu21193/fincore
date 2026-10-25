// Load test for POST /v1/payments.
//
//   k6 run -e TARGET=http://localhost:8080 -e RPS=50 -e DURATION=2m loadtest/payments.js
//
// Thresholds encode the SLO used for canary analysis: <1% server errors and
// p95 < 300 ms. Declines (HTTP 402) are business outcomes, not errors.
import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const TARGET = __ENV.TARGET || 'http://localhost:8080';
const RPS = Number(__ENV.RPS || 50);
const DURATION = __ENV.DURATION || '2m';

const serverErrors = new Rate('server_errors');
const captured = new Rate('captured');
const latency = new Trend('payment_latency', true);

export const options = {
  discardResponseBodies: false,
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 1,
      timeUnit: '1s',
      preAllocatedVUs: Math.max(20, RPS),
      maxVUs: RPS * 10,
      stages: [
        { target: RPS, duration: '30s' },
        { target: RPS, duration: DURATION },
        { target: 0, duration: '10s' },
      ],
    },
  },
  thresholds: {
    server_errors: ['rate<0.01'],
    'http_req_duration{expected_response:true}': ['p(95)<300', 'p(99)<800'],
  },
};

export default function () {
  const body = JSON.stringify({
    merchant_id: `m_load_${__VU % 20}`,
    amount: 100 + Math.floor(Math.random() * 9900),
    currency: 'USD',
    card_token: 'tok_visa',
  });
  const key = `load-${__VU}-${__ITER}-${Date.now()}`;
  const res = http.post(`${TARGET}/v1/payments`, body, {
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': key },
    timeout: '10s',
  });
  serverErrors.add(res.status === 0 || res.status >= 500);
  captured.add(res.status === 201);
  latency.add(res.timings.duration);
  check(res, { 'captured or declined': (r) => r.status === 201 || r.status === 402 });
}

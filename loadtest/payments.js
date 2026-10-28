// Load test for POST /v1/payments.
//
// Stepped (the Phase 3 capacity test, run in-cluster by scripts/loadtest.sh):
//   k6 run -e TARGET=... -e STEPS=50,100,150,200,250,300 -e HOLD=2m loadtest/payments.js
// Single rate (against a port-forward, `make loadtest`):
//   k6 run -e TARGET=http://localhost:8080 -e RPS=50 -e DURATION=2m loadtest/payments.js
//
// Each step ramps for 20 s, then holds its rate. The thresholds are the
// payments SLOs (gitops/platform/slo): < 0.1 % server errors, p99 < 300 ms.
// Declines (HTTP 402) are business outcomes, not errors. Concurrency is
// bounded (MAX_VUS): when the platform cannot keep up, k6 drops iterations
// instead of queueing them, so the rate actually served is visible.
import http from 'k6/http';
import { check } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const TARGET = __ENV.TARGET || 'http://localhost:8080';
const STEPS = (__ENV.STEPS || __ENV.RPS || '50').split(',').map(Number);
const HOLD = __ENV.HOLD || __ENV.DURATION || '2m';

const serverErrors = new Rate('server_errors');
const captured = new Rate('captured');
const latency = new Trend('payment_latency', true);

const stages = [];
for (const rps of STEPS) {
  stages.push({ target: rps, duration: '20s' }, { target: rps, duration: HOLD });
}
stages.push({ target: 0, duration: '10s' });

export const options = {
  discardResponseBodies: true,
  // A new connection per request, as the traffic generator does: kube-proxy
  // balances per connection, an ALB per request.
  noConnectionReuse: true,
  scenarios: {
    steps: {
      executor: 'ramping-arrival-rate',
      startRate: 1,
      timeUnit: '1s',
      preAllocatedVUs: Math.min(100, Math.max(...STEPS)),
      maxVUs: Number(__ENV.MAX_VUS || 300),
      stages,
    },
  },
  thresholds: {
    server_errors: ['rate<0.001'],
    'http_req_duration{expected_response:true}': ['p(99)<300'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
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

// Machine-readable summary between markers, for scripts/loadtest.sh.
export function handleSummary(data) {
  const pick = (m) => (data.metrics[m] ? data.metrics[m].values : null);
  const out = {
    steps: STEPS,
    hold: HOLD,
    iterations: pick('iterations'),
    dropped_iterations: pick('dropped_iterations'),
    http_reqs: pick('http_reqs'),
    server_errors: pick('server_errors'),
    captured: pick('captured'),
    payment_latency_ms: pick('payment_latency'),
    vus_max: pick('vus_max'),
    thresholds_passed: Object.fromEntries(
      Object.entries(data.metrics)
        .filter(([, m]) => m.thresholds)
        .map(([name, m]) => [name, Object.values(m.thresholds).every((t) => t.ok)]),
    ),
  };
  return { stdout: `\n===K6-SUMMARY===\n${JSON.stringify(out)}\n===END===\n` };
}

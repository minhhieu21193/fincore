// Steady background traffic for canary analysis. Runs forever (restarted by
// the Deployment when the 24h scenario ends).
import http from 'k6/http';
import { check } from 'k6';

const TARGET = __ENV.TARGET;
const MERCHANTS = ['m_acme', 'm_globex', 'm_initech', 'm_umbrella'];

export const options = {
  discardResponseBodies: true,
  // A new connection per request: kube-proxy balances per connection, so
  // reused keep-alive connections would never reach a freshly started canary
  // pod (an ALB on AWS balances per request anyway).
  noConnectionReuse: true,
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 10),
      timeUnit: '1s',
      duration: '24h',
      preAllocatedVUs: 20,
      // Bounded concurrency, like a real client fleet: if the platform slows
      // down, k6 drops iterations instead of piling up connections (with 100
      // VUs a slow spell turned into a self-sustaining overload).
      maxVUs: 30,
    },
  },
};

export default function () {
  const body = JSON.stringify({
    merchant_id: MERCHANTS[Math.floor(Math.random() * MERCHANTS.length)],
    amount: 100 + Math.floor(Math.random() * 9900),
    currency: 'USD',
    card_token: Math.random() < 0.03 ? 'tok_decline' : 'tok_visa',
  });
  const res = http.post(`${TARGET}/v1/payments`, body, {
    headers: {
      'Content-Type': 'application/json',
      'Idempotency-Key': `traffic-${__VU}-${__ITER}-${Date.now()}`,
    },
    timeout: '10s',
  });
  check(res, { 'no server error': (r) => r.status > 0 && r.status < 500 });
}

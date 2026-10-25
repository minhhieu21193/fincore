// Steady background traffic for canary analysis. Runs forever (restarted by
// the Deployment when the 24h scenario ends).
import http from 'k6/http';
import { check } from 'k6';

const TARGET = __ENV.TARGET;
const MERCHANTS = ['m_acme', 'm_globex', 'm_initech', 'm_umbrella'];

export const options = {
  discardResponseBodies: true,
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 10),
      timeUnit: '1s',
      duration: '24h',
      preAllocatedVUs: 20,
      maxVUs: 100,
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

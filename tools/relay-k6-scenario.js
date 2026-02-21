import http from 'k6/http';
import { check, sleep } from 'k6';
import exec from 'k6/execution';
import { Rate } from 'k6/metrics';

const publishAcceptedRate = new Rate('relay_publish_accepted_rate');
const pollParseRate = new Rate('relay_poll_parse_rate');
const signerOkRate = new Rate('relay_signer_ok_rate');

function envPositiveInt(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw.length === 0) {
    return fallback;
  }
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return fallback;
  }
  return Math.floor(parsed);
}

function envNonNegativeInt(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw.length === 0) {
    return fallback;
  }
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return fallback;
  }
  return Math.floor(parsed);
}

function envString(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || raw.length === 0) {
    return fallback;
  }
  return raw;
}

const relayBaseUrl = envString('RELAY_BASE_URL', 'http://127.0.0.1:8787');
const relayRoom = envString('RELAY_ROOM', 'main');
const relayTopic = envString('RELAY_TOPIC', 'notify');
const relaySenderPrefix = envString('RELAY_SENDER_PREFIX', 'k6');
const relayPayloadWrapped = envString('RELAY_PAYLOAD_WRAPPED', '0') === '1';
const relaySignerUrl = envString('RELAY_SIGNER_URL', '');
const benchDuration = envString('K6_BENCH_DURATION', '30s');
const publishRate = envNonNegativeInt('K6_PUBLISH_RATE', 200);
const publishPreAllocatedVUs = envPositiveInt('K6_PUBLISH_PREALLOCATED_VUS', 30);
const publishMaxVUs = envPositiveInt('K6_PUBLISH_MAX_VUS', 200);
const pollVUs = envNonNegativeInt('K6_POLL_VUS', 10);
const pollLimit = envPositiveInt('K6_POLL_LIMIT', 200);
const pollSleepMs = envNonNegativeInt('K6_POLL_SLEEP_MS', 200);
const pollAfterDefault = envNonNegativeInt('K6_POLL_AFTER', 0);

let pollAfterCursor = pollAfterDefault;

const scenarios = {};
const thresholds = {
  http_req_failed: ['rate<0.01'],
};

if (publishRate > 0) {
  scenarios.publish_stream = {
    executor: 'constant-arrival-rate',
    exec: 'publishScenario',
    rate: publishRate,
    timeUnit: '1s',
    duration: benchDuration,
    preAllocatedVUs: publishPreAllocatedVUs,
    maxVUs: publishMaxVUs,
  };
  thresholds['http_req_duration{endpoint:publish}'] = ['p(95)<600', 'p(99)<1200'];
  thresholds.relay_publish_accepted_rate = ['rate>0.95'];
  if (relaySignerUrl.length > 0) {
    thresholds.relay_signer_ok_rate = ['rate>0.99'];
  }
}

if (pollVUs > 0) {
  scenarios.poll_stream = {
    executor: 'constant-vus',
    exec: 'pollScenario',
    vus: pollVUs,
    duration: benchDuration,
  };
  thresholds['http_req_duration{endpoint:poll}'] = ['p(95)<500', 'p(99)<1000'];
  thresholds.relay_poll_parse_rate = ['rate>0.99'];
}

if (Object.keys(scenarios).length === 0) {
  throw new Error('at least one scenario must be enabled (K6_PUBLISH_RATE>0 or K6_POLL_VUS>0)');
}

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'],
  thresholds,
  scenarios,
};

export function setup() {
  const url = `${relayBaseUrl}/health`;
  const response = http.get(url, {
    tags: { endpoint: 'health' },
  });
  const ok = check(response, {
    'health status is 200': (r) => r.status === 200,
  });
  if (!ok) {
    throw new Error(`health check failed: ${url} status=${response.status}`);
  }
}

function buildRecord(sender, id) {
  const ts = Math.floor(Date.now() / 1000);
  return [
    'version 1',
    `key hub/issue/${id}/meta`,
    'kind hub.issue',
    `clock ${sender}=1`,
    `timestamp ${ts}`,
    `node ${sender}`,
    'deleted 0',
    '',
    `{"title":"k6-${sender}","body":"relay benchmark ${id}"}`,
  ].join('\n');
}

function buildPublishPayload(sender, id) {
  return {
    kind: 'hub.record',
    record: buildRecord(sender, id),
  };
}

export function publishScenario() {
  const sender = `${relaySenderPrefix}-vu${exec.vu.idInTest}`;
  const id = `k6-${sender}-${exec.scenario.iterationInTest}-${Date.now()}`;
  const payload = buildPublishPayload(sender, id);
  const bodyPayload = relayPayloadWrapped ? { payload } : payload;
  const requestBody = JSON.stringify(bodyPayload);
  const query =
    `room=${encodeURIComponent(relayRoom)}` +
    `&sender=${encodeURIComponent(sender)}` +
    `&topic=${encodeURIComponent(relayTopic)}` +
    `&id=${encodeURIComponent(id)}`;
  const headers = { 'Content-Type': 'application/json' };
  if (relaySignerUrl.length > 0) {
    const signerRequest = JSON.stringify({
      sender,
      room: relayRoom,
      id,
      topic: relayTopic,
      payload: bodyPayload,
    });
    const signerResponse = http.post(`${relaySignerUrl}/sign`, signerRequest, {
      headers: { 'Content-Type': 'application/json' },
      tags: { endpoint: 'signer' },
    });
    const signerStatusOk = check(signerResponse, {
      'signer status is 200': (r) => r.status === 200,
    });
    if (!signerStatusOk) {
      signerOkRate.add(false);
      publishAcceptedRate.add(false);
      return;
    }
    let signerHeaders = null;
    try {
      const signerBody = signerResponse.json();
      signerHeaders = signerBody && signerBody.headers ? signerBody.headers : null;
    } catch (_err) {
      signerHeaders = null;
    }
    if (!signerHeaders) {
      signerOkRate.add(false);
      publishAcceptedRate.add(false);
      return;
    }
    signerOkRate.add(true);
    headers['x-relay-public-key'] = String(signerHeaders['x-relay-public-key'] ?? '');
    headers['x-relay-signature'] = String(signerHeaders['x-relay-signature'] ?? '');
    headers['x-relay-timestamp'] = String(signerHeaders['x-relay-timestamp'] ?? '');
    headers['x-relay-nonce'] = String(signerHeaders['x-relay-nonce'] ?? '');
  }
  const response = http.post(`${relayBaseUrl}/api/v1/publish?${query}`, requestBody, {
    headers,
    tags: { endpoint: 'publish' },
  });
  const statusOk = check(response, {
    'publish status is 200': (r) => r.status === 200,
  });
  if (!statusOk) {
    publishAcceptedRate.add(false);
    return;
  }
  let accepted = false;
  try {
    const body = response.json();
    accepted = body && body.accepted === true;
  } catch (_err) {
    accepted = false;
  }
  publishAcceptedRate.add(accepted);
}

export function pollScenario() {
  const query =
    `room=${encodeURIComponent(relayRoom)}` +
    `&after=${pollAfterCursor}` +
    `&limit=${pollLimit}`;
  const response = http.get(`${relayBaseUrl}/api/v1/poll?${query}`, {
    tags: { endpoint: 'poll' },
  });
  const statusOk = check(response, {
    'poll status is 200': (r) => r.status === 200,
  });
  if (!statusOk) {
    pollParseRate.add(false);
    if (pollSleepMs > 0) {
      sleep(pollSleepMs / 1000);
    }
    return;
  }
  let parsedOk = false;
  try {
    const body = response.json();
    if (body && Number.isFinite(body.next_cursor)) {
      pollAfterCursor = Math.max(pollAfterCursor, Math.floor(body.next_cursor));
      parsedOk = true;
    }
  } catch (_err) {
    parsedOk = false;
  }
  pollParseRate.add(parsedOk);
  if (pollSleepMs > 0) {
    sleep(pollSleepMs / 1000);
  }
}

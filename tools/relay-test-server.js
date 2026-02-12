#!/usr/bin/env node
// Minimal relay server for hub sync e2e tests.
// Usage: node relay-test-server.js <port>

const http = require('http');

const port = parseInt(process.argv[2] || '8787', 10);
const envelopes = [];
let autoId = 1;

function writeJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-cache',
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      resolve(Buffer.concat(chunks).toString('utf8'));
    });
  });
}

function parsePositiveInt(raw, fallback) {
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    return fallback;
  }
  return Math.floor(value);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${port}`);
  const auth = req.headers.authorization || '';

  if (req.method === 'GET' && url.pathname === '/health') {
    writeJson(res, 200, { ok: true });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/v1/publish') {
    const rawBody = await readBody(req);
    let bodyObj = {};
    try {
      bodyObj = rawBody.length > 0 ? JSON.parse(rawBody) : {};
    } catch (err) {
      writeJson(res, 400, { ok: false, error: `invalid json: ${String(err)}` });
      return;
    }
    const payload =
      bodyObj && typeof bodyObj.payload === 'object' && bodyObj.payload !== null
        ? bodyObj.payload
        : {};
    const eventId = url.searchParams.get('id') || `msg-${autoId++}`;
    const room = url.searchParams.get('room') || 'main';
    const sender = url.searchParams.get('sender') || 'bit';
    const topic = url.searchParams.get('topic') || 'notify';
    envelopes.push({
      room,
      id: eventId,
      sender,
      topic,
      payload,
      signature: null,
    });
    console.log(`AUTH publish ${auth}`);
    writeJson(res, 200, {
      ok: true,
      accepted: true,
      cursor: envelopes.length,
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/v1/poll') {
    const after = parsePositiveInt(url.searchParams.get('after') || '0', 0);
    const limit = parsePositiveInt(url.searchParams.get('limit') || '200', 200);
    const room = url.searchParams.get('room') || 'main';
    const selected = envelopes.slice(after, after + limit);
    console.log(`AUTH poll ${auth}`);
    writeJson(res, 200, {
      ok: true,
      room,
      next_cursor: envelopes.length,
      envelopes: selected,
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/debug/state') {
    writeJson(res, 200, {
      ok: true,
      count: envelopes.length,
      envelopes,
    });
    return;
  }

  writeJson(res, 404, { ok: false, error: 'not found' });
});

server.listen(port, () => {
  console.log(`Relay test server started on http://127.0.0.1:${port}`);
});

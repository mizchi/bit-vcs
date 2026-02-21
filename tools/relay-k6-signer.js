#!/usr/bin/env node
/* eslint-disable no-console */

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');

function toBase64Url(buffer) {
  return buffer.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function canonicalizeJson(value) {
  if (value === null) return 'null';
  const t = typeof value;
  if (t === 'string' || t === 'number' || t === 'boolean') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalizeJson(item)).join(',')}]`;
  }
  if (t === 'object') {
    const keys = Object.keys(value).sort();
    const parts = keys.map((key) => `${JSON.stringify(key)}:${canonicalizeJson(value[key])}`);
    return `{${parts.join(',')}}`;
  }
  return 'null';
}

function sha256Hex(text) {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}

function buildPublishSigningMessage(input) {
  return [
    'v1',
    `sender=${input.sender}`,
    `room=${input.room}`,
    `id=${input.id}`,
    `topic=${input.topic}`,
    `ts=${input.ts}`,
    `nonce=${input.nonce}`,
    `payload_sha256=${input.payloadHash}`,
  ].join('\n');
}

function readPrivateKey() {
  const keyFile = process.env.RELAY_SIGN_PRIVATE_KEY_FILE || process.env.BIT_RELAY_SIGN_PRIVATE_KEY_FILE;
  if (!keyFile) {
    throw new Error('RELAY_SIGN_PRIVATE_KEY_FILE or BIT_RELAY_SIGN_PRIVATE_KEY_FILE is required');
  }
  const content = fs.readFileSync(keyFile);
  return crypto.createPrivateKey(content);
}

function resolvePublicKeyBase64Url(privateKey) {
  const fromEnv = process.env.RELAY_SIGN_PUBLIC_KEY || process.env.BIT_RELAY_SIGN_PUBLIC_KEY;
  if (fromEnv && fromEnv.trim().length > 0) {
    return fromEnv.trim();
  }
  const publicKey = crypto.createPublicKey(privateKey);
  const jwk = publicKey.export({ format: 'jwk' });
  if (!jwk || typeof jwk.x !== 'string' || jwk.x.length === 0) {
    throw new Error('failed to derive Ed25519 public key (jwk.x)');
  }
  return jwk.x;
}

function writeJson(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-cache',
  });
  res.end(text);
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
  });
}

function validateSignRequest(parsed) {
  if (!parsed || typeof parsed !== 'object') {
    return 'invalid json payload';
  }
  const required = ['sender', 'room', 'id', 'topic'];
  for (const key of required) {
    if (typeof parsed[key] !== 'string' || parsed[key].trim().length === 0) {
      return `missing field: ${key}`;
    }
  }
  if (!Object.prototype.hasOwnProperty.call(parsed, 'payload')) {
    return 'missing field: payload';
  }
  return null;
}

async function main() {
  const privateKey = readPrivateKey();
  const publicKey = resolvePublicKeyBase64Url(privateKey);
  const port = Number.parseInt(process.argv[2] || process.env.RELAY_SIGNER_PORT || '18788', 10);
  const listenPort = Number.isFinite(port) && port > 0 ? port : 18788;

  const server = http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url === '/health') {
      writeJson(res, 200, { ok: true });
      return;
    }
    if (req.method !== 'POST' || req.url !== '/sign') {
      writeJson(res, 404, { ok: false, error: 'not found' });
      return;
    }
    const raw = await readBody(req);
    let parsed = null;
    try {
      parsed = raw.length > 0 ? JSON.parse(raw) : null;
    } catch (_err) {
      writeJson(res, 400, { ok: false, error: 'invalid json payload' });
      return;
    }
    const validationError = validateSignRequest(parsed);
    if (validationError) {
      writeJson(res, 400, { ok: false, error: validationError });
      return;
    }

    const sender = parsed.sender.trim();
    const room = parsed.room.trim();
    const id = parsed.id.trim();
    const topic = parsed.topic.trim();
    const payload = parsed.payload;

    const nowMs = Date.now();
    const ts = Math.floor(nowMs / 1000);
    const nonce = `${nowMs}-${id}`;
    const payloadHash = sha256Hex(canonicalizeJson(payload));
    const message = buildPublishSigningMessage({
      sender,
      room,
      id,
      topic,
      ts,
      nonce,
      payloadHash,
    });
    const signature = crypto.sign(null, Buffer.from(message, 'utf8'), privateKey);
    const signatureBase64Url = toBase64Url(signature);

    writeJson(res, 200, {
      ok: true,
      headers: {
        'x-relay-public-key': publicKey,
        'x-relay-signature': signatureBase64Url,
        'x-relay-timestamp': String(ts),
        'x-relay-nonce': nonce,
      },
    });
  });

  server.listen(listenPort, () => {
    console.log(`relay k6 signer started on http://127.0.0.1:${listenPort}`);
  });
}

main().catch((err) => {
  console.error(String(err));
  process.exit(1);
});

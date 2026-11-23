#!/usr/bin/env node
// Stands in for the Samsung app, to test the iPhone app without an Android phone
// (for example next to the iOS Simulator on a Mac). It follows the same rules as
// android/…/ReceiverApi.kt, but keeps the contacts in memory instead of saving them.
//
//   node tools/fake-samsung.js [options]
//     --port <n>             listen here (default 8765)
//     --code <code>          start already paired with this code (for manual pairing)
//     --pairing-open         accept same-Wi-Fi pairing requests at any time
//     --auto-accept          answer "Accept" to every pairing request by itself
//     --advertise-host <h>   the address it tells the iPhone to use afterwards (default 127.0.0.1)
//     --dump <file>          after each upload, write what was received to this JSON file
//                            (photos are replaced by their size)

'use strict';
const http = require('http');
const fs = require('fs');
const crypto = require('crypto');
const zlib = require('zlib');
const P = require('./protocol');

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const opt = (name, fallback) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);

const port = Number(opt('--port', P.PORT));
const advertiseHost = opt('--advertise-host', '127.0.0.1');
const dumpFile = opt('--dump', null);
const PAIRING_WINDOW_MS = 3 * 60 * 1000;
const MAX_BODY = 50 * 1024 * 1024;

const state = {
  code: opt('--code', null) ? P.normalizeCode(opt('--code')) : null,
  pairedDevice: '',
  contacts: new Map(), // id -> hash
  lastSnapshotHash: '',
  lastGeneratedAt: 0,
};
const sessions = new Map();

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const send = (res, status, obj) => {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': body.length, Connection: 'close' });
  res.end(body);
};
const error = (res, status, message) => send(res, status, { error: message });

function authError(req) {
  if (!state.code) return 'Samsung is not paired';
  const token = (req.headers.authorization || '').replace(/^Bearer /, '').trim();
  const want = P.derive(state.code).auth;
  const ok = token.length === want.length && crypto.timingSafeEqual(Buffer.from(token), Buffer.from(want));
  return ok ? null : 'Wrong pairing code — pair again';
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) reject(new Error('too large'));
      else chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function displayName(c) {
  const name = [c.namePrefix, c.givenName, c.middleName, c.familyName, c.nameSuffix].filter(Boolean).join(' ');
  return name || c.organization || (c.phones && c.phones[0] && c.phones[0].value) || '(no name)';
}

function pairStart(res, body) {
  if (!flag('--pairing-open')) return error(res, 403, 'Pairing is not open. On the Samsung, tap "Pair iPhone" first.');
  let iphonePub;
  try {
    iphonePub = Buffer.from(body.pub, 'base64');
    crypto.createPublicKey({ key: iphonePub, format: 'der', type: 'spki' });
  } catch {
    return error(res, 400, 'bad public key');
  }
  const k = P.newPairingKeys();
  const id = crypto.randomBytes(16).toString('hex');
  sessions.clear();
  sessions.set(id, {
    secret: P.ecdh(k.privateKey, iphonePub),
    device: String(body.device || 'iPhone').slice(0, 60),
    createdAt: Date.now(),
    decision: flag('--auto-accept') ? true : null,
    sealed: null,
  });
  log(`pairing request from ${body.device}; number ${P.comparisonNumber(iphonePub, k.pubDer)}`);
  send(res, 200, { session: id, pub: k.pubDer.toString('base64'), device: 'Fake Samsung' });
}

function pairFinish(res, body) {
  const s = sessions.get(body.session);
  if (!s || Date.now() - s.createdAt > PAIRING_WINDOW_MS) return error(res, 410, 'pairing session expired');
  if (s.decision === null) return send(res, 202, { pending: true });
  if (s.decision === false) return error(res, 403, 'Pairing was rejected on the Samsung');
  if (!s.sealed) {
    state.code = P.normalizeCode(P.generateCode());
    state.pairedDevice = s.device;
    state.lastSnapshotHash = '';
    state.lastGeneratedAt = 0;
    const info = { code: state.code, device: 'Fake Samsung', port, tailscale: null, lan: advertiseHost };
    s.sealed = P.sealRaw(P.pairingKey(s.secret), Buffer.from(JSON.stringify(info)));
    log(`paired with ${s.device}; code ${state.code.match(/.{4}/g).join('-')}`);
  }
  send(res, 200, { sealed: s.sealed.toString('base64') });
}

function ping(req, res) {
  const theirs = req.headers['x-snapshot-hash'];
  log(`check-in: ${theirs === undefined ? 'no hash sent' : theirs === state.lastSnapshotHash ? 'up to date' : 'has changes'}`);
  send(res, 200, { lastSnapshotHash: state.lastSnapshotHash, count: state.contacts.size, tailscale: null, lan: advertiseHost });
}

function push(req, res, blob) {
  let snapshot;
  try {
    snapshot = P.open(P.derive(state.code).key, blob); // AES-GCM, then raw DEFLATE, then JSON
  } catch (e) {
    log(`could not read the upload: ${e.message}`);
    return error(res, 400, 'could not decrypt snapshot');
  }
  const list = (snapshot.contacts || []).filter((c) => c.id);
  if ((snapshot.generatedAt || 0) < state.lastGeneratedAt) return error(res, 409, 'older than the snapshot already applied');
  if (list.length === 0 && req.headers['x-allow-empty'] !== '1' && state.contacts.size > 0) {
    return error(res, 422, 'refusing to delete every contact without confirmation');
  }

  let added = 0, updated = 0, deleted = 0;
  const seen = new Map();
  for (const c of list) {
    if (seen.has(c.id)) continue;
    const hash = c.hash || crypto.createHash('sha256').update(JSON.stringify(c)).digest('hex').slice(0, 16);
    seen.set(c.id, hash);
    if (!state.contacts.has(c.id)) added++;
    else if (state.contacts.get(c.id) !== hash) updated++;
  }
  for (const id of state.contacts.keys()) if (!seen.has(id)) deleted++;
  state.contacts = seen;
  state.lastSnapshotHash = req.headers['x-snapshot-hash'] || '';
  state.lastGeneratedAt = snapshot.generatedAt || 0;

  log(`upload: ${blob.length} bytes, ${list.length} contacts -> ${added} added, ${updated} updated, ${deleted} removed`);
  for (const c of list.slice(0, 40)) {
    const parts = [`${(c.phones || []).length} phone`, `${(c.emails || []).length} email`];
    if (c.addresses) parts.push(`${c.addresses.length} address`);
    if (c.birthday) parts.push(`birthday ${c.birthday.year || '----'}-${c.birthday.month}-${c.birthday.day}`);
    if (c.photo) parts.push(`photo ${Buffer.from(c.photo, 'base64').length} B`);
    log(`   ${displayName(c)}  [${parts.join(', ')}]`);
  }
  if (dumpFile) {
    const slim = list.map((c) => (c.photo ? { ...c, photo: `<${Buffer.from(c.photo, 'base64').length} bytes>` } : c));
    fs.writeFileSync(dumpFile, JSON.stringify({ ...snapshot, contacts: slim }, null, 2));
  }
  send(res, 200, { added, updated, deleted, total: seen.size, failed: 0 });
}

const server = http.createServer(async (req, res) => {
  const route = `${req.method} ${req.url.split('?')[0]}`;
  try {
    if (route === 'GET /v1/hello') {
      return send(res, 200, { app: 'contactsync-receiver', device: 'Fake Samsung', paired: !!state.code, pairingOpen: flag('--pairing-open') });
    }
    if (route === 'PUT /v1/contacts') {
      const why = authError(req); // checked before the body is read, like the real app
      if (why) { log(`refused upload: ${why}`); return error(res, 401, why); }
      return push(req, res, await readBody(req, MAX_BODY));
    }
    const text = (await readBody(req, 16 * 1024)).toString('utf8');
    if (route === 'POST /v1/ping') {
      const why = authError(req);
      if (why) { log(`refused check-in: ${why}`); return error(res, 401, why); }
      return ping(req, res);
    }
    let body = {};
    try { body = text ? JSON.parse(text) : {}; } catch { return error(res, 400, 'bad request'); }
    if (route === 'POST /v1/pair/start') return pairStart(res, body);
    if (route === 'POST /v1/pair/finish') return pairFinish(res, body);
    error(res, 404, 'not found');
  } catch (e) {
    error(res, e.message === 'too large' ? 413 : 500, e.message);
  }
});

server.listen(port, () => {
  log(`fake Samsung listening on port ${port}` + (state.code ? `, paired with code ${state.code.match(/.{4}/g).join('-')}` : ', not paired'));
});

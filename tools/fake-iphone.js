#!/usr/bin/env node
// Simulates the iPhone app, to test the Samsung app without a Mac/iPhone.
//
//   node tools/fake-iphone.js pair <samsungIp>                    # same-Wi-Fi pairing (accept on the Samsung)
//   node tools/fake-iphone.js ping <samsungIp> <code>             # what the Samsung has
//   node tools/fake-iphone.js push <samsungIp> <code> [variant] [--stale] [--allow-empty] [--cut]
//
// variants: a = 3 contacts; b = edits one, deletes one, adds one; empty = no contacts;
//           bulk:N[:photoKB] = N generated contacts, each with a photo of about photoKB (default 0 = none).
// --stale sends a snapshot dated in the past; --allow-empty sets X-Allow-Empty;
// --cut drops the connection half-way through the upload, as when the iPhone loses its network.

'use strict';
const crypto = require('crypto');
const P = require('./protocol');

const zlib = require('zlib');

const argv = process.argv.slice(2);
const flags = new Set(argv.filter((a) => a.startsWith('--')));
const [cmd, host, ...rest] = argv.filter((a) => !a.startsWith('--'));
if (!cmd || !host) {
  console.error('usage:\n  fake-iphone.js pair <ip>\n  fake-iphone.js ping <ip> <code>\n' +
    '  fake-iphone.js push <ip> <code> [a|b|empty|bulk:N[:photoKB]] [--stale] [--allow-empty] [--cut]');
  process.exit(1);
}
const base = `http://${host.includes(":") ? host : `${host}:${P.PORT}`}`;

async function post(path, body) {
  const r = await fetch(base + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: r.status, json: await r.json().catch(() => ({})) };
}

async function pair() {
  const k = P.newPairingKeys();
  const start = await post('/v1/pair/start', { pub: k.pubDer.toString('base64'), device: 'Fake iPhone' });
  if (start.status !== 200) throw new Error(`pair/start: ${start.status} ${JSON.stringify(start.json)}`);
  const androidPub = Buffer.from(start.json.pub, 'base64');
  console.log(`Samsung: ${start.json.device}`);
  console.log(`Confirm this number on the Samsung: ${P.comparisonNumber(k.pubDer, androidPub)}`);
  const key = P.pairingKey(P.ecdh(k.privateKey, androidPub));
  for (;;) {
    await new Promise((r) => setTimeout(r, 1000));
    const fin = await post('/v1/pair/finish', { session: start.json.session });
    if (fin.status === 202) continue;
    if (fin.status !== 200) throw new Error(`pair/finish: ${fin.status} ${JSON.stringify(fin.json)}`);
    const info = JSON.parse(P.openRaw(key, Buffer.from(fin.json.sealed, 'base64')).toString('utf8'));
    console.log('Paired:', info);
    return;
  }
}

// A real (decodable) PNG of pseudo-random noise, so it does not compress: about `kb` kilobytes.
function png(seed, kb) {
  const side = Math.max(4, Math.round(Math.sqrt((kb * 1024) / 3)));
  const raw = Buffer.alloc(side * (1 + side * 3));
  let x = (seed * 2654435761) >>> 0 || 1;
  for (let i = 0; i < raw.length; i++) {
    x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0;
    raw[i] = i % (1 + side * 3) === 0 ? 0 : x & 0xff; // filter byte 0 starts each row
  }
  const table = png.table || (png.table = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  }));
  const crc = (buf) => {
    let c = 0xffffffff;
    for (const b of buf) c = table[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const sum = Buffer.alloc(4); sum.writeUInt32BE(crc(body));
    return Buffer.concat([len, body, sum]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(side, 0); ihdr.writeUInt32BE(side, 4);
  ihdr[8] = 8; ihdr[9] = 2; // 8-bit RGB
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 1 })), chunk('IEND', Buffer.alloc(0)),
  ]);
}

function bulk(n, photoKb) {
  const first = ['Dana', 'Yossi', 'Noa', 'Avi', 'Michal', 'שלום', 'רונית', 'Zoë', 'José', 'Anna-Maria'];
  const last = ['Levi', 'Cohen', 'Mizrahi', 'Peretz', 'כהן', 'לוי', "O'Brien", 'Müller', 'Nakamura', 'Smith'];
  return Array.from({ length: n }, (_, i) => {
    const c = {
      id: `bulk-${String(i).padStart(5, '0')}`,
      givenName: first[i % first.length], familyName: `${last[(i * 7) % last.length]} ${i}`,
      phones: [{ label: 'mobile', value: `+972 50-${String(1000000 + i).slice(1, 4)}-${String(10000 + i).slice(1)}` }],
    };
    if (i % 2 === 0) c.emails = [{ label: 'work', value: `user${i}@example.com` }];
    if (i % 3 === 0) c.organization = `Company ${i % 40}`;
    if (i % 5 === 0) c.addresses = [{ label: 'home', street: `Herzl ${i}`, city: 'Tel Aviv', country: 'Israel' }];
    if (i % 7 === 0) c.birthday = { month: 1 + (i % 12), day: 1 + (i % 28), ...(i % 14 === 0 ? { year: 1960 + (i % 50) } : {}) };
    if (photoKb > 0) c.photo = png(i + 1, photoKb).toString('base64');
    return c;
  });
}

function sample(variant) {
  if (variant === 'empty') return [];
  if (variant.startsWith('bulk:')) {
    const [, n, kb] = variant.split(':');
    return hashed(bulk(Number(n), Number(kb || 0)));
  }
  const a = [
    {
      id: 'fake-1', givenName: 'Dana', familyName: 'Levi', organization: 'Acme', jobTitle: 'CTO',
      phones: [{ label: 'mobile', value: '+972 50-123-4567' }, { label: 'work', value: '03-555-1234' }],
      emails: [{ label: 'work', value: 'dana@acme.example' }],
      birthday: { month: 3, day: 14, year: 1990 },
    },
    {
      id: 'fake-2', givenName: 'Yossi', familyName: 'Cohen',
      phones: [{ label: 'Gym', value: '+972 52-765-4321' }],
      addresses: [{ label: 'home', street: 'Herzl 1', city: 'Tel Aviv', postalCode: '6100000', country: 'Israel' }],
    },
    { id: 'fake-3', organization: 'Pizza Place', phones: [{ label: 'main', value: '*1234' }] },
  ];
  const list = variant === 'b'
    ? [{ ...a[0], jobTitle: 'CEO' }, a[2],
       { id: 'fake-4', givenName: 'Noa', nickname: 'Noni', phones: [{ label: 'iphone', value: '+972 54-000-0000' }],
         urls: [{ label: 'homepage', value: 'https://noa.example' }], birthday: { month: 12, day: 1 } }]
    : a;
  return hashed(list);
}

const hashed = (list) => list.map((c) => ({
  ...c,
  hash: crypto.createHash('sha256').update(JSON.stringify(c)).digest('hex').slice(0, 16),
}));

async function push(code, variant = 'a') {
  const { auth, key } = P.derive(code);
  const contacts = sample(variant);
  const snapHash = crypto.createHash('sha256').update(contacts.map((c) => c.hash).join(',')).digest('hex');
  await ping(code, snapHash);
  const headers = { Authorization: `Bearer ${auth}`, 'X-Snapshot-Hash': snapHash, 'Content-Type': 'application/octet-stream' };
  if (flags.has('--allow-empty')) headers['X-Allow-Empty'] = '1';
  const generatedAt = flags.has('--stale') ? Date.now() - 86400000 : Date.now();
  const body = P.seal(key, { v: 1, generatedAt, contacts });
  if (flags.has('--cut')) return cutUpload(headers, body);
  const t0 = Date.now();
  const r = await fetch(`${base}/v1/contacts`, { method: 'PUT', headers, body });
  console.log(`push: ${r.status} ${await r.text()}  (${contacts.length} contacts, ${(body.length / 1024).toFixed(0)} KB, ${Date.now() - t0} ms)`);
}

// Sends the first half of an upload, then drops the connection.
function cutUpload(headers, body) {
  const { hostname, port } = new URL(base);
  const half = body.subarray(0, body.length >> 1);
  return new Promise((resolve) => {
    const socket = require('net').connect(Number(port), hostname, () => {
      const head = Object.entries({ Host: hostname, ...headers, 'Content-Length': body.length })
        .map(([name, value]) => `${name}: ${value}\r\n`).join('');
      socket.write(`PUT /v1/contacts HTTP/1.1\r\n${head}\r\n`);
      socket.write(half, () => setTimeout(() => {
        socket.destroy();
        console.log(`push: cut after ${half.length >> 10} of ${body.length >> 10} KB`);
        resolve();
      }, 500));
    });
    socket.on('error', (e) => { console.log(`push: cut (${e.message})`); resolve(); });
  });
}

// Like the iPhone app, tell the Samsung the hash of what we hold (omitted for a bare `ping`).
async function ping(code, snapHash) {
  const { auth } = P.derive(code);
  const headers = { Authorization: `Bearer ${auth}` };
  if (snapHash) headers['X-Snapshot-Hash'] = snapHash;
  const r = await fetch(`${base}/v1/ping`, { method: 'POST', headers });
  console.log('ping:', r.status, await r.text());
}

const run = { pair, ping: () => ping(rest[0]), push: () => push(rest[0], rest[1]) }[cmd];
if (!run) { console.error(`unknown command: ${cmd}`); process.exit(1); }
run().catch((e) => {
  console.error(e.message);
  process.exit(1);
});

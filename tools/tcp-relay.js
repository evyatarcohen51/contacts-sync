#!/usr/bin/env node
// Passes TCP connections on to another address:
//
//   node tools/tcp-relay.js <listen port> <target host> <target port>
//
// Used by ios/both-apps-check.sh. `adb forward` only listens on 127.0.0.1; this makes the
// Android emulator's port reachable on every address of the Mac, the way a phone on the
// Wi-Fi would be.

'use strict';
const net = require('net');

const [listenPort, targetHost, targetPort] = process.argv.slice(2);
if (!listenPort || !targetHost || !targetPort) {
  console.error('usage: tcp-relay.js <listen port> <target host> <target port>');
  process.exit(1);
}

net.createServer((client) => {
  const target = net.connect(Number(targetPort), targetHost);
  client.pipe(target);
  target.pipe(client);
  let sent = 0;
  let logged = false;
  client.on('data', (chunk) => { sent += chunk.length; });
  const close = () => {
    client.destroy();
    target.destroy();
    // Small requests are check-ins; a large one is an upload of the contacts.
    if (!logged && sent > 4096) console.log(`upload passed through: ${Math.round(sent / 1024)} KB`);
    logged = true;
  };
  client.on('error', close);
  target.on('error', close);
  client.on('close', close);
  target.on('close', close);
}).listen(Number(listenPort), () => console.log(`relay: port ${listenPort} -> ${targetHost}:${targetPort}`));

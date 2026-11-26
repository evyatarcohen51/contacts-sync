#!/usr/bin/env node
// Passes TCP connections on to another address:
//
//   node tools/tcp-relay.js <listen port> <target host> <target port>
//
// Used by ios/both-apps-check.sh. `adb forward` only listens on 127.0.0.1; this makes the
// Android emulator's port reachable on every address of the Mac, the way a phone on the
// Wi-Fi would be. It prints one line per HTTP request that went through, for example
// "PUT /v1/contacts -> 200, 1.3 KB sent", so the check can see a sync happen without
// asking the (slow) emulator.

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
  let request = '';
  let status = '';
  let logged = false;
  client.on('data', (chunk) => {
    if (!sent) request = chunk.toString('latin1').split('\r\n')[0].split(' ').slice(0, 2).join(' ');
    sent += chunk.length;
  });
  target.on('data', (chunk) => {
    if (!status) status = chunk.toString('latin1').split(' ')[1] || '?';
  });
  const close = () => {
    client.destroy();
    target.destroy();
    if (logged) return;
    logged = true;
    console.log(`${request || '(no request)'} -> ${status || 'no answer'}, ${(sent / 1024).toFixed(1)} KB sent`);
  };
  client.on('error', close);
  target.on('error', close);
  client.on('close', close);
  target.on('close', close);
}).listen(Number(listenPort), () => console.log(`relay: port ${listenPort} -> ${targetHost}:${targetPort}`));

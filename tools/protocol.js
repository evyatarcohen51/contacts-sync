// Reference implementation of the ContactSync wire protocol in Node.
// The iOS (Swift/CryptoKit) and Android (Kotlin/javax.crypto) apps implement
// exactly the same steps. Used by fake-iphone.js and to produce test vectors.
//
// Transport: the Samsung listens on TCP 8765 (reachable over Tailscale or the
// local Wi-Fi); the iPhone connects to it and pushes.
//
//   code  = 16 chars from ALPHABET, shown as XXXX-XXXX-XXXX-XXXX
//   auth  = hex(SHA256("contactsync-auth:" + code))   -> "Authorization: Bearer <auth>"
//   key   = SHA256("contactsync-key:" + code)         -> AES-256-GCM key
//   blob  = nonce(12) || AES-GCM(rawDeflate(utf8(json))) || tag(16)
//           (identical to CryptoKit's AES.GCM.SealedBox.combined)
//
// Pairing (same Wi-Fi): P-256 ECDH, public keys as SPKI DER (base64).
//   number     = uint32be(SHA256(iphonePubDer || androidPubDer)[0..4]) % 1e6, 6 digits
//   pairingKey = SHA256(ecdhSecret || "contactsync-pair")
//   /v1/pair/finish returns AES-GCM(pairingKey, json{code, device, port, tailscale, lan})

'use strict';
const crypto = require('crypto');
const zlib = require('zlib');

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const PORT = 8765;

const normalizeCode = (s) => s.toUpperCase().replace(/[^A-Z0-9]/g, '');
const sha = (...parts) => {
  const h = crypto.createHash('sha256');
  parts.forEach((p) => h.update(p));
  return h.digest();
};

function derive(rawCode) {
  const code = normalizeCode(rawCode);
  return {
    code,
    auth: sha('contactsync-auth:' + code).toString('hex'),
    key: sha('contactsync-key:' + code),
  };
}

function generateCode() {
  let out = '';
  for (const b of crypto.randomBytes(16)) out += ALPHABET[b % 32];
  return out.match(/.{4}/g).join('-');
}

function sealRaw(key, plain, nonce = crypto.randomBytes(12)) {
  const c = crypto.createCipheriv('aes-256-gcm', key, nonce);
  const ct = Buffer.concat([c.update(plain), c.final()]);
  return Buffer.concat([nonce, ct, c.getAuthTag()]);
}

function openRaw(key, blob) {
  const d = crypto.createDecipheriv('aes-256-gcm', key, blob.subarray(0, 12));
  d.setAuthTag(blob.subarray(blob.length - 16));
  return Buffer.concat([d.update(blob.subarray(12, blob.length - 16)), d.final()]);
}

const seal = (key, obj, nonce) =>
  sealRaw(key, zlib.deflateRawSync(Buffer.from(JSON.stringify(obj), 'utf8')), nonce);
const open = (key, blob) => JSON.parse(zlib.inflateRawSync(openRaw(key, blob)).toString('utf8'));

// ---- pairing ----
function newPairingKeys() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return { publicKey, privateKey, pubDer: publicKey.export({ type: 'spki', format: 'der' }) };
}

function ecdh(privateKey, theirPubDer) {
  const pub = crypto.createPublicKey({ key: theirPubDer, format: 'der', type: 'spki' });
  return crypto.diffieHellman({ privateKey, publicKey: pub });
}

function comparisonNumber(iphonePubDer, androidPubDer) {
  const h = sha(iphonePubDer, androidPubDer);
  return String(h.readUInt32BE(0) % 1000000).padStart(6, '0');
}

const pairingKey = (secret) => sha(secret, 'contactsync-pair');

module.exports = {
  ALPHABET, PORT, normalizeCode, derive, generateCode, seal, open, sealRaw, openRaw,
  newPairingKeys, ecdh, comparisonNumber, pairingKey,
};

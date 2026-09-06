// Offline public synthetic vectors only. No network, credentials, or receiver.
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import crypto from 'crypto';
import assert from 'assert';

const directory = path.join(path.dirname(fileURLToPath(import.meta.url)),
  'fixtures/signalhub-v2-handoff-8f6df4f');
const load = name => JSON.parse(fs.readFileSync(path.join(directory, name), 'utf8'));
const fixture = load('signature.example.json');
function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])]));
  }
  return value;
}
assert.deepStrictEqual(fixture.vectors.map(vector => vector.type).sort(),
  ['ca_alert', 'heartbeat', 'report']);
for (const vector of fixture.vectors) {
  const canonical = JSON.stringify(sorted(load(vector.fixture)));
  assert.strictEqual(canonical, vector.body, 'canonical bytes: ' + vector.type);
  const digest = crypto.createHash('sha256').update(Buffer.from(vector.body, 'utf8')).digest('hex');
  assert.strictEqual(digest, vector.bodySha256, 'body digest: ' + vector.type);
  const input = ['POST', '/api/wecom/ingest', vector.device, vector.timestamp,
    vector.nonce, digest].join('\n');
  const signature = crypto.createHmac('sha256', Buffer.from(fixture.secret, 'utf8'))
    .update(Buffer.from(input, 'utf8')).digest('hex');
  assert.strictEqual(signature, vector.signature, 'HMAC: ' + vector.type);
}
console.log('Node canonical UTF-8 bytes/SHA256/HMAC: 3/3 PASS; no network requests');

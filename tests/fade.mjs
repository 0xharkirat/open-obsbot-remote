#!/usr/bin/env node
// P4 fade-from-black verification. Needs the fade-capable bridge + one camera.
//
//   node tests/fade.mjs
//
// A fade-from-black darkens the active MJPEG frames from black up to full over
// ~500ms. A darker frame JPEG-compresses much smaller, so we can prove the fade
// without decoding pixels: sample the active stream's frame sizes, trigger a
// faded set_active, and assert the sizes DIP (toward black) then RECOVER.

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';
import http from 'node:http';

const AUTH = JSON.parse(
  fs.readFileSync(`${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`, 'utf8'));
const token = AUTH.tokens[0];

const ws = new WebSocket('ws://localhost:8765/v1');
let nextId = 1;
const acks = new Map();
let lastState = null;
function send(msg) {
  msg.id = String(nextId++);
  return new Promise((res, rej) => {
    const t = setTimeout(() => { acks.delete(msg.id); rej(new Error(`ack timeout ${msg.action}`)); }, 5000);
    acks.set(msg.id, { res: (r) => { clearTimeout(t); res(r); } });
    ws.send(JSON.stringify(msg));
  });
}
ws.on('message', (raw) => {
  const j = JSON.parse(raw.toString());
  if (j.event === 'state') { lastState = j; return; }
  if (j.id && acks.has(j.id)) { acks.get(j.id).res(j); acks.delete(j.id); }
});
ws.on('error', (e) => { console.error('[ws]', e.message); process.exit(2); });

// Collect (t, size) for each MJPEG part on the active stream.
function sampleActive(samples) {
  const req = http.get(
    { host: 'localhost', port: 8766, path: `/preview/active.mjpg?t=${token}`, timeout: 8000 },
    (res) => {
      let buf = Buffer.alloc(0);
      res.on('data', (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        // Parse any complete "Content-Length: N\r\n\r\n<N bytes>\r\n" parts.
        for (;;) {
          const m = /Content-Length:\s*(\d+)\r\n\r\n/i.exec(buf.toString('latin1', 0, Math.min(buf.length, 512)));
          if (!m) break;
          const len = parseInt(m[1], 10);
          const start = m.index + m[0].length;
          if (buf.length < start + len + 2) break;
          samples.push({ t: Date.now(), size: len });
          buf = buf.subarray(start + len + 2);
        }
      });
    });
  req.on('error', () => {});
  return req;
}

await new Promise((r, j) => { ws.once('open', r); ws.once('error', j); });
await send({ action: 'hello', token });
await send({ action: 'subscribe' });
await new Promise((r) => setTimeout(r, 800));
if (!lastState || !lastState.devices?.length) { console.error('no camera'); process.exit(1); }
const active = lastState.active_device_id || lastState.devices[0].device_id;
console.log(`[setup] active=${active}`);

const samples = [];
const req = sampleActive(samples);
await new Promise((r) => setTimeout(r, 600));       // baseline (full brightness)
const triggerT = Date.now();
await send({ action: 'device.set_active', device_id: active, transition: 'fade' });
await new Promise((r) => setTimeout(r, 900));       // capture the fade + recovery
req.destroy();

const before = samples.filter((s) => s.t < triggerT).map((s) => s.size);
const after = samples.filter((s) => s.t >= triggerT);
const baseline = before.length ? before.reduce((a, b) => a + b, 0) / before.length : 0;
const minAfter = after.length ? Math.min(...after.map((s) => s.size)) : 0;
const lastAfter = after.length ? after[after.length - 1].size : 0;

console.log(`\n=== P4 FADE BATTERY ===`);
console.log(`  frames: ${before.length} before, ${after.length} after trigger`);
console.log(`  baseline avg=${Math.round(baseline)}B  min-after=${minAfter}B  last-after=${lastAfter}B`);

let pass = 0, fail = 0;
const test = (name, cond) => {
  if (cond) { pass++; console.log(`  ${name}... PASS`); }
  else { fail++; console.log(`  ${name}... FAIL`); }
};
test('captured baseline + post-trigger frames', before.length >= 2 && after.length >= 3);
test('fade dips frames toward black (min-after < 0.5x baseline)', baseline > 0 && minAfter < 0.5 * baseline);
test('program recovers to full after the fade (last > 0.6x baseline)', lastAfter > 0.6 * baseline);

console.log(`\n=== RESULTS ===\n${pass}/${pass + fail} passed`);
ws.close();
process.exit(fail === 0 ? 0 : 1);

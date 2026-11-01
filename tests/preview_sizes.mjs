#!/usr/bin/env node
// Smaller preview streams (w, fps, q on the MJPEG routes). Needs a running
// bridge and 1 camera that is awake.
//
//   node tests/preview_sizes.mjs
//
// Reads each JPEG's width and height from its SOF marker, so no decoder and
// no new npm dependency. Takes about 55 s: a 5 s camera-rate sample, a 10 s
// fps=10 sample, and a 30 s bitrate sample.

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';
import http from 'node:http';

const AUTH = JSON.parse(
  fs.readFileSync(`${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`, 'utf8'));
const token = AUTH.tokens[0];

// Width and height from a JPEG's start-of-frame marker, or null.
function jpegSize(b) {
  if (b.length < 4 || b[0] !== 0xff || b[1] !== 0xd8) return null;
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) return null;
    const m = b[i + 1];
    if (m === 0xff) { i++; continue; }                      // fill byte
    if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
      return { w: b.readUInt16BE(i + 7), h: b.readUInt16BE(i + 5) };
    }
    if (m === 0xda || m === 0xd9) return null;              // scan or end
    i += 2 + b.readUInt16BE(i + 2);
  }
  return null;
}

// Read an MJPEG stream for `ms`, or until `max` frames. Splits parts on
// Content-Length. Resolves { status, frames: [{ t, size, w, h }], bytes, secs }.
function sample(path, { ms = 3000, max = Infinity } = {}) {
  return new Promise((resolve) => {
    const frames = [];
    const t0 = performance.now();
    let status = 0, bytes = 0, finished = false;
    const done = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      req.destroy();
      resolve({ status, frames, bytes, secs: (performance.now() - t0) / 1000 });
    };
    const timer = setTimeout(done, ms);
    const req = http.get({ host: 'localhost', port: 8766, path }, (res) => {
      status = res.statusCode;
      let buf = Buffer.alloc(0);
      res.on('data', (chunk) => {
        bytes += chunk.length;
        buf = Buffer.concat([buf, chunk]);
        for (;;) {
          const end = buf.indexOf('\r\n\r\n');
          if (end < 0) break;
          const m = /Content-Length:\s*(\d+)/i.exec(buf.toString('latin1', 0, end));
          const start = end + 4;
          if (!m) { buf = buf.subarray(start); continue; }
          const len = Number(m[1]);
          if (buf.length < start + len) break;
          const jpeg = buf.subarray(start, start + len);
          frames.push({ t: performance.now(), size: len, ...jpegSize(jpeg) });
          buf = buf.subarray(start + len);
          if (frames.length >= max) return done();
        }
      });
      res.on('end', done);
    });
    req.on('error', done);
  });
}

// The most frames in any half-open 1 s window.
function maxPerSecond(frames) {
  let best = 0;
  for (let i = 0; i < frames.length; i++) {
    let n = 0;
    for (let j = i; j < frames.length && frames[j].t < frames[i].t + 1000; j++) n++;
    best = Math.max(best, n);
  }
  return best;
}

const ws = new WebSocket('ws://localhost:8765/v1');
let nextId = 1;
const acks = new Map();
let lastState = null;
function send(msg) {
  msg.id = String(nextId++);
  return new Promise((res, rej) => {
    const t = setTimeout(() => { acks.delete(msg.id); rej(new Error(`ack timeout ${msg.action}`)); }, 5000);
    acks.set(msg.id, (r) => { clearTimeout(t); res(r); });
    ws.send(JSON.stringify(msg));
  });
}
ws.on('message', (raw) => {
  const j = JSON.parse(raw.toString());
  if (j.event === 'state') { lastState = j; return; }
  if (j.id && acks.has(j.id)) { acks.get(j.id)(j); acks.delete(j.id); }
});
ws.on('error', (e) => { console.error('[ws]', e.message); process.exit(2); });

await new Promise((r, j) => { ws.once('open', r); ws.once('error', j); });
await send({ action: 'hello', token });
await send({ action: 'subscribe' });
await new Promise((r) => setTimeout(r, 800));
// Close with an explicit code. The bridge (Crow) answers a close with no code
// by sending 1005, which the ws library rejects as an invalid frame.
ws.close(1000);
if (!lastState || !lastState.devices?.length) { console.error('no camera'); process.exit(1); }
const sn = lastState.active_device_id || lastState.devices[0].device_id;
console.log(`[setup] camera=${sn}`);

let pass = 0, fail = 0;
const test = (name, cond, detail = '') => {
  if (cond) { pass++; console.log(`  ${name}... PASS ${detail}`); }
  else { fail++; console.log(`  ${name}... FAIL ${detail}`); }
};
const sizes = (r) => [...new Set(r.frames.map((f) => `${f.w}x${f.h}`))].join(',');
const routes = { 'active.mjpg': '/preview/active.mjpg', [`${sn}.mjpg`]: `/preview/${sn}.mjpg` };

console.log('\n=== SIZES ===');
for (const [name, path] of Object.entries(routes)) {
  const r = await sample(`${path}?t=${token}`, { max: 1 });
  test(`${name} with no parameters: 1st frame 1920x1080`,
    r.frames[0]?.w === 1920 && r.frames[0]?.h === 1080, sizes(r));
  for (const [w, h] of [[640, 360], [960, 540]]) {
    const s = await sample(`${path}?t=${token}&w=${w}`, { max: 5 });
    test(`${name}?w=${w}: 5 frames, all ${w}x${h}`,
      s.frames.length === 5 && s.frames.every((f) => f.w === w && f.h === h), sizes(s));
  }
}

console.log('\n=== TOKEN ===');
{
  const r = await sample(`/preview/${sn}.mjpg?w=640&t=${token}`, { max: 1 });
  test('token after w (?w=640&t=...): 200 and 640x360',
    r.status === 200 && r.frames[0]?.w === 640, `status=${r.status}`);
  const n = await sample(`/preview/${sn}.mjpg?w=640`, { max: 1 });
  test('no token: 401', n.status === 401, `status=${n.status}`);
}

console.log('\n=== RATE ===');
const base = await sample(`/preview/${sn}.mjpg?t=${token}`, { ms: 5000 });
const bf = base.frames;
const camFps = bf.length > 1 ? ((bf.length - 1) * 1000) / (bf[bf.length - 1].t - bf[0].t) : 0;
console.log(`  camera rate (uncapped stream): ${camFps.toFixed(1)} fps`);
{
  const r = await sample(`/preview/${sn}.mjpg?t=${token}&fps=10`, { ms: 11000 });
  const t0 = r.frames[0]?.t ?? 0;
  const in10 = r.frames.filter((f) => f.t < t0 + 10000).length;
  const want = 10 * Math.min(10, camFps);
  test('?fps=10: at most 11 frames in any 1 s', maxPerSecond(r.frames) <= 11,
    `max=${maxPerSecond(r.frames)}`);
  test(`?fps=10: ${Math.round(want)} frames in 10 s, within 5%`,
    want > 0 && Math.abs(in10 - want) <= 0.05 * want, `got=${in10}`);
}

console.log('\n=== BITRATE ===');
{
  const r = await sample(`/preview/${sn}.mjpg?t=${token}&w=640&fps=10&q=0.6`, { ms: 30000 });
  const mbps = (r.bytes * 8) / r.secs / 1e6;
  test('w=640&fps=10&q=0.6 averages 4 Mbps or less over 30 s',
    r.frames.length > 0 && mbps <= 4, `${mbps.toFixed(2)} Mbps, ${sizes(r)}`);
}

console.log(`\n=== RESULTS ===\n${pass}/${pass + fail} passed`);
process.exit(fail === 0 ? 0 : 1);

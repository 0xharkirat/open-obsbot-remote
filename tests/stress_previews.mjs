#!/usr/bin/env node
// Preview soak: runs the whole preview path for a set time and fails on a
// regression in frame rate or bridge memory. Needs a running bridge and 1 or
// more cameras that are awake.
//
//   node tests/stress_previews.mjs [--minutes 2] [--tiles 4] [--stage 0]
//
// Opens --tiles tile previews (w=640&fps=10&q=0.6, spread across the cameras
// on /preview/<sn>.mjpg), --stage stage previews (w=960&fps=15&q=0.7 on
// active.mjpg), and 1 full active.mjpg. Every 20 s it TAKEs the next camera
// with a 500 ms crossfade (with 1 camera, it re-takes the same one, which
// still runs the fade path). Fails when a stream averages below 90% of
// min(requested fps, camera rate), or when the bridge's resident memory at
// the end is more than 20% above its value after a 30 s warm-up.

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';
import http from 'node:http';
import { execFileSync } from 'node:child_process';

const arg = (name, def) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 && process.argv[i + 1] !== undefined ? Number(process.argv[i + 1]) : def;
};
const MINUTES = arg('minutes', 2), TILES = arg('tiles', 4), STAGE = arg('stage', 0);
const RUN_MS = MINUTES * 60000, WARM_MS = Math.min(30000, RUN_MS / 2);

const AUTH = JSON.parse(
  fs.readFileSync(`${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`, 'utf8'));
const token = AUTH.tokens[0];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Count the frames and bytes of an MJPEG stream (parts split on Content-Length)
// into `s`, which it returns.
function openStream(path, s = {}) {
  Object.assign(s, { path, frames: 0, bytes: 0, first: 0, status: 0, closed: false });
  s.req = http.get({ host: 'localhost', port: 8766, path }, (res) => {
    s.status = res.statusCode;
    let buf = Buffer.alloc(0);
    res.on('data', (chunk) => {
      s.bytes += chunk.length;
      buf = Buffer.concat([buf, chunk]);
      for (;;) {
        const end = buf.indexOf('\r\n\r\n');
        if (end < 0) break;
        const m = /Content-Length:\s*(\d+)/i.exec(buf.toString('latin1', 0, end));
        const start = end + 4;
        if (!m) { buf = buf.subarray(start); continue; }
        const len = Number(m[1]);
        if (buf.length < start + len) break;
        if (!s.first) s.first = performance.now();
        s.frames++;
        buf = buf.subarray(start + len);
      }
    });
    res.on('end', () => { s.closed = true; });
  });
  s.req.on('error', () => { s.closed = true; });
  return s;
}

// The bridge process: whoever listens on the MJPEG port.
function bridgeStats() {
  try {
    const pid = execFileSync('lsof', ['-nP', '-iTCP:8766', '-sTCP:LISTEN', '-t'])
      .toString().trim().split('\n')[0];
    const [cpu, rss] = execFileSync('ps', ['-o', '%cpu=,rss=', '-p', pid])
      .toString().trim().split(/\s+/).map(Number);
    return { cpu, rssMb: rss / 1024 };
  } catch {
    return { cpu: NaN, rssMb: NaN };
  }
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
await sleep(800);
if (!lastState || !lastState.devices?.length) { console.error('no camera'); process.exit(1); }
const startActive = lastState.active_device_id;

// Camera rate per camera, from a 4 s uncapped stream. A camera with no
// frames (asleep) is left out.
const rate = {};
for (const d of lastState.devices) {
  const s = openStream(`/preview/${d.device_id}.mjpg?t=${token}`);
  await sleep(4000);
  s.req.destroy();
  const secs = s.first ? (performance.now() - s.first) / 1000 : 0;
  if (s.frames > 1 && secs > 0) rate[d.device_id] = (s.frames - 1) / secs;
  console.log(`[setup] ${d.device_id}: ${rate[d.device_id]?.toFixed(1) ?? 'no video'} fps`);
}
const cams = Object.keys(rate);
if (!cams.length) { console.error('no camera with video'); process.exit(1); }
const minRate = Math.min(...cams.map((c) => rate[c]));

const streams = [];
for (let i = 0; i < TILES; i++) {
  const cam = cams[i % cams.length];
  streams.push(openStream(`/preview/${cam}.mjpg?t=${token}&w=640&fps=10&q=0.6`,
    { name: `tile${i + 1}@${cam}`, want: Math.min(10, rate[cam]) }));
}
for (let i = 0; i < STAGE; i++) {
  streams.push(openStream(`/preview/active.mjpg?t=${token}&w=960&fps=15&q=0.7`,
    { name: `stage${i + 1}@active`, want: Math.min(15, minRate) }));
}
streams.push(openStream(`/preview/active.mjpg?t=${token}`,
  { name: 'full@active', want: minRate }));

console.log(`[run] ${MINUTES} min, ${TILES} tiles, ${STAGE} stage, 1 full; TAKE every 20 s\n`);
const t0 = performance.now();
let take = 0, rssWarm = NaN, lastReport = 0;
const prev = streams.map(() => 0);
let prevBytes = 0;
while (performance.now() - t0 < RUN_MS) {
  await sleep(1000);
  const el = performance.now() - t0;
  if (el >= (take + 1) * 20000) {
    take++;
    const cam = cams[take % cams.length];
    const r = await send({ action: 'device.set_active', device_id: cam, fade_ms: 500 });
    if (!r.ok) console.log(`  TAKE ${cam} failed: ${JSON.stringify(r)}`);
  }
  if (Number.isNaN(rssWarm) && el >= WARM_MS) rssWarm = bridgeStats().rssMb;
  if (el - lastReport >= 10000) {
    const secs = (el - lastReport) / 1000;
    const st = bridgeStats();
    const bytes = streams.reduce((a, s) => a + s.bytes, 0);
    const fps = streams.map((s, i) => `${s.name}=${((s.frames - prev[i]) / secs).toFixed(1)}`);
    console.log(`  t=${Math.round(el / 1000)}s ${fps.join(' ')} | ` +
      `${(((bytes - prevBytes) * 8) / secs / 1e6).toFixed(1)} Mbps | ` +
      `cpu=${st.cpu}% rss=${st.rssMb.toFixed(0)}MB`);
    streams.forEach((s, i) => { prev[i] = s.frames; });
    prevBytes = bytes;
    lastReport = el;
  }
}

const end = performance.now();
for (const s of streams) s.req.destroy();
const rssEnd = bridgeStats().rssMb;
const totalBytes = streams.reduce((a, s) => a + s.bytes, 0);
if (startActive) await send({ action: 'device.set_active', device_id: startActive });
// Close with an explicit code. The bridge (Crow) answers a close with no code
// by sending 1005, which the ws library rejects as an invalid frame.
ws.close(1000);

let pass = 0, fail = 0;
const test = (name, cond, detail) => {
  if (cond) { pass++; console.log(`  ${name}... PASS ${detail}`); }
  else { fail++; console.log(`  ${name}... FAIL ${detail}`); }
};
console.log('\n=== STRESS PREVIEWS ===');
console.log(`  total ${((totalBytes * 8) / ((end - t0) / 1000) / 1e6).toFixed(1)} Mbps`);
for (const s of streams) {
  const avg = s.first ? s.frames / ((end - s.first) / 1000) : 0;
  test(`${s.name} averages >= 90% of ${s.want.toFixed(1)} fps`, avg >= 0.9 * s.want,
    `avg=${avg.toFixed(1)}${s.closed ? ' (stream closed)' : ''}`);
}
test('bridge memory at the end <= 120% of the warm-up value',
  rssEnd <= 1.2 * rssWarm, `warm=${rssWarm.toFixed(0)}MB end=${rssEnd.toFixed(0)}MB`);

console.log(`\n=== RESULTS ===\n${pass}/${pass + fail} passed`);
process.exit(fail === 0 ? 0 : 1);

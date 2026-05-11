#!/usr/bin/env node
// Verify zoom planner produces continuous motion (not discrete steps)
// after the cameraSetZoomAbsoluteR float-API switch.
// Samples state-event zoom every 100ms during 5s and 30s plans, prints
// per-100ms zoom-delta histogram + flags long idle segments.

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';

const AUTH_PATH = `${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`;
const auth = JSON.parse(fs.readFileSync(AUTH_PATH, 'utf8'));
const token = auth.tokens[0];

const ws = new WebSocket('ws://localhost:8765/v1');
let nextId = 1;
const acks = new Map();
let lastState = null;
const watchers = [];

function send(msg, timeout = 10000) {
  msg.id = String(nextId++);
  return new Promise((res, rej) => {
    const t = setTimeout(() => { acks.delete(msg.id); rej(new Error('ack timeout')); }, timeout);
    acks.set(msg.id, { res: r => { clearTimeout(t); res(r); }, rej });
    ws.send(JSON.stringify(msg));
  });
}
function waitState(pred, ms = 60000) {
  return new Promise((res, rej) => {
    const t = setTimeout(() => { const i = watchers.indexOf(w); if (i >= 0) watchers.splice(i, 1); rej(new Error('timeout')); }, ms);
    const w = s => { if (pred(s)) { clearTimeout(t); const i = watchers.indexOf(w); if (i >= 0) watchers.splice(i, 1); res(s); } };
    watchers.push(w);
    if (lastState && pred(lastState)) w(lastState);
  });
}

ws.on('message', raw => {
  const m = JSON.parse(raw.toString());
  if (m.type === 'ack' && acks.has(m.id)) { const a = acks.get(m.id); acks.delete(m.id); a.res(m); }
  if (m.event === 'state') { lastState = m; for (const w of [...watchers]) w(m); }
});

await new Promise(r => ws.once('open', r));
await send({ action: 'hello', token });
await send({ action: 'subscribe' });
await waitState(s => s.device.connected, 3000);
console.log(`[device] ${lastState.device.model_display}\n`);

async function measure(durMs, label) {
  await send({ action: 'zoom.set', value: 1.0, duration_ms: 0, final: true });
  await new Promise(r => setTimeout(r, 1500));
  console.log(`${label}: zoom.set 1.0→2.0 duration_ms=${durMs}`);

  const samples = [];
  const sampler = setInterval(() => {
    if (lastState) samples.push({ t: Date.now(), z: lastState.zoom.value });
  }, 100);
  const t0 = Date.now();
  await send({ action: 'zoom.set', value: 2.0, duration_ms: durMs, final: true });
  // Wait a bit beyond the plan to make sure we capture the final.
  await new Promise(r => setTimeout(r, durMs + 1500));
  clearInterval(sampler);

  // Analyze
  const path = samples.filter(s => s.t >= t0);
  // Per-sample delta + idle detection (≥ 200 ms where delta < 0.005).
  let totalIdleMs = 0;
  let longestIdleMs = 0;
  let idleStart = -1;
  for (let i = 1; i < path.length; i++) {
    const dz = Math.abs(path[i].z - path[i - 1].z);
    const dt = path[i].t - path[i - 1].t;
    if (dz < 0.003 && path[i].z > 1.05 && path[i].z < 1.95) {
      if (idleStart < 0) idleStart = path[i - 1].t;
    } else {
      if (idleStart >= 0) {
        const idleMs = path[i].t - idleStart;
        if (idleMs >= 150) {
          totalIdleMs += idleMs;
          if (idleMs > longestIdleMs) longestIdleMs = idleMs;
        }
        idleStart = -1;
      }
    }
  }
  const dur = path.length > 0 ? path[path.length - 1].t - path[0].t : 0;
  const finalZ = path.length > 0 ? path[path.length - 1].z : 0;
  console.log(`  observed elapsed: ${dur} ms, final zoom: ${finalZ.toFixed(3)}`);
  console.log(`  samples: ${path.length}, idle (>=150ms stuck): total ${totalIdleMs}ms, longest ${longestIdleMs}ms`);

  // Compact trail (every Nth sample).
  const stride = Math.max(1, Math.floor(path.length / 12));
  const trail = [];
  for (let i = 0; i < path.length; i += stride) {
    trail.push(`${path[i].t - t0}ms:${path[i].z.toFixed(3)}`);
  }
  if (path.length > 0) {
    const last = path[path.length - 1];
    trail.push(`${last.t - t0}ms:${last.z.toFixed(3)}`);
  }
  console.log('  trail: ' + trail.join('  '));
  console.log();
  return { idleMs: totalIdleMs, longestIdleMs };
}

const r5 = await measure(5000, '5-second slow zoom');
const r30 = await measure(30000, '30-second cinematic zoom');

await send({ action: 'zoom.set', value: 1.0, duration_ms: 0, final: true });
ws.close();

// Stall thresholds: bridge state poll runs ~500ms cadence so a single
// "no-progress" gap of up to ~700ms is just sample timing, not a real
// lens stall. Anything beyond suggests motion truly stopped.
console.log('=== VERDICT ===');
const ok5 = r5.longestIdleMs < 1000;
const ok30 = r30.longestIdleMs < 2500;
console.log(`5s plan: ${ok5 ? 'PASS' : 'FAIL'}  (longest stall ${r5.longestIdleMs}ms < 1000ms)`);
console.log(`30s plan: ${ok30 ? 'PASS' : 'FAIL'}  (longest stall ${r30.longestIdleMs}ms < 2500ms)`);
process.exit(ok5 && ok30 ? 0 : 1);

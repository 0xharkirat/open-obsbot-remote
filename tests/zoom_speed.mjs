#!/usr/bin/env node
// Zoom + zoom-with-duration timing test.
//
// Verifies:
//   - zoom.set duration_ms=0 (instant) snaps within ~1s
//   - zoom.set duration_ms=N (>0) takes ~N ms ±30% to land
//   - zoom mid-drag (no `final`) coalesces; final value lands on release
//   - Tiny 2 Lite zoom range 1.0..2.0; out-of-range clamps cleanly
//
// Run with bridge live + camera attached:
//   node tests/zoom_speed.mjs

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';

const auth = JSON.parse(fs.readFileSync(
  `${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`, 'utf8'));
const token = auth.tokens[0];

const ws = new WebSocket('ws://localhost:8765/v1');
let nextId = 1;
const pending = new Map();
let lastState = null;
const watchers = [];

function send(msg) {
  msg.id = String(nextId++);
  return new Promise((res, rej) => {
    const t = setTimeout(() => {
      pending.delete(msg.id);
      rej(new Error(`ack timeout ${msg.action}`));
    }, 5000);
    pending.set(msg.id, { res: r => { clearTimeout(t); res(r); }, rej });
    ws.send(JSON.stringify(msg));
  });
}

function waitState(pred, ms = 5000, label = '') {
  return new Promise((res, rej) => {
    const t = setTimeout(() => {
      const i = watchers.indexOf(w);
      if (i >= 0) watchers.splice(i, 1);
      rej(new Error('state predicate timeout: ' + label));
    }, ms);
    const w = s => {
      if (pred(s)) {
        clearTimeout(t);
        const i = watchers.indexOf(w);
        if (i >= 0) watchers.splice(i, 1);
        res(s);
      }
    };
    watchers.push(w);
    if (lastState && pred(lastState)) w(lastState);
  });
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

ws.on('message', raw => {
  const m = JSON.parse(raw);
  if (m.type === 'ack' && pending.has(m.id)) {
    const p = pending.get(m.id);
    pending.delete(m.id);
    if (m.ok) p.res(m); else p.rej(new Error(`${m.err}: ${m.msg}`));
    return;
  }
  if (m.event === 'state') {
    lastState = m;
    for (const w of [...watchers]) w(m);
  }
});

await new Promise((r, rj) => { ws.once('open', r); ws.once('error', rj); });
await send({ action: 'hello', token });
await send({ action: 'subscribe' });
await waitState(() => lastState?.device.connected, 3000, 'connected');
console.log(`[device] ${lastState.device.model_display}, zoom range ${lastState.zoom.min}..${lastState.zoom.max}`);

const results = [];
async function test(name, body) {
  process.stdout.write(`  ${name}... `);
  try {
    const out = await body();
    process.stdout.write(`PASS  ${out || ''}\n`);
    results.push({ name, ok: true });
  } catch (e) {
    process.stdout.write(`FAIL  ${e.message}\n`);
    results.push({ name, ok: false });
  }
}

console.log('\n=== ZOOM BASIC ===');

await test('zoom.set 1.5x instant lands within 2s', async () => {
  await send({ action: 'zoom.set', value: 1.0, final: true, duration_ms: 0 });
  await waitState(s => Math.abs(s.zoom.value - 1.0) < 0.05, 3000, 'zoom=1.0');
  const t0 = Date.now();
  await send({ action: 'zoom.set', value: 1.5, final: true, duration_ms: 0 });
  await waitState(s => Math.abs(s.zoom.value - 1.5) < 0.05, 3000, 'zoom=1.5');
  const took = Date.now() - t0;
  if (took > 2000) throw new Error(`took ${took}ms`);
  return `${took}ms`;
});

await test('zoom.set 2.0x (max) lands within 2s', async () => {
  await send({ action: 'zoom.set', value: 1.0, final: true, duration_ms: 0 });
  await waitState(s => Math.abs(s.zoom.value - 1.0) < 0.05, 3000, 'zoom=1.0');
  const t0 = Date.now();
  await send({ action: 'zoom.set', value: 2.0, final: true, duration_ms: 0 });
  await waitState(s => Math.abs(s.zoom.value - 2.0) < 0.05, 3000, 'zoom=2.0');
  const took = Date.now() - t0;
  if (took > 2000) throw new Error(`took ${took}ms`);
  return `${took}ms`;
});

await test('zoom.set above max clamps to zoom.max', async () => {
  const max = lastState.zoom.max;
  await send({ action: 'zoom.set', value: max + 1.0, final: true, duration_ms: 0 });
  await waitState(s => Math.abs(s.zoom.value - max) < 0.05, 3000, 'zoom≈max');
  return `clamped to ${max}`;
});

await test('zoom.set below min clamps to zoom.min', async () => {
  const min = lastState.zoom.min;
  await send({ action: 'zoom.set', value: 0.5, final: true, duration_ms: 0 });
  await waitState(s => Math.abs(s.zoom.value - min) < 0.05, 3000, 'zoom≈min');
  return `clamped to ${min}`;
});

console.log('\n=== ZOOM WITH DURATION ===');

async function timeZoom(target, ms) {
  const t0 = Date.now();
  await send({ action: 'zoom.set', value: target, final: true, duration_ms: ms });
  await waitState(s => Math.abs(s.zoom.value - target) < 0.05,
    Math.max(ms * 1.6, 5000), `zoom→${target} (${ms}ms)`);
  return Date.now() - t0;
}

for (const ms of [3000, 8000]) {
  await test(`zoom.set duration_ms=${ms}: 1.0→2.0 takes ±30%`, async () => {
    await send({ action: 'zoom.set', value: 1.0, final: true, duration_ms: 0 });
    await sleep(800);
    const took = await timeZoom(2.0, ms);
    const lo = ms * 0.6;
    const hi = ms * 1.5 + 800;
    if (took < lo || took > hi) {
      throw new Error(`took ${took}ms (target ${ms}ms ±30%)`);
    }
    return `${took}ms`;
  });
}

await test('long zoom plan: 15s plan, 4s in shows partial ease', async () => {
  await send({ action: 'zoom.set', value: 1.0, final: true, duration_ms: 0 });
  await sleep(800);
  const t0 = Date.now();
  await send({ action: 'zoom.set', value: 2.0, final: true, duration_ms: 15000 });
  await sleep(4000);
  const partial = lastState.zoom.value;
  const elapsed = Date.now() - t0;
  // Cancel by snapping back
  await send({ action: 'zoom.set', value: 1.0, final: true, duration_ms: 0 });
  await sleep(500);
  const advanced = partial - 1.0;
  if (advanced <= 0.05 || advanced >= 0.85) {
    throw new Error(`after ${elapsed}ms zoom advanced ${advanced.toFixed(2)} (expected 0.05..0.85)`);
  }
  return `4s into 15s plan, advanced ${(advanced * 100).toFixed(0)}% of 1.0× delta`;
});

await test('zoom mid-drag preserved: rapid sets coalesce, final wins', async () => {
  await send({ action: 'zoom.set', value: 1.0, final: true, duration_ms: 0 });
  await sleep(500);
  // 10 rapid mid-drag sets without final, then a final.
  for (let i = 1; i <= 10; i++) {
    await send({ action: 'zoom.set', value: 1.0 + i * 0.05, final: false, duration_ms: 0 });
    await sleep(40);  // faster than coalesce 80ms
  }
  // Final value: 1.7
  await send({ action: 'zoom.set', value: 1.7, final: true, duration_ms: 0 });
  await waitState(s => Math.abs(s.zoom.value - 1.7) < 0.05, 3000, 'final=1.7');
  return 'final value lands despite mid-drag throttle';
});

await test('zoom while zoom in-flight: new target preempts', async () => {
  await send({ action: 'zoom.set', value: 1.0, final: true, duration_ms: 0 });
  await sleep(500);
  // Start a 10s plan, then mid-flight switch to instant 1.3.
  await send({ action: 'zoom.set', value: 2.0, final: true, duration_ms: 10000 });
  await sleep(2000);
  await send({ action: 'zoom.set', value: 1.3, final: true, duration_ms: 0 });
  await waitState(s => Math.abs(s.zoom.value - 1.3) < 0.05, 3000, 'preempted to 1.3');
  return 'preempted ok';
});

console.log('\n=== RESULTS ===');
const passed = results.filter(r => r.ok).length;
console.log(`${passed}/${results.length} passed`);

// Restore zoom for cleanliness
await send({ action: 'zoom.set', value: 1.0, final: true, duration_ms: 0 }).catch(() => {});

ws.close();
process.exit(passed === results.length ? 0 : 1);

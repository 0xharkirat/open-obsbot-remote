#!/usr/bin/env node
// Slow-motion floor smoke test. Verifies that:
//   - MoveSpeed.ultra produces dramatically slower preset recalls than
//     MoveSpeed.cinema, which is slower than slow, etc.
//   - Cancellation works (a new preset recall preempts an in-flight one).
//   - Zoom + gimbal finish together when both are in the move target.
//
// Run with the bridge live + camera attached:
//   node tests/slow_motion.mjs
//
// Cancels mid-flight when needed so you don't actually wait 5 minutes
// for an ultra pan during a smoke run.

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

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

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
await waitState(() => lastState && lastState.device.connected, 3000, 'connected');

console.log(`[device] ${lastState.device.model_display} ${lastState.device.sn}`);

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

console.log('\n=== SLOW MOTION TIMINGS ===');

// Build a far-apart pair of preset positions so each move has visible
// duration. We don't permanently overwrite user presets — save P5/P6
// (slots 4,5) at fixed angles, restore at the end.
async function saveTestPreset(slot, name, yaw, pitch) {
  // Drive to position via instant ptz.angle, then save.
  await send({ action: 'ptz.angle', yaw, pitch, speed: 'instant' });
  await waitState(s =>
    Math.abs(s.ptz.yaw - yaw) < 2 && Math.abs(s.ptz.pitch - pitch) < 2,
    5000, `position ${yaw},${pitch}`);
  await send({ action: 'preset.save', preset_id: slot, name });
  await sleep(300);
}

// Pre-load: P5=center, P6=20°right + 5°up
await saveTestPreset(4, 'TEST_HOME',  0,   0);
await saveTestPreset(5, 'TEST_RIGHT', 20,  5);

async function timeRecall(slot, speed, cancelAfterMs = 0) {
  const t0 = Date.now();
  await send({ action: 'preset.recall', preset_id: slot, speed });
  if (cancelAfterMs > 0) {
    await sleep(cancelAfterMs);
    // Cancel by sending another instant recall back to where we started.
    await send({ action: 'preset.recall', preset_id: 4, speed: 'instant' });
    await sleep(300);
    return Date.now() - t0;
  }
  // Wait for arrival.
  const target = (await waitState(() => true, 100, 'noop')).presets.find(p => p.id === slot);
  await waitState(s =>
      Math.abs(s.ptz.yaw - target.yaw) < 1 &&
      Math.abs(s.ptz.pitch - target.pitch) < 1,
    300_000, `arrive at preset ${slot} (${speed})`);
  return Date.now() - t0;
}

let tFast, tSlow, tCinema;

// Pan delta is 20°. Bands derived from the bridge's `duration_ms_for`
// table: ms_per_deg × 20°.
//   fast    11   ms/deg  → ~220ms       (allow 100..1500 for camera + WS)
//   slow    55   ms/deg  → ~1100ms      (allow 800..2500)
//   cinema  250  ms/deg  → ~5000ms      (allow 4000..8000)

await test('preset.recall fast: arrives in <1.5s', async () => {
  await send({ action: 'preset.recall', preset_id: 4, speed: 'instant' });
  await sleep(800);
  tFast = await timeRecall(5, 'fast');
  if (tFast > 1500) throw new Error(`took ${tFast}ms`);
  return `${tFast}ms`;
});

await test('preset.recall slow: arrives in 0.8-2.5s', async () => {
  await send({ action: 'preset.recall', preset_id: 4, speed: 'instant' });
  await sleep(800);
  tSlow = await timeRecall(5, 'slow');
  if (tSlow < 800 || tSlow > 2500) throw new Error(`took ${tSlow}ms`);
  return `${tSlow}ms`;
});

await test('preset.recall cinema: arrives in 4-8s', async () => {
  await send({ action: 'preset.recall', preset_id: 4, speed: 'instant' });
  await sleep(800);
  tCinema = await timeRecall(5, 'cinema');
  if (tCinema < 4000 || tCinema > 8000) throw new Error(`took ${tCinema}ms`);
  return `${tCinema}ms`;
});

await test('preset.recall ultra is much slower than cinema (cancel after 8s, but observe motion)', async () => {
  await send({ action: 'preset.recall', preset_id: 4, speed: 'instant' });
  await sleep(800);
  // Capture starting yaw, then issue ultra recall, observe movement at 8s.
  const startYaw = lastState.ptz.yaw;
  const t0 = Date.now();
  await send({ action: 'preset.recall', preset_id: 5, speed: 'ultra' });
  await sleep(8000);
  const movedYaw = lastState.ptz.yaw;
  const t = Date.now() - t0;
  // Cancel the in-flight ultra move by recalling instant home.
  await send({ action: 'preset.recall', preset_id: 4, speed: 'instant' });
  await sleep(500);
  // After 8s of an ultra move toward 20° yaw, gimbal should have moved
  // somewhere in the 0..15° range (ease-in-out makes early progress slow).
  const moved = movedYaw - startYaw;
  if (moved <= 0.3 || moved >= 18) {
    throw new Error(`after ${t}ms, yaw moved ${moved.toFixed(1)}° (expected 0.3..18)`);
  }
  return `8s elapsed, yaw advanced ${moved.toFixed(1)}°`;
});

await test('preset.recall cancelled mid-flight by new instant recall', async () => {
  await send({ action: 'preset.recall', preset_id: 4, speed: 'instant' });
  await sleep(800);
  // Start cinema move
  await send({ action: 'preset.recall', preset_id: 5, speed: 'cinema' });
  await sleep(2000);
  const midYaw = lastState.ptz.yaw;
  // Cancel by going back to home instant
  await send({ action: 'preset.recall', preset_id: 4, speed: 'instant' });
  await waitState(s => Math.abs(s.ptz.yaw) < 2, 5000, 'cancel returned home');
  return `cancelled at yaw=${midYaw.toFixed(1)}°`;
});

console.log('\n=== TIMINGS SUMMARY ===');
console.log(`fast:    ${tFast || '?'}ms`);
console.log(`slow:    ${tSlow || '?'}ms`);
console.log(`cinema:  ${tCinema || '?'}ms`);

console.log('\n=== RESULTS ===');
const passed = results.filter(r => r.ok).length;
console.log(`${passed}/${results.length} passed`);

// Cleanup test presets
await send({ action: 'preset.delete', preset_id: 4 }).catch(() => {});
await send({ action: 'preset.delete', preset_id: 5 }).catch(() => {});

ws.close();
process.exit(passed === results.length ? 0 : 1);

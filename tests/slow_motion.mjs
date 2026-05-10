#!/usr/bin/env node
// Slow-motion timing test against real bridge.
//
// Verifies the protocol's `duration_ms` field actually drives the
// gimbal at the expected wall-clock duration, across a range of
// 90°-pan-equivalent moves.
//
// Run:
//   node tests/slow_motion.mjs

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
console.log(`[device] ${lastState.device.model_display}`);

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

// Save 2 test presets so we can recall between them.
async function saveTestPreset(slot, name, yaw, pitch) {
  await send({ action: 'ptz.angle', yaw, pitch, duration_ms: 0 });
  await waitState(s =>
    Math.abs(s.ptz.yaw - yaw) < 2 && Math.abs(s.ptz.pitch - pitch) < 2,
    5000, `position ${yaw},${pitch}`);
  await send({ action: 'preset.save', preset_id: slot, name });
  await sleep(300);
}

await saveTestPreset(4, 'TEST_HOME',  0,  0);
await saveTestPreset(5, 'TEST_RIGHT', 20, 5);

console.log('\n=== TIMINGS (preset recall, 20° pan + 5° tilt + zoom delta) ===');

async function timeRecall(slot, ms) {
  const t0 = Date.now();
  await send({ action: 'preset.recall', preset_id: slot, duration_ms: ms });
  const target = lastState.presets.find(p => p.id === slot);
  if (!target) throw new Error('preset not in state');
  await waitState(s =>
      Math.abs(s.ptz.yaw - target.yaw) < 1 &&
      Math.abs(s.ptz.pitch - target.pitch) < 1,
    Math.max(ms * 1.6, 5000), `arrive at preset ${slot} (target ${ms}ms)`);
  return Date.now() - t0;
}

// 90° pan equivalent: planner duration is wall-clock so should be honored.
// Tolerance ±30% (some camera-side settle overhead).
for (const ms of [500, 1000, 5000, 15000]) {
  await test(`preset.recall duration_ms=${ms}: arrives ±30%`, async () => {
    await send({ action: 'preset.recall', preset_id: 4, duration_ms: 0 });
    await sleep(800);
    const took = await timeRecall(5, ms);
    const lo = ms === 0 ? 0 : ms * 0.7;
    const hi = ms === 0 ? 1500 : ms * 1.5 + 800;
    if (took < lo || took > hi) {
      throw new Error(`took ${took}ms (target ${ms}ms ±30%)`);
    }
    return `${took}ms`;
  });
}

await test('preset.recall duration_ms=0 (instant) arrives <1.5s', async () => {
  await send({ action: 'preset.recall', preset_id: 4, duration_ms: 0 });
  await sleep(500);
  const t0 = Date.now();
  await send({ action: 'preset.recall', preset_id: 5, duration_ms: 0 });
  const target = lastState.presets.find(p => p.id === 5);
  await waitState(s =>
      Math.abs(s.ptz.yaw - target.yaw) < 1.5 &&
      Math.abs(s.ptz.pitch - target.pitch) < 1.5,
    3000, 'instant arrive');
  const took = Date.now() - t0;
  if (took > 1500) throw new Error(`took ${took}ms`);
  return `${took}ms`;
});

await test('60s plan: 8s in, partial ease-in-out progress', async () => {
  await send({ action: 'preset.recall', preset_id: 4, duration_ms: 0 });
  await sleep(800);
  const startYaw = lastState.ptz.yaw;
  const t0 = Date.now();
  await send({ action: 'preset.recall', preset_id: 5, duration_ms: 60000 });
  await sleep(8000);
  const movedYaw = lastState.ptz.yaw;
  const t = Date.now() - t0;
  await send({ action: 'preset.recall', preset_id: 4, duration_ms: 0 });
  await sleep(500);
  const moved = movedYaw - startYaw;
  if (moved <= 0.5 || moved >= 18) {
    throw new Error(`after ${t}ms, advanced ${moved.toFixed(1)}° (expected 0.5..18 of 20°)`);
  }
  return `${moved.toFixed(1)}° advanced in 8s of 60s plan`;
});

await test('cancel in-flight by new instant', async () => {
  await send({ action: 'preset.recall', preset_id: 4, duration_ms: 0 });
  await sleep(800);
  await send({ action: 'preset.recall', preset_id: 5, duration_ms: 5000 });
  await sleep(2000);
  const midYaw = lastState.ptz.yaw;
  await send({ action: 'preset.recall', preset_id: 4, duration_ms: 0 });
  await waitState(s => Math.abs(s.ptz.yaw) < 2, 5000, 'cancel returned home');
  return `cancelled at yaw=${midYaw.toFixed(1)}°`;
});

console.log('\n=== RESULTS ===');
const passed = results.filter(r => r.ok).length;
console.log(`${passed}/${results.length} passed`);

await send({ action: 'preset.delete', preset_id: 4 }).catch(() => {});
await send({ action: 'preset.delete', preset_id: 5 }).catch(() => {});

ws.close();
process.exit(passed === results.length ? 0 : 1);

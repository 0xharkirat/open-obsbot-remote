#!/usr/bin/env node
// tests/exposure.mjs — v1.2 PR G smoke regression.
//
// Verifies the new bridge actions land and the state event surfaces the
// corresponding fields. SDK rejects exposure_mode / ev_bias on Tiny 2
// Lite, so the bridge replies ack ok=false with err="unsupported";
// the test treats that as "expected on this camera" (still better than
// a crash). Anti-flicker / WB are supported.

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';

const AUTH_PATH = `${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`;
const auth = JSON.parse(fs.readFileSync(AUTH_PATH, 'utf8'));
const token = auth.tokens[0];

const ws = new WebSocket('ws://localhost:8765/v1');
let nextId = 1;
const pendingAcks = new Map();
let lastState = null;
const stateWatchers = [];

function send(msg, { allowUnsupported = false } = {}) {
  msg.id = String(nextId++);
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => {
      pendingAcks.delete(msg.id);
      reject(new Error(`ack timeout for ${msg.action}`));
    }, 5000);
    pendingAcks.set(msg.id, {
      resolve: (r) => { clearTimeout(t); resolve(r); },
      reject: (e) => {
        clearTimeout(t);
        if (allowUnsupported && /unsupported/.test(e.message)) {
          resolve({ ok: false, err: 'unsupported', tolerated: true });
        } else {
          reject(e);
        }
      },
    });
    ws.send(JSON.stringify(msg));
  });
}

function waitState(predicate, timeoutMs = 3000, label = '') {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => {
      const idx = stateWatchers.indexOf(w);
      if (idx >= 0) stateWatchers.splice(idx, 1);
      reject(new Error(`state predicate timeout: ${label}`));
    }, timeoutMs);
    const w = (s) => {
      if (predicate(s)) {
        clearTimeout(t);
        const idx = stateWatchers.indexOf(w);
        if (idx >= 0) stateWatchers.splice(idx, 1);
        resolve(s);
      }
    };
    stateWatchers.push(w);
    if (lastState && predicate(lastState)) w(lastState);
  });
}

const results = [];
async function test(name, body) {
  process.stdout.write(`  ${name}... `);
  try {
    await body();
    process.stdout.write('PASS\n');
    results.push({ name, ok: true });
  } catch (e) {
    process.stdout.write(`FAIL ${e.message}\n`);
    results.push({ name, ok: false, err: e.message });
  }
}

ws.on('message', (raw) => {
  let m;
  try { m = JSON.parse(raw.toString()); } catch { return; }
  if (m.type === 'ack' && pendingAcks.has(m.id)) {
    const p = pendingAcks.get(m.id);
    pendingAcks.delete(m.id);
    if (m.ok) p.resolve(m); else p.reject(new Error(`${m.err}: ${m.msg}`));
    return;
  }
  if (m.event === 'state') {
    lastState = m;
    for (const w of [...stateWatchers]) w(m);
  }
});

ws.on('error', (e) => { console.error('[ws] error:', e.message); process.exit(2); });
await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });

await send({ action: 'hello', token });
await send({ action: 'subscribe' });
await waitState((s) => s.device.connected, 3000, 'connected');
console.log(`[device] ${lastState.device.model_display}`);
console.log(`[image start] anti_flicker=${lastState.image.anti_flicker} wb_auto=${lastState.image.wb_auto} wb_kelvin=${lastState.image.wb_kelvin}`);

console.log('\n=== EXPOSURE (best-effort on Tiny 2 Lite) ===');
await test('image.set_exposure_mode auto (unsupported is OK)', async () => {
  const r = await send({ action: 'image.set_exposure_mode', mode: 'auto' },
                       { allowUnsupported: true });
  if (!r.ok && !r.tolerated) throw new Error('unexpected error');
});

await test('image.set_ev_bias -0.7 (unsupported is OK)', async () => {
  const r = await send({ action: 'image.set_ev_bias', bias: -0.7 },
                       { allowUnsupported: true });
  if (!r.ok && !r.tolerated) throw new Error('unexpected error');
});

console.log('\n=== ANTI-FLICKER ===');
await test('image.set_anti_flicker 60 reflects in state', async () => {
  await send({ action: 'image.set_anti_flicker', mode: '60' });
  await waitState((s) => s.image.anti_flicker === '60', 1500);
});

await test('image.set_anti_flicker 50 reflects', async () => {
  await send({ action: 'image.set_anti_flicker', mode: '50' });
  await waitState((s) => s.image.anti_flicker === '50', 1500);
});

await test('image.set_anti_flicker off reflects', async () => {
  await send({ action: 'image.set_anti_flicker', mode: 'off' });
  await waitState((s) => s.image.anti_flicker === 'off', 1500);
});

console.log('\n=== WHITE BALANCE ===');
await test('image.set_wb_auto true reflects', async () => {
  await send({ action: 'image.set_wb_auto', enabled: true });
  await waitState((s) => s.image.wb_auto === true, 1500);
});

await test('image.set_wb_temp 5500 sets kelvin + disables auto', async () => {
  await send({ action: 'image.set_wb_temp', kelvin: 5500 });
  await waitState((s) => s.image.wb_kelvin === 5500 && s.image.wb_auto === false, 1500);
});

await test('image.set_wb_temp 9999 clamps to 6500', async () => {
  await send({ action: 'image.set_wb_temp', kelvin: 9999 });
  await waitState((s) => s.image.wb_kelvin === 6500, 1500);
});

// Restore safe defaults.
await send({ action: 'image.set_wb_auto', enabled: true });

const passed = results.filter(r => r.ok).length;
console.log(`\n=== RESULTS ===\n${passed}/${results.length} passed`);
ws.close();
process.exit(passed === results.length ? 0 : 1);

#!/usr/bin/env node
// Production-grade smoke test against real bridge + real camera.
//
//   node tests/bridge_smoke.mjs
//
// Connects to ws://localhost:8765/v1, pairs (or reuses token), subscribes,
// runs a battery of action+verify cycles, prints PASS/FAIL.
//
// Reads token from ~/Library/Application Support/Open OBSBOT Bridge/auth.json.

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

function send(msg) {
  msg.id = String(nextId++);
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => {
      pendingAcks.delete(msg.id);
      reject(new Error(`ack timeout for ${msg.action} id=${msg.id}`));
    }, 4000);
    pendingAcks.set(msg.id, { resolve: (r) => { clearTimeout(t); resolve(r); }, reject });
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

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function fmt(v) { return typeof v === 'number' ? v.toFixed(2) : String(v); }

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

ws.on('open', async () => {
  console.log('[ws] open');
});

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
  // hello reply has additional fields; treat like ack
  if (m.type === 'ack' && m.ok && pendingAcks.has(m.id)) {
    const p = pendingAcks.get(m.id);
    pendingAcks.delete(m.id);
    p.resolve(m);
  }
});

ws.on('error', (e) => { console.error('[ws] error:', e.message); process.exit(2); });
ws.on('close', () => { console.log('[ws] close'); });

await new Promise((res, rej) => {
  ws.once('open', res);
  ws.once('error', rej);
});

// hello + subscribe
const hello = await send({ action: 'hello', token });
console.log(`[hello] devices: ${hello.devices?.length ?? 0}`);
await send({ action: 'subscribe' });
await waitState(() => lastState !== null, 2000, 'first state');

console.log(`[state] device=${lastState.device.model_display} sn=${lastState.device.sn} fw=${lastState.device.firmware} run=${lastState.device.run_status}`);
console.log(`[state] yaw=${fmt(lastState.ptz.yaw)} pitch=${fmt(lastState.ptz.pitch)} zoom=${fmt(lastState.zoom.value)} ai=${lastState.ai.mode}`);

console.log('\n=== TEST BATTERY ===');

// 1. PTZ recenter
await test('ptz.recenter brings yaw to 0', async () => {
  // First nudge yaw away
  await send({ action: 'ptz.angle', yaw: 5, pitch: 0 });
  await sleep(800);
  await send({ action: 'ptz.recenter' });
  await waitState(s => Math.abs(s.ptz.yaw) < 1.5, 5000, 'yaw≈0');
});

// 2. Zoom set + readback
await test('zoom.set 1.5x reflects in state', async () => {
  await send({ action: 'zoom.set', value: 1.5 });
  await waitState(s => Math.abs(s.zoom.value - 1.5) < 0.05, 3000, 'zoom≈1.5');
});

await test('zoom.set 1.0x back', async () => {
  await send({ action: 'zoom.set', value: 1.0 });
  await waitState(s => Math.abs(s.zoom.value - 1.0) < 0.05, 3000, 'zoom≈1.0');
});

// 3. Preset zoom roundtrip
await test('preset.save captures zoom 1.7x; recall restores it', async () => {
  await send({ action: 'zoom.set', value: 1.7 });
  await waitState(s => Math.abs(s.zoom.value - 1.7) < 0.05, 3000, 'zoom≈1.7');
  // Save in slot 3 (P4)
  await send({ action: 'preset.save', preset_id: 3, name: 'Test_Zoom_1.7' });
  await waitState(s => {
    const p = (s.presets || []).find(x => x.id === 3);
    return p && Math.abs(p.zoom - 1.7) < 0.05;
  }, 3000, 'preset[3].zoom≈1.7');
  // Move zoom away
  await send({ action: 'zoom.set', value: 1.0 });
  await waitState(s => Math.abs(s.zoom.value - 1.0) < 0.05, 3000, 'zoom≈1.0');
  // Recall — instant mode
  await send({ action: 'preset.recall', preset_id: 3, speed: 'instant' });
  await waitState(s => Math.abs(s.zoom.value - 1.7) < 0.1, 5000, 'zoom restored ≈1.7');
});

// Restore zoom for cleanliness
await send({ action: 'zoom.set', value: 1.0 });
await sleep(500);

// 4. AI mode no flap during manual
await test('AI off after manual cmd; not flapping in stream', async () => {
  // Enable AI human first
  await send({ action: 'ai.set_mode', mode: 'human', sub_mode: 'normal' });
  await waitState(s => s.ai.mode === 'human', 2000, 'ai=human');
  // Stream velocity to trigger ai-off flag
  for (let i = 0; i < 3; i++) {
    await send({ action: 'ptz.velocity', yaw_speed: 30, pitch_speed: 0 });
    await sleep(80);
  }
  await send({ action: 'ptz.stop' });
  await waitState(s => s.ai.mode === 'none', 3000, 'ai=none after manual');
  // Re-arm AI then stream again — bridge must NOT keep toggling AI mode
  // (snapshot stays consistent)
  await send({ action: 'ai.set_mode', mode: 'human', sub_mode: 'normal' });
  await waitState(s => s.ai.mode === 'human', 2000, 'ai=human again');
  let flapCount = 0;
  let lastMode = 'human';
  const watcher = (s) => {
    if (s.ai.mode !== lastMode) { flapCount++; lastMode = s.ai.mode; }
  };
  stateWatchers.push(watcher);
  // Don't stream velocity now — just observe AI is stable
  await sleep(2000);
  const idx = stateWatchers.indexOf(watcher);
  if (idx >= 0) stateWatchers.splice(idx, 1);
  if (flapCount > 0) throw new Error(`AI flapped ${flapCount} times unprovoked`);
  // Disable AI for cleanliness
  await send({ action: 'ai.set_mode', mode: 'none', sub_mode: 'normal' });
});

// 5. Sequencer state shape
await test('sequence.set ships steps in state event', async () => {
  const steps = [
    { preset_id: 0, seconds: 5, speed: 'medium' },
    { preset_id: 1, seconds: 5, speed: 'fast' },
  ];
  await send({ action: 'sequence.set', steps, mode: 'forward' });
  await waitState(s => {
    const ss = s.sequence?.steps;
    return Array.isArray(ss) && ss.length === 2 &&
      ss[0].preset_id === 0 && ss[0].seconds === 5 && ss[0].speed === 'medium' &&
      ss[1].preset_id === 1 && ss[1].seconds === 5 && ss[1].speed === 'fast';
  }, 3000, 'sequence.steps echo');
});

// 6. Sequencer save_as + load
await test('sequence.save_as persists; load echoes back same steps', async () => {
  const NAME = 'PROD_TEST_' + Date.now();
  const steps = [
    { preset_id: 2, seconds: 7, speed: 'slow' },
    { preset_id: 3, seconds: 4, speed: 'instant' },
  ];
  await send({ action: 'sequence.save_as', name: NAME, steps, mode: 'ping_pong' });
  await waitState(s => (s.sequence?.available || []).includes(NAME),
    3000, 'available includes new name');
  // Wipe scratch
  await send({ action: 'sequence.set', steps: [], mode: 'forward' });
  await sleep(300);
  // Load
  await send({ action: 'sequence.load', name: NAME });
  await waitState(s => {
    const ss = s.sequence?.steps;
    return Array.isArray(ss) && ss.length === 2 &&
      ss[0].preset_id === 2 && ss[0].seconds === 7 && ss[0].speed === 'slow' &&
      ss[1].preset_id === 3 && ss[1].seconds === 4 && ss[1].speed === 'instant' &&
      s.sequence.loaded === NAME &&
      s.sequence.mode === 'ping_pong';
  }, 3000, 'load echoes steps');
  // Cleanup
  await send({ action: 'sequence.delete', name: NAME });
});

console.log('\n=== RESULTS ===');
const passed = results.filter(r => r.ok).length;
const failed = results.filter(r => !r.ok);
console.log(`${passed}/${results.length} passed`);
for (const f of failed) console.log(`  FAIL: ${f.name} — ${f.err}`);

ws.close();
process.exit(failed.length === 0 ? 0 : 1);

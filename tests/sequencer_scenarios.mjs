#!/usr/bin/env node
// Runs three sequencer scenarios of increasing complexity against a live
// two-camera bridge and logs the observed behaviour (program camera, cue/step,
// phase, active preset) with timestamps, so a human can review what happened.
//
//   node tests/sequencer_scenarios.mjs
//
// It primes presets 6 and 7 on both cameras at distinct poses, runs the
// scenarios, then removes the test presets and restores the starting camera.

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';

const AUTH = JSON.parse(fs.readFileSync(
  `${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`, 'utf8'));
const token = AUTH.tokens[0];
const ws = new WebSocket('ws://localhost:8765/v1');
let nextId = 1;
const acks = new Map();
let state = null;
const t0 = () => (Date.now() - START) / 1000;
let START = Date.now();

function send(msg) {
  msg.id = String(nextId++);
  return new Promise((res) => { acks.set(msg.id, res); ws.send(JSON.stringify(msg)); });
}
ws.on('message', (raw) => {
  const j = JSON.parse(raw.toString());
  if (j.event === 'state') { state = j; return; }
  if (j.id && acks.has(j.id)) { acks.get(j.id)(j); acks.delete(j.id); }
});
ws.on('error', (e) => { console.error('[ws]', e.message); process.exit(2); });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nameOf = (id) => {
  const d = state?.devices?.find((x) => x.device_id === id);
  return d ? (d.device.friendly_name || d.device_id.slice(-5)) : (id || '-').slice(-5);
};

// Log only when something observable changes, so the trace reads as a timeline.
async function watch(label, ms, read) {
  let prev = '';
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const line = read();
    if (line !== prev) { console.log(`  [t+${t0().toFixed(1)}s] ${line}`); prev = line; }
    await sleep(120);
  }
}

await new Promise((r, j) => { ws.once('open', r); ws.once('error', j); });
await send({ action: 'hello', token });
await send({ action: 'subscribe' });
await sleep(700);
const devs = state.devices;
if (devs.length < 2) { console.error('need two cameras'); process.exit(1); }
const A = devs[0].device_id, B = devs[1].device_id;
const startActive = state.active_device_id;

console.log(`cameras: A=${nameOf(A)} (${A}), B=${nameOf(B)} (${B})`);

// ---- prime presets 6 + 7 on both cameras at distinct poses ----
console.log('\n[setup] priming presets 6 (recenter) and 7 (panned) on both cameras...');
for (const cam of [A, B]) {
  await send({ action: 'device.set_active', device_id: cam });
  await sleep(1200); // wake + settle
  await send({ action: 'ptz.recenter', device_id: cam });
  await sleep(800);
  await send({ action: 'preset.save', device_id: cam, preset_id: 6, name: 'SCN_WIDE' });
  await send({ action: 'ptz.angle', device_id: cam, yaw: 25, pitch: -8, duration_ms: 0 });
  await sleep(800);
  await send({ action: 'preset.save', device_id: cam, preset_id: 7, name: 'SCN_TIGHT' });
}
await send({ action: 'device.set_active', device_id: A });
await sleep(600);

// =====================================================================
// SCENARIO 1 - simple: single-camera preset sequence, forward loop
// =====================================================================
START = Date.now();
console.log('\n=== SCENARIO 1 (simple): per-camera sequence on A ===');
console.log('2 steps P6 -> P7, instant moves, 3s hold each, forward loop. ~8s.');
await send({
  action: 'sequence.set', device_id: A, mode: 'forward',
  steps: [
    { preset_id: 6, seconds: 3, transition_ms: 0 },
    { preset_id: 7, seconds: 3, transition_ms: 0 },
  ],
});
await send({ action: 'sequence.start', device_id: A });
await watch('s1', 8000, () => {
  const d = state.devices.find((x) => x.device_id === A);
  const s = d?.sequence;
  return `A seq: step=${s?.step_index} preset=${d?.active_preset_id} phase=${s?.phase} elapsed=${s?.elapsed_s}/${s?.total_s}s`;
});
await send({ action: 'sequence.stop', device_id: A });
console.log(`  [t+${t0().toFixed(1)}s] stopped`);

// =====================================================================
// SCENARIO 2 - medium: cross-camera mix, hard cuts
// =====================================================================
START = Date.now();
console.log('\n=== SCENARIO 2 (medium): mix, hard cuts A -> B -> A ===');
console.log('3 cues, cut, 3s hold each, forward loop. ~11s. Program should switch cameras.');
await send({
  action: 'mix.set', mode: 'forward',
  cues: [
    { camera_sn: A, preset_id: 6, move_ms: 600, hold_s: 3, transition: 'cut' },
    { camera_sn: B, preset_id: 6, move_ms: 600, hold_s: 3, transition: 'cut' },
    { camera_sn: A, preset_id: 7, move_ms: 600, hold_s: 3, transition: 'cut' },
  ],
});
await send({ action: 'mix.start' });
await watch('s2', 11000, () => {
  const m = state.mix;
  return `mix: cue=${m.cue_index}/${m.cue_count} onair=${nameOf(state.active_device_id)} phase=${m.phase} ${m.elapsed_s}/${m.total_s}s`;
});
await send({ action: 'mix.stop' });
console.log(`  [t+${t0().toFixed(1)}s] stopped`);

// =====================================================================
// SCENARIO 3 - complex: mix with fades, a meanwhile pre-position, ping-pong
// =====================================================================
START = Date.now();
console.log('\n=== SCENARIO 3 (complex): mix, fades + meanwhile pre-position + ping-pong ===');
console.log('cue0 A/P6 fade-in; cue1 B/P7 fade-in, meanwhile pre-position A->P7;');
console.log('cue2 A/P7 cut. move 800ms, hold 3s, ping-pong. ~16s.');
await send({
  action: 'mix.set', mode: 'ping_pong',
  cues: [
    { camera_sn: A, preset_id: 6, move_ms: 800, hold_s: 3, transition: 'fade' },
    {
      camera_sn: B, preset_id: 7, move_ms: 800, hold_s: 3, transition: 'fade',
      meanwhile: { camera_sn: A, preset_id: 7, move_ms: 800 },
    },
    { camera_sn: A, preset_id: 7, move_ms: 800, hold_s: 3, transition: 'cut' },
  ],
});
await send({ action: 'mix.start' });
await watch('s3', 16000, () => {
  const m = state.mix;
  const cue = m.cues?.[m.cue_index];
  const via = cue ? cue.transition : '-';
  return `mix: cue=${m.cue_index}/${m.cue_count} onair=${nameOf(state.active_device_id)} via=${via} phase=${m.phase} ${m.elapsed_s}/${m.total_s}s`;
});
await send({ action: 'mix.stop' });
console.log(`  [t+${t0().toFixed(1)}s] stopped`);

// ---- cleanup ----
console.log('\n[cleanup] removing test presets + scratch, restoring active camera...');
await send({ action: 'mix.set', cues: [], mode: 'forward' });
for (const cam of [A, B]) {
  await send({ action: 'sequence.set', device_id: cam, steps: [], mode: 'forward' });
  await send({ action: 'preset.delete', device_id: cam, preset_id: 6 });
  await send({ action: 'preset.delete', device_id: cam, preset_id: 7 });
  await send({ action: 'ptz.recenter', device_id: cam });
}
await send({ action: 'device.set_active', device_id: startActive });
console.log('done.');
ws.close();
process.exit(0);

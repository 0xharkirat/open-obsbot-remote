#!/usr/bin/env node
// P3 mix-sequencer acceptance battery. Run against a bridge with TWO real
// cameras attached.
//
//   node tests/mix_sequence.mjs
//
// Covers the cross-camera sequencer wire contract (mix.set / start / stop /
// save_as / load / delete + the state.mix block) and the ONE behaviour that
// defines this feature: NO on-air movement lock. A cue whose program camera is
// already live still recalls its preset - the camera moves LIVE on air without
// the program switching away. See docs/PROTOCOL.md + project_v2_backlog.md.

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
    }, 5000);
    pendingAcks.set(msg.id, {
      resolve: (r) => { clearTimeout(t); resolve(r); },
      reject: (e) => { clearTimeout(t); reject(e); },
    });
    ws.send(JSON.stringify(msg));
  });
}

async function sendExpectErr(msg) {
  const r = await send(msg);
  if (r.ok !== false) throw new Error(`expected ok:false, got ${JSON.stringify(r).slice(0, 120)}`);
  return r;
}

function waitState(predicate, timeoutMs = 8000, label = '') {
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

ws.on('message', (raw) => {
  const j = JSON.parse(raw.toString());
  if (j.event === 'state') {
    lastState = j;
    for (const w of [...stateWatchers]) w(j);
    return;
  }
  if (j.id && pendingAcks.has(j.id)) {
    const p = pendingAcks.get(j.id);
    pendingAcks.delete(j.id);
    p.resolve(j);
  }
});
ws.on('error', (e) => { console.error('[ws] error:', e.message); process.exit(2); });

let pass = 0, fail = 0;
async function test(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    pass++;
    console.log(`  ${name}... PASS (${Date.now() - t0}ms)`);
  } catch (e) {
    fail++;
    console.log(`  ${name}... FAIL: ${e.message}`);
  }
}
const assert = (cond, msg) => { if (!cond) throw new Error(msg); };
const deviceOf = (s, id) => s.devices.find((d) => d.device_id === id);

await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
await send({ action: 'hello', token });
await send({ action: 'subscribe' });
await waitState((s) => Array.isArray(s.devices), 5000, 'first v2 state');

const devs = lastState.devices;
console.log(`[setup] ${devs.length} device(s): ${devs.map((d) => d.device_id).join(', ')}`);
if (devs.length < 2) {
  console.error('NEED two cameras attached for this battery.');
  process.exit(1);
}
const [A, B] = [devs[0].device_id, devs[1].device_id];
const activeAtStart = lastState.active_device_id;
const MIX_NAME = 'SMOKE_MIX';

// Two distinct saved poses on A so a cue that recalls the second one while A is
// on air produces a visible LIVE move (the no-lock proof). One pose on B.
console.log('[setup] priming presets 6/7 on A, 6 on B...');
await send({ action: 'device.set_active', device_id: A });
await waitState((s) => s.active_device_id === A, 6000, 'A live');
await send({ action: 'ptz.recenter', device_id: A });
await send({ action: 'preset.save', device_id: A, preset_id: 6, name: 'SMOKE_6' });
await send({ action: 'ptz.angle', device_id: A, yaw: 22, pitch: 0, duration_ms: 0 });
await send({ action: 'preset.save', device_id: A, preset_id: 7, name: 'SMOKE_7' });
await send({ action: 'ptz.recenter', device_id: B });
await send({ action: 'preset.save', device_id: B, preset_id: 6, name: 'SMOKE_6' });

console.log('\n=== P3 MIX SEQUENCER BATTERY ===');

await test('state carries a mix block with the expected shape', async () => {
  const m = lastState.mix;
  assert(m && typeof m === 'object', 'no mix block');
  assert(m.running === false, `running=${m.running}`);
  assert(Array.isArray(m.cues), 'cues not array');
  assert(Array.isArray(m.available), 'available not array');
  assert(typeof m.cue_index === 'number', 'cue_index missing');
  assert(['moving', 'holding'].includes(m.phase), `phase=${m.phase}`);
});

const CUES = [
  { camera_sn: A, preset_id: 6, move_ms: 600, hold_s: 2, transition: 'cut' },
  { camera_sn: A, preset_id: 7, move_ms: 600, hold_s: 2, transition: 'cut' },
  { camera_sn: B, preset_id: 6, move_ms: 600, hold_s: 2, transition: 'cut' },
];

await test('mix.set echoes cues into state (loaded cleared to scratch)', async () => {
  const r = await send({ action: 'mix.set', cues: CUES, mode: 'forward' });
  assert(r.ok === true, 'not ok');
  const s = await waitState((st) => st.mix.cue_count === 3, 4000, 'cue_count=3');
  assert(s.mix.loaded === '', `loaded=${s.mix.loaded}`);
  assert(s.mix.cues[0].camera_sn === A && s.mix.cues[0].preset_id === 6, 'cue0 wrong');
  assert(s.mix.cues[2].camera_sn === B, 'cue2 camera wrong');
  assert(s.mix.mode === 'forward', `mode=${s.mix.mode}`);
});

await test('mix.save_as adds to library + marks loaded', async () => {
  const r = await send({ action: 'mix.save_as', name: MIX_NAME, cues: CUES, mode: 'forward' });
  assert(r.ok === true, 'not ok');
  const s = await waitState(
    (st) => st.mix.available.includes(MIX_NAME) && st.mix.loaded === MIX_NAME,
    4000, 'saved + loaded');
  assert(s.mix.available.includes(MIX_NAME), 'not in available');
});

await test('mix.save_as with empty name -> invalid_param', async () => {
  const r = await sendExpectErr({ action: 'mix.save_as', name: '', cues: CUES });
  assert(r.err === 'invalid_param', `err=${r.err}`);
});

await test('mix.set [] clears scratch; mix.load rehydrates from library', async () => {
  await send({ action: 'mix.set', cues: [], mode: 'forward' });
  await waitState((st) => st.mix.cue_count === 0, 4000, 'cleared');
  const r = await send({ action: 'mix.load', name: MIX_NAME });
  assert(r.ok === true, 'load not ok');
  const s = await waitState((st) => st.mix.cue_count === 3, 4000, 'reloaded');
  assert(s.mix.loaded === MIX_NAME, `loaded=${s.mix.loaded}`);
});

await test('mix.load unknown -> not_found', async () => {
  const r = await sendExpectErr({ action: 'mix.load', name: 'NOPE_MIX' });
  assert(r.err === 'not_found', `err=${r.err}`);
});

await test('mix.start -> running true, first cue puts A on air', async () => {
  const r = await send({ action: 'mix.start' });
  assert(r.ok === true, 'not ok');
  await waitState((s) => s.mix.running === true, 4000, 'running');
  await waitState((s) => s.active_device_id === A && s.mix.cue_index === 0, 8000, 'cue0 A live');
});

await test('NO on-air lock: cue1 moves A LIVE (program stays A, shot changes)', async () => {
  // cue0 and cue1 are both camera A. Advancing to cue1 must NOT switch the
  // program away from A - it recalls preset 7 on the already-live camera, so
  // the audience sees A physically move on air. This is the whole point.
  await waitState(
    (s) => s.mix.cue_index === 1 && s.active_device_id === A,
    12000, 'cue1 still on A');
  // The live camera actually took the new shot (preset 7), proving the recall
  // fired on the on-air camera rather than being suppressed.
  await waitState(
    (s) => deviceOf(s, A)?.presets && s.active_device_id === A &&
           deviceOf(s, A).active_preset_id === 7,
    8000, 'A moved to preset 7 while on air');
});

await test('cue2 switches the program to B', async () => {
  await waitState(
    (s) => s.mix.cue_index === 2 && s.active_device_id === B,
    12000, 'cue2 B live');
});

await test('phase reports both moving and holding across the run', async () => {
  // Over one more loop we should observe the moving->holding transition.
  await waitState((s) => s.mix.running && s.mix.phase === 'moving', 12000, 'moving seen');
  await waitState((s) => s.mix.running && s.mix.phase === 'holding', 12000, 'holding seen');
});

await test('mix.stop -> running false, cue_index reset', async () => {
  const r = await send({ action: 'mix.stop' });
  assert(r.ok === true, 'not ok');
  const s = await waitState((st) => st.mix.running === false && st.mix.cue_index === -1,
    5000, 'stopped');
  assert(s.mix.cue_index === -1, `cue_index=${s.mix.cue_index}`);
});

await test('mix.delete removes from library', async () => {
  const r = await send({ action: 'mix.delete', name: MIX_NAME });
  assert(r.ok === true, 'not ok');
  await waitState((st) => !st.mix.available.includes(MIX_NAME), 4000, 'deleted');
});

// ---- cleanup: remove test presets, clear scratch, restore program ----
console.log('\n[cleanup] removing test presets + scratch, restoring active...');
await send({ action: 'mix.set', cues: [], mode: 'forward' });
await send({ action: 'preset.delete', device_id: A, preset_id: 6 });
await send({ action: 'preset.delete', device_id: A, preset_id: 7 });
await send({ action: 'preset.delete', device_id: B, preset_id: 6 });
await send({ action: 'ptz.recenter', device_id: A });
await send({ action: 'device.set_active', device_id: activeAtStart });

console.log(`\n=== RESULTS ===\n${pass}/${pass + fail} passed`);
ws.close();
process.exit(fail === 0 ? 0 : 1);

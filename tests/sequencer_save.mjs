#!/usr/bin/env node
// Sequencer save / load / persistence test against real bridge.
//
// Verifies:
//   - sequence.save_as creates an entry in `sequence.available`
//   - sequence.load echoes back the exact steps + mode + name
//   - sequences.json on disk survives bridge restart (manual)
//   - sequence.delete removes the entry
//
// Run with bridge live + camera attached:
//   node tests/sequencer_save.mjs

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';

const auth = JSON.parse(fs.readFileSync(
  `${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`, 'utf8'));
const SEQUENCES_PATH = `${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/sequences.json`;
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
console.log(`[lib at start] ${(lastState.sequence?.available || []).join(', ') || '(empty)'}`);

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

console.log('\n=== SEQUENCER SAVE / LOAD ===');

const NAME = 'TEST_' + Date.now();
const STEPS = [
  { preset_id: 0, seconds: 5,  transition_ms: 1000 },
  { preset_id: 1, seconds: 8,  transition_ms: 30000 },
  { preset_id: 2, seconds: 10, transition_ms: 0 },
];

await test('save_as: creates entry in sequence.available', async () => {
  await send({ action: 'sequence.save_as', name: NAME, steps: STEPS, mode: 'ping_pong' });
  await waitState(s => (s.sequence?.available || []).includes(NAME), 3000, 'available has name');
  return `available now has ${lastState.sequence.available.length} sequences`;
});

await test('save persisted to sequences.json on disk', async () => {
  const obj = JSON.parse(fs.readFileSync(SEQUENCES_PATH, 'utf8'));
  if (!obj[NAME]) throw new Error(`${NAME} not in sequences.json`);
  if (obj[NAME].mode !== 'ping_pong') throw new Error('mode mismatch');
  if (obj[NAME].steps.length !== 3) throw new Error('step count mismatch');
  if (obj[NAME].steps[1].transition_ms !== 30000) throw new Error('30s transition not persisted');
  return 'disk has correct shape';
});

await test('load: scratch updates, mode + steps + name correct', async () => {
  await send({ action: 'sequence.set', steps: [], mode: 'forward' });
  await sleep(300);
  await send({ action: 'sequence.load', name: NAME });
  await waitState(s => {
    const ss = s.sequence?.steps;
    return Array.isArray(ss) && ss.length === 3 &&
      ss[0].preset_id === 0 && ss[0].seconds === 5  && ss[0].transition_ms === 1000 &&
      ss[1].preset_id === 1 && ss[1].seconds === 8  && ss[1].transition_ms === 30000 &&
      ss[2].preset_id === 2 && ss[2].seconds === 10 && ss[2].transition_ms === 0 &&
      s.sequence.loaded === NAME &&
      s.sequence.mode === 'ping_pong';
  }, 3000, 'load echoes steps');
  return 'all 3 steps + mode + name match';
});

await test('Gurudwara (user-saved) is still in library', async () => {
  if (!(lastState.sequence?.available || []).includes('Gurudwara')) {
    throw new Error('Gurudwara missing from available — did the file get clobbered?');
  }
  return 'present';
});

await test('legacy speed entries auto-migrate on load', async () => {
  // Write a legacy-shape entry directly to disk (older v1.0 format)
  const obj = JSON.parse(fs.readFileSync(SEQUENCES_PATH, 'utf8'));
  obj['LEGACY_TEST'] = {
    mode: 'forward',
    steps: [
      { preset_id: 0, seconds: 5, speed: 'cinema' },
      { preset_id: 1, seconds: 5, speed: 'slow' },
      { preset_id: 2, seconds: 5, speed: 'instant' },
    ],
  };
  fs.writeFileSync(SEQUENCES_PATH, JSON.stringify(obj, null, 2));
  // Bridge has the file in memory? read_lib() re-reads on each load. Try.
  await send({ action: 'sequence.set', steps: [], mode: 'forward' });
  await sleep(200);
  await send({ action: 'sequence.load', name: 'LEGACY_TEST' });
  await waitState(s => {
    const ss = s.sequence?.steps;
    return ss?.length === 3 &&
      ss[0].transition_ms === 22000 &&    // cinema → 22s
      ss[1].transition_ms === 5000  &&    // slow   → 5s
      ss[2].transition_ms === 0;          // instant → 0
  }, 3000, 'legacy auto-migrate');
  await send({ action: 'sequence.delete', name: 'LEGACY_TEST' });
  return 'cinema=22s, slow=5s, instant=0 mapped';
});

await test('delete: name disappears from available + disk', async () => {
  await send({ action: 'sequence.delete', name: NAME });
  await waitState(s => !(s.sequence?.available || []).includes(NAME), 3000, 'gone');
  const obj = JSON.parse(fs.readFileSync(SEQUENCES_PATH, 'utf8'));
  if (obj[NAME]) throw new Error(`${NAME} still on disk`);
  return 'deleted from state + disk';
});

console.log('\n=== RESULTS ===');
const passed = results.filter(r => r.ok).length;
console.log(`${passed}/${results.length} passed`);

console.log(`\n[lib at end] ${(lastState.sequence?.available || []).join(', ')}`);
console.log('To test cross-restart persistence: re-run this script after `pkill -9 -f obsbot-bridge && open Open\\ OBSBOT\\ Bridge.app`. Gurudwara should still be in the library.');

ws.close();
process.exit(passed === results.length ? 0 : 1);

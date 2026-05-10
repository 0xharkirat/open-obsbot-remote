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
  { preset_id: 0, seconds: 5,  speed: 'slow' },
  { preset_id: 1, seconds: 8,  speed: 'cinema' },
  { preset_id: 2, seconds: 10, speed: 'medium' },
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
  if (obj[NAME].steps[1].speed !== 'cinema') throw new Error('cinema speed not persisted');
  return 'disk has correct shape';
});

await test('load: scratch updates, mode + steps + name correct', async () => {
  // Wipe scratch first
  await send({ action: 'sequence.set', steps: [], mode: 'forward' });
  await sleep(300);
  await send({ action: 'sequence.load', name: NAME });
  await waitState(s => {
    const ss = s.sequence?.steps;
    return Array.isArray(ss) && ss.length === 3 &&
      ss[0].preset_id === 0 && ss[0].seconds === 5 && ss[0].speed === 'slow' &&
      ss[1].preset_id === 1 && ss[1].seconds === 8 && ss[1].speed === 'cinema' &&
      ss[2].preset_id === 2 && ss[2].seconds === 10 && ss[2].speed === 'medium' &&
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

await test('save round-trip preserves cinema/ultra speeds', async () => {
  const N2 = NAME + '_speeds';
  const SPEEDS = [
    { preset_id: 0, seconds: 5, speed: 'ultra' },
    { preset_id: 1, seconds: 5, speed: 'cinema' },
    { preset_id: 2, seconds: 5, speed: 'instant' },
  ];
  await send({ action: 'sequence.save_as', name: N2, steps: SPEEDS, mode: 'forward' });
  await waitState(s => (s.sequence?.available || []).includes(N2), 3000, 'saved');
  await send({ action: 'sequence.set', steps: [], mode: 'forward' });
  await sleep(200);
  await send({ action: 'sequence.load', name: N2 });
  await waitState(s => {
    const ss = s.sequence?.steps;
    return ss?.length === 3 &&
      ss[0].speed === 'ultra' &&
      ss[1].speed === 'cinema' &&
      ss[2].speed === 'instant';
  }, 3000, 'speeds preserved');
  await send({ action: 'sequence.delete', name: N2 });
  return 'ultra + cinema + instant survived round-trip';
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

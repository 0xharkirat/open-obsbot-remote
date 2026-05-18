#!/usr/bin/env node
// Sequencer timing regression — verifies the stay-timer does NOT
// overlap the move-timer (B2 fix).
//
// Pre-fix bug: with seconds=5 + transition_ms=3000 the step_index would
// advance to 1 at ~4.5 s after start, because trigger_step() returned
// async and step_started was reset immediately. The 3 s move ran
// concurrently with the stay clock against the 5 s budget. User-facing
// effect: observed hold time ≈ seconds - (transition_ms/1000), and for
// seconds=40 + transition_ms=30000 the user saw only ~10 s of hold.
//
// Post-fix: sequencer chains
//   trigger_step -> motion_wait_idle(transition_ms + 500) -> reset clock
// so the move and the hold are disjoint. step_index should now advance
// at >= 7.5 s after start (3 s move + 5 s hold = 8 s; we allow a small
// margin for motor settle).
//
// Run with bridge live + camera attached:
//   node tests/sequence_timing.mjs

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
    }, 8000);
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

// --- preset prep ---
//
// Save two presets at deliberately-distinct poses so the move actually
// takes the requested duration. If both presets are near the current
// pose the motor would land quickly and the test couldn't distinguish
// pre-fix from post-fix behaviour.
async function saveTestPreset(slot, name, yaw, pitch) {
  await send({ action: 'ptz.angle', yaw, pitch, duration_ms: 0 });
  await waitState(s =>
    Math.abs(s.ptz.yaw - yaw) < 2 && Math.abs(s.ptz.pitch - pitch) < 2,
    5000, `position ${yaw},${pitch}`);
  await send({ action: 'preset.save', preset_id: slot, name });
  await sleep(300);
}

console.log('\n=== SETUP ===');
console.log('  saving P0 (-20°, -5°) and P1 (20°, 5°)...');
await saveTestPreset(0, 'TEST_LEFT',  -20, -5);
await saveTestPreset(1, 'TEST_RIGHT',  20,  5);
// Park back at P0 before the sequence test starts so the first move is
// a real ~3 s pan, not a no-op.
await send({ action: 'preset.recall', preset_id: 0, duration_ms: 0 });
await sleep(800);

console.log('\n=== TIMING (B2 regression) ===');

const STEPS = [
  { preset_id: 0, seconds: 5, transition_ms: 3000 },
  { preset_id: 1, seconds: 5, transition_ms: 3000 },
];

await test('step_index advances at >= 7.5s (move+hold disjoint)', async () => {
  // Reset to scratch + load our 2-step sequence.
  await send({ action: 'sequence.set', steps: STEPS, mode: 'once' });
  await sleep(200);

  // Record every step_index value we observe along with its timestamp.
  // We start tracking from the moment sequence.start acks.
  const events = [];
  const tracker = s => {
    const idx = s?.sequence?.step_index;
    if (typeof idx === 'number') {
      events.push({ idx, t: Date.now() });
    }
  };
  watchers.push(tracker);

  const t0 = Date.now();
  await send({ action: 'sequence.start' });

  // Wait until we see step_index transition to 1 (or timeout).
  await waitState(s => s?.sequence?.step_index === 1, 15000, 'idx == 1');
  const advanceMs = Date.now() - t0;

  // Cleanup: stop the sequence + remove the tracker.
  await send({ action: 'sequence.stop' });
  const i = watchers.indexOf(tracker);
  if (i >= 0) watchers.splice(i, 1);

  // Pre-fix this happened at ~4.5 s (move overlapped stay). Post-fix
  // should be ~8 s (3 s move + 5 s hold) ± some camera-side settle
  // overhead. Floor at 7.5 s = halfway between the two — anything
  // below means the bug regressed.
  if (advanceMs < 7500) {
    throw new Error(
      `advanced at ${advanceMs}ms (expected >= 7500ms; pre-fix was ~4500ms)`);
  }
  // Generous ceiling so a slightly-slow camera doesn't false-fail.
  if (advanceMs > 12000) {
    throw new Error(
      `advanced at ${advanceMs}ms (expected <= 12000ms; sequencer stuck?)`);
  }
  return `idx 0 -> 1 at ${advanceMs}ms`;
});

await test('sequence.phase reports moving during transition', async () => {
  // Same shape, but this time we sample phase during the first move.
  await send({ action: 'sequence.set', steps: STEPS, mode: 'once' });
  await sleep(200);
  await send({ action: 'preset.recall', preset_id: 0, duration_ms: 0 });
  await sleep(800);

  await send({ action: 'sequence.start' });
  // Within the 3 s transition window we should see phase=moving.
  await waitState(
    s => s?.sequence?.phase === 'moving',
    3000, 'phase == moving');
  // Then within the next few seconds, phase should switch to holding.
  await waitState(
    s => s?.sequence?.phase === 'holding' && s?.sequence?.step_index === 0,
    6000, 'phase == holding (still on step 0)');

  await send({ action: 'sequence.stop' });
  return 'observed moving -> holding';
});

await test('instant-transition step reports phase=holding immediately', async () => {
  // transition_ms=0 means no MotionPlanner pass, so phase should stay
  // at "holding" the whole time.
  const INSTANT_STEPS = [
    { preset_id: 0, seconds: 3, transition_ms: 0 },
    { preset_id: 1, seconds: 3, transition_ms: 0 },
  ];
  await send({ action: 'sequence.set', steps: INSTANT_STEPS, mode: 'once' });
  await sleep(200);
  await send({ action: 'sequence.start' });
  // Watch the next 1.5 s. phase should never flip to moving for an
  // instant transition.
  let sawMoving = false;
  const tracker = s => {
    if (s?.sequence?.phase === 'moving') sawMoving = true;
  };
  watchers.push(tracker);
  await sleep(1500);
  const i = watchers.indexOf(tracker);
  if (i >= 0) watchers.splice(i, 1);
  await send({ action: 'sequence.stop' });
  if (sawMoving) {
    throw new Error('phase flipped to moving for transition_ms=0 step');
  }
  return 'phase stayed holding';
});

await test('sequence.stop releases planner mid-move', async () => {
  // Start a sequence with a long transition; stop it mid-move; verify
  // sequence.stop returns within a reasonable bound (not blocked on
  // the full transition_ms).
  const LONG_STEPS = [
    { preset_id: 0, seconds: 30, transition_ms: 8000 },
    { preset_id: 1, seconds: 30, transition_ms: 8000 },
  ];
  await send({ action: 'preset.recall', preset_id: 1, duration_ms: 0 });
  await sleep(800);
  await send({ action: 'sequence.set', steps: LONG_STEPS, mode: 'once' });
  await sleep(200);
  await send({ action: 'sequence.start' });
  // Wait until the move is in flight.
  await waitState(s => s?.sequence?.phase === 'moving', 2000, 'phase moving');
  await sleep(1000);   // a second into the 8 s move
  const t0 = Date.now();
  await send({ action: 'sequence.stop' });
  const stopMs = Date.now() - t0;
  // Should be well under the remaining 7 s of transition. Generous
  // ceiling of 2 s lets us absorb worker-queue + ack latency.
  if (stopMs > 2000) {
    throw new Error(`stop took ${stopMs}ms (expected < 2000ms; planner blocked?)`);
  }
  return `stop returned in ${stopMs}ms`;
});

console.log('\n=== RESULTS ===');
const passed = results.filter(r => r.ok).length;
console.log(`${passed}/${results.length} passed`);

await send({ action: 'preset.delete', preset_id: 0 }).catch(() => {});
await send({ action: 'preset.delete', preset_id: 1 }).catch(() => {});

ws.close();
process.exit(passed === results.length ? 0 : 1);

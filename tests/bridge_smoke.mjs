#!/usr/bin/env node
// Production-grade smoke test against real bridge + real camera.
//
//   node tests/bridge_smoke.mjs            (full battery)
//   node tests/bridge_smoke.mjs --short    (skip slow tests)
//
// Connects to ws://localhost:8765/v1, pairs (or reuses token), subscribes,
// runs a battery of action+verify cycles, prints PASS/FAIL, and tails the
// bridge log for any new error/warn lines that appeared during the run.

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';

const SHORT = process.argv.includes('--short');

const AUTH_PATH = `${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`;
const LOG_PATH  = `${os.homedir()}/Library/Logs/Open OBSBOT Bridge/bridge.log`;
const auth = JSON.parse(fs.readFileSync(AUTH_PATH, 'utf8'));
const token = auth.tokens[0];

// Capture log size at start so we can diff at the end.
const logStartSize = fs.existsSync(LOG_PATH) ? fs.statSync(LOG_PATH).size : 0;

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
  const t0 = Date.now();
  try {
    await body();
    const dt = Date.now() - t0;
    process.stdout.write(`PASS (${dt}ms)\n`);
    results.push({ name, ok: true, ms: dt });
  } catch (e) {
    const dt = Date.now() - t0;
    process.stdout.write(`FAIL (${dt}ms) ${e.message}\n`);
    results.push({ name, ok: false, err: e.message, ms: dt });
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
  if (m.type === 'pong' && pendingAcks.has(m.id)) {
    const p = pendingAcks.get(m.id);
    pendingAcks.delete(m.id);
    p.resolve(m);
    return;
  }
  if (m.event === 'state') {
    lastState = m;
    for (const w of [...stateWatchers]) w(m);
  }
});

ws.on('error', (e) => { console.error('[ws] error:', e.message); process.exit(2); });

await new Promise((res, rej) => {
  ws.once('open', res);
  ws.once('error', rej);
});

const hello = await send({ action: 'hello', token });
console.log(`[hello] devices: ${hello.devices?.length ?? 0}, server=${hello.server?.version}`);
await send({ action: 'subscribe' });
await waitState(() => lastState !== null && lastState.device.connected, 3000, 'first connected state');

const dev = lastState.device;
console.log(`[device] ${dev.model_display} sn=${dev.sn} fw=${dev.firmware} run=${dev.run_status}`);
console.log(`[start ] yaw=${fmt(lastState.ptz.yaw)} pitch=${fmt(lastState.ptz.pitch)} zoom=${fmt(lastState.zoom.value)} ai=${lastState.ai.mode} fov=${lastState.image.fov} hdr=${lastState.image.hdr}`);
console.log(`[zoom  ] range ${lastState.zoom.min}..${lastState.zoom.max}`);

console.log('\n=== TEST BATTERY (' + (SHORT ? 'short' : 'full') + ') ===');

// ---------- BASIC PROTOCOL ----------

await test('ping → pong with id echo', async () => {
  const t0 = Date.now();
  const r = await send({ action: 'ping' });
  const rt = Date.now() - t0;
  if (r.type !== 'pong') throw new Error('expected pong, got ' + r.type);
  if (rt > 500) throw new Error('ping rt ' + rt + 'ms (>500ms)');
});

await test('unknown action returns ack ok=false', async () => {
  try {
    await send({ action: 'totally.fake.action' });
    throw new Error('should have rejected');
  } catch (e) {
    if (!String(e.message).includes('unsupported')) {
      throw new Error('expected unsupported err, got ' + e.message);
    }
  }
});

// ---------- PTZ ----------

await test('ptz.angle yaw=10 reflects', async () => {
  await send({ action: 'ptz.angle', yaw: 10, pitch: 0 });
  await waitState(s => Math.abs(s.ptz.yaw - 10) < 2, 5000, 'yaw≈10');
});

await test('ptz.recenter brings yaw back to 0', async () => {
  await send({ action: 'ptz.recenter' });
  await waitState(s => Math.abs(s.ptz.yaw) < 1.5, 5000, 'yaw≈0');
});

await test('ptz.velocity stream + ptz.stop', async () => {
  // Prime: set AI off + small settle delay. Right after a ptz.recenter
  // the gimbal motor is still finalizing position; sending velocity
  // immediately can race the recenter's gimbalRstPosR and silently
  // drop the speed cmd.
  await send({ action: 'ai.set_mode', mode: 'none', sub_mode: 'normal' });
  await sleep(500);
  const yawBefore = lastState.ptz.yaw;
  // Stream rightward ~2s at speed 60 (matches phone hold-button preset).
  for (let i = 0; i < 25; i++) {
    await send({ action: 'ptz.velocity', yaw_speed: 60, pitch_speed: 0 });
    await sleep(80);
  }
  await send({ action: 'ptz.stop' });
  // Wait for the next state event to confirm (poller is ~500ms).
  await sleep(700);
  const yawAfter = lastState.ptz.yaw;
  // Tiny 2 Lite SDK convention: positive yaw_speed moves yaw toward
  // negative angle. Test only that gimbal *moved*, not direction.
  if (Math.abs(yawAfter - yawBefore) <= 5) {
    throw new Error(`yaw delta=${(yawAfter - yawBefore).toFixed(2)} (before=${yawBefore.toFixed(2)} after=${yawAfter.toFixed(2)}); expected |delta|>5°`);
  }
  await send({ action: 'ptz.recenter' });
  await waitState(s => Math.abs(s.ptz.yaw) < 1.5, 5000, 'yaw≈0');
});

// ---------- ZOOM ----------

await test('zoom.set 1.5x reflects in state', async () => {
  await send({ action: 'zoom.set', value: 1.5 });
  await waitState(s => Math.abs(s.zoom.value - 1.5) < 0.05, 3000, 'zoom≈1.5');
});

await test('zoom.set 1.0x back', async () => {
  await send({ action: 'zoom.set', value: 1.0 });
  await waitState(s => Math.abs(s.zoom.value - 1.0) < 0.05, 3000, 'zoom≈1.0');
});

await test('zoom.set above max clamps to zoom.max', async () => {
  const max = lastState.zoom.max;
  await send({ action: 'zoom.set', value: max + 1.0 });
  await waitState(s => Math.abs(s.zoom.value - max) < 0.05, 3000, 'zoom≈max');
  await send({ action: 'zoom.set', value: 1.0 });
  await waitState(s => Math.abs(s.zoom.value - 1.0) < 0.05, 3000, 'zoom≈1.0');
});

await test('zoom.set_smooth at speed=8 reflects', async () => {
  await send({ action: 'zoom.set_smooth', value: 1.4, speed: 8 });
  await waitState(s => Math.abs(s.zoom.value - 1.4) < 0.05, 5000, 'zoom≈1.4');
  await send({ action: 'zoom.set', value: 1.0 });
  await waitState(s => Math.abs(s.zoom.value - 1.0) < 0.05, 3000, 'zoom≈1.0');
});

// ---------- PRESETS ----------

await test('preset.save captures zoom 1.7x; recall instant restores it', async () => {
  await send({ action: 'zoom.set', value: 1.7 });
  await waitState(s => Math.abs(s.zoom.value - 1.7) < 0.05, 3000, 'zoom≈1.7');
  await send({ action: 'preset.save', preset_id: 3, name: 'Smoke_P4_Zoom17' });
  await waitState(s => {
    const p = (s.presets || []).find(x => x.id === 3);
    return p && Math.abs(p.zoom - 1.7) < 0.05;
  }, 3000, 'preset[3].zoom≈1.7');
  await send({ action: 'zoom.set', value: 1.0 });
  await waitState(s => Math.abs(s.zoom.value - 1.0) < 0.05, 3000, 'zoom≈1.0');
  await send({ action: 'preset.recall', preset_id: 3, duration_ms: 0 });
  await waitState(s => Math.abs(s.zoom.value - 1.7) < 0.1, 5000, 'zoom restored ≈1.7');
});

await test('preset.recall slow speed restores zoom too', async () => {
  await send({ action: 'zoom.set', value: 1.0 });
  await waitState(s => Math.abs(s.zoom.value - 1.0) < 0.05, 3000, 'zoom≈1.0');
  await send({ action: 'preset.recall', preset_id: 3, duration_ms: 1000 });
  await waitState(s => Math.abs(s.zoom.value - 1.7) < 0.1, 6000, 'zoom restored');
});

if (!SHORT) {
  await test('preset names round-trip: P3 saved with name reflects in state', async () => {
    await send({ action: 'preset.save', preset_id: 2, name: 'Smoke_P3_Named' });
    await waitState(s => {
      const p = (s.presets || []).find(x => x.id === 2);
      return p && p.name === 'Smoke_P3_Named';
    }, 3000, 'preset[2].name match');
  });
}

// Restore zoom for cleanliness
await send({ action: 'zoom.set', value: 1.0 });
await sleep(400);
await send({ action: 'ptz.recenter' });
await sleep(400);

// ---------- AI MODE ----------

await test('ai.set_mode human + sub=close_up reflects', async () => {
  await send({ action: 'ai.set_mode', mode: 'human', sub_mode: 'close_up' });
  await waitState(s => s.ai.mode === 'human' && s.ai.sub_mode === 'close_up',
    3000, 'ai.mode=human sub=close_up');
});

await test('ai.set_mode group reflects', async () => {
  await send({ action: 'ai.set_mode', mode: 'group', sub_mode: 'normal' });
  await waitState(s => s.ai.mode === 'group', 3000, 'ai=group');
});

await test('ai.set_mode none turns AI off', async () => {
  await send({ action: 'ai.set_mode', mode: 'none', sub_mode: 'normal' });
  await waitState(s => s.ai.mode === 'none', 3000, 'ai=none');
});

await test('manual ptz after AI on disables AI without flap', async () => {
  await send({ action: 'ai.set_mode', mode: 'human', sub_mode: 'normal' });
  await waitState(s => s.ai.mode === 'human', 3000, 'ai=human');
  // velocity stream — AI should drop to none on first cmd, then stay none
  for (let i = 0; i < 3; i++) {
    await send({ action: 'ptz.velocity', yaw_speed: 30, pitch_speed: 0 });
    await sleep(80);
  }
  await send({ action: 'ptz.stop' });
  await waitState(s => s.ai.mode === 'none', 3000, 'ai=none after manual');
  // Re-arm AI then observe stability for 2s
  await send({ action: 'ai.set_mode', mode: 'human', sub_mode: 'normal' });
  await waitState(s => s.ai.mode === 'human', 3000, 'ai=human again');
  let flapCount = 0;
  let lastMode = 'human';
  const watcher = (s) => {
    if (s.ai.mode !== lastMode) { flapCount++; lastMode = s.ai.mode; }
  };
  stateWatchers.push(watcher);
  await sleep(2000);
  const idx = stateWatchers.indexOf(watcher);
  if (idx >= 0) stateWatchers.splice(idx, 1);
  if (flapCount > 0) throw new Error(`AI flapped ${flapCount} times unprovoked`);
  await send({ action: 'ai.set_mode', mode: 'none', sub_mode: 'normal' });
  await waitState(s => s.ai.mode === 'none', 3000, 'ai=none cleanup');
  await send({ action: 'ptz.recenter' });
});

// ---------- IMAGE ----------

await test('image.set_hdr toggles', async () => {
  const was = lastState.image.hdr;
  await send({ action: 'image.set_hdr', enabled: !was });
  await waitState(s => s.image.hdr === !was, 6000, 'hdr flipped');
  // Restore (need 3s debounce per CLAUDE.md)
  await sleep(3500);
  await send({ action: 'image.set_hdr', enabled: was });
  await waitState(s => s.image.hdr === was, 6000, 'hdr restored');
});

await test('image.set_fov cycles 86 → 78 → 86', async () => {
  await send({ action: 'image.set_fov', fov: 78 });
  await waitState(s => s.image.fov === 78, 5000, 'fov=78');
  await send({ action: 'image.set_fov', fov: 86 });
  await waitState(s => s.image.fov === 86, 5000, 'fov=86');
});

await test('image.set_face_ae toggles', async () => {
  const was = lastState.image.face_ae;
  await send({ action: 'image.set_face_ae', enabled: !was });
  await waitState(s => s.image.face_ae === !was, 4000, 'face_ae flipped');
  await send({ action: 'image.set_face_ae', enabled: was });
  await waitState(s => s.image.face_ae === was, 4000, 'face_ae restored');
});

await test('image.set_face_focus toggles', async () => {
  const was = lastState.image.face_focus;
  await send({ action: 'image.set_face_focus', enabled: !was });
  await waitState(s => s.image.face_focus === !was, 4000, 'face_focus flipped');
  await send({ action: 'image.set_face_focus', enabled: was });
  await waitState(s => s.image.face_focus === was, 4000, 'face_focus restored');
});

if (!SHORT) {
  await test('image.set_flip_h toggles', async () => {
    const was = lastState.image.flip_h;
    await send({ action: 'image.set_flip_h', enabled: !was });
    await waitState(s => s.image.flip_h === !was, 4000, 'flip_h flipped');
    await send({ action: 'image.set_flip_h', enabled: was });
    await waitState(s => s.image.flip_h === was, 4000, 'flip_h restored');
  });

  await test('image.set_color brightness reflects', async () => {
    const was = lastState.image.brightness;
    const target = was === 50 ? 60 : 50;
    await send({ action: 'image.set_color', brightness: target });
    await waitState(s => Math.abs(s.image.brightness - target) <= 1, 4000, 'brightness=target');
    await send({ action: 'image.set_color', brightness: was });
    await waitState(s => Math.abs(s.image.brightness - was) <= 1, 4000, 'brightness restored');
  });
}

// ---------- RUN STATUS ----------

if (!SHORT) {
  await test('system.run_status sleep then run', async () => {
    await send({ action: 'system.run_status', status: 'sleep' });
    await waitState(s => s.device.run_status === 'sleep', 5000, 'run=sleep');
    await sleep(800);
    await send({ action: 'system.run_status', status: 'run' });
    await waitState(s => s.device.run_status === 'run', 5000, 'run=run');
  });
}

// ---------- SEQUENCER ----------

await test('sequence.set ships steps in state event', async () => {
  const steps = [
    { preset_id: 0, seconds: 5, transition_ms: 2000 },
    { preset_id: 1, seconds: 5, transition_ms: 1000 },
  ];
  await send({ action: 'sequence.set', steps, mode: 'forward' });
  await waitState(s => {
    const ss = s.sequence?.steps;
    return Array.isArray(ss) && ss.length === 2 &&
      ss[0].preset_id === 0 && ss[0].seconds === 5 && ss[0].transition_ms === 2000 &&
      ss[1].preset_id === 1 && ss[1].transition_ms === 1000;
  }, 3000, 'steps echo');
});

await test('sequence.start sets running=true; stop sets it false', async () => {
  await send({ action: 'sequence.start' });
  await waitState(s => s.sequence?.running === true, 3000, 'running=true');
  await sleep(800);
  await send({ action: 'sequence.stop' });
  await waitState(s => s.sequence?.running === false, 3000, 'running=false');
});

await test('sequence.save_as + load round-trips steps + mode', async () => {
  const NAME = 'PROD_TEST_' + Date.now();
  const steps = [
    { preset_id: 2, seconds: 7, transition_ms: 5000 },
    { preset_id: 3, seconds: 4, transition_ms: 0 },
  ];
  await send({ action: 'sequence.save_as', name: NAME, steps, mode: 'ping_pong' });
  await waitState(s => (s.sequence?.available || []).includes(NAME),
    3000, 'available includes new name');
  await send({ action: 'sequence.set', steps: [], mode: 'forward' });
  await sleep(300);
  await send({ action: 'sequence.load', name: NAME });
  await waitState(s => {
    const ss = s.sequence?.steps;
    return Array.isArray(ss) && ss.length === 2 &&
      ss[0].preset_id === 2 && ss[0].seconds === 7 && ss[0].transition_ms === 5000 &&
      ss[1].preset_id === 3 && ss[1].seconds === 4 && ss[1].transition_ms === 0 &&
      s.sequence.loaded === NAME && s.sequence.mode === 'ping_pong';
  }, 3000, 'load echoes steps');
  await send({ action: 'sequence.delete', name: NAME });
  await waitState(s => !(s.sequence?.available || []).includes(NAME),
    3000, 'available excludes after delete');
});

await test('sequence.set with seconds<3 clamps to 3', async () => {
  await send({ action: 'sequence.set', steps: [
    { preset_id: 0, seconds: 1, transition_ms: 2000 },  // bridge clamps to 3
  ], mode: 'forward' });
  await waitState(s => {
    const ss = s.sequence?.steps;
    return ss && ss.length === 1 && ss[0].seconds === 3;
  }, 3000, 'clamped seconds');
});

// ---------- CLEANUP ----------

await send({ action: 'ai.set_mode', mode: 'none', sub_mode: 'normal' }).catch(() => {});
await send({ action: 'zoom.set', value: 1.0 }).catch(() => {});
await send({ action: 'ptz.recenter' }).catch(() => {});

// ---------- REPORT ----------

console.log('\n=== RESULTS ===');
const passed = results.filter(r => r.ok).length;
const failed = results.filter(r => !r.ok);
const totalMs = results.reduce((a, r) => a + r.ms, 0);
console.log(`${passed}/${results.length} passed in ${(totalMs/1000).toFixed(1)}s`);
for (const f of failed) console.log(`  FAIL: ${f.name} — ${f.err}`);

// Tail bridge log for new errors/warnings since test start
console.log('\n=== BRIDGE LOG (errors/warnings during run) ===');
try {
  const stat = fs.statSync(LOG_PATH);
  const size = stat.size - logStartSize;
  if (size > 0) {
    const fd = fs.openSync(LOG_PATH, 'r');
    const buf = Buffer.alloc(size);
    fs.readSync(fd, buf, 0, size, logStartSize);
    fs.closeSync(fd);
    const lines = buf.toString().split('\n');
    const interesting = lines.filter(l =>
      / error \]| warn  \]| fatal /.test(l) ||
      /===== bridge exited/.test(l));
    if (interesting.length === 0) {
      console.log('(no errors/warnings)');
    } else {
      for (const l of interesting) console.log('  ' + l);
    }
  } else {
    console.log('(log unchanged)');
  }
} catch (e) {
  console.log('(log read failed: ' + e.message + ')');
}

ws.close();
process.exit(failed.length === 0 ? 0 : 1);

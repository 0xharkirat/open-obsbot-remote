#!/usr/bin/env node
// v2 multi-camera acceptance battery. Run against a bridge with TWO
// real cameras attached (one may be asleep - that is a tested state,
// not a failure).
//
//   node tests/two_cam_smoke.mjs
//
// Covers the v2 wire contract: BridgeState envelope, device_id routing
// rules, device.list / set_active / rename, per-device presets, the
// per-device + active MJPEG endpoints, and the removal of dead fields.
// See docs/PROTOCOL.md.

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';
import http from 'node:http';

const AUTH_PATH = `${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`;
const auth = JSON.parse(fs.readFileSync(AUTH_PATH, 'utf8'));
const token = auth.tokens[0];

const ws = new WebSocket('ws://localhost:8765/v1');
let nextId = 1;
const pendingAcks = new Map();
let lastState = null;
const stateWatchers = [];
let helloAck = null;

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

// Resolves with the ERROR ack (ok:false) - for tests that expect rejection.
async function sendExpectErr(msg) {
  const r = await send(msg);
  if (r.ok !== false) throw new Error(`expected ok:false, got ${JSON.stringify(r).slice(0, 120)}`);
  return r;
}

function waitState(predicate, timeoutMs = 4000, label = '') {
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

function httpStatus(path) {
  return new Promise((resolve) => {
    const req = http.get({ host: 'localhost', port: 8766, path, timeout: 4000 }, (res) => {
      resolve({ status: res.statusCode, type: res.headers['content-type'] ?? '' });
      req.destroy();
    });
    req.on('timeout', () => { req.destroy(); resolve({ status: -1, type: 'timeout' }); });
    req.on('error', () => resolve({ status: -2, type: 'error' }));
  });
}

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

await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej); });
helloAck = await send({ action: 'hello', token });
await send({ action: 'subscribe' });
await waitState((s) => Array.isArray(s.devices), 5000, 'first v2 state');

const devs = lastState.devices;
console.log(`[setup] ${devs.length} device(s): ${devs.map((d) => `${d.device_id}(${d.device?.run_status})`).join(', ')}`);
console.log(`[setup] active = ${lastState.active_device_id}\n`);
if (devs.length < 2) {
  console.error('NEED two cameras attached for this battery.');
  process.exit(1);
}
const [A, B] = [devs[0].device_id, devs[1].device_id];
const activeAtStart = lastState.active_device_id;
const otherCam = activeAtStart === A ? B : A;

console.log('=== V2 MULTI-CAM BATTERY ===');

await test('hello ack advertises protocol 2.0 + device summaries', async () => {
  assert(helloAck.server?.protocol === '2.0', `server.protocol=${helloAck.server?.protocol}`);
  assert(Array.isArray(helloAck.devices) && helloAck.devices.length >= 2, 'hello.devices');
});

await test('state envelope: version, ts, active_device_id in devices', async () => {
  assert(lastState.version === '2.0', `version=${lastState.version}`);
  assert(typeof lastState.ts === 'number', 'ts missing');
  assert(devs.some((d) => d.device_id === lastState.active_device_id), 'active not in devices');
});

await test('every device entry: id==sn, connected, valid run_status', async () => {
  for (const d of lastState.devices) {
    assert(d.device_id === d.device.sn, `id ${d.device_id} != sn ${d.device.sn}`);
    assert(d.device.connected === true, `${d.device_id} not connected`);
    assert(['run', 'sleep', 'privacy', 'unknown'].includes(d.device.run_status), `run_status=${d.device.run_status}`);
  }
});

await test('dead fields are gone (image.hue, ai.tracking_mode, sequence.loop)', async () => {
  for (const d of lastState.devices) {
    assert(!('hue' in (d.image ?? {})), 'image.hue present');
    assert(!('tracking_mode' in (d.ai ?? {})), 'ai.tracking_mode present');
    assert(!('loop' in (d.sequence ?? {})), 'sequence.loop present');
  }
});

await test('device.list matches state devices + active', async () => {
  const r = await send({ action: 'device.list' });
  assert(r.ok === true, 'not ok');
  const ids = r.devices.map((d) => d.device_id).sort();
  assert(JSON.stringify(ids) === JSON.stringify(devs.map((d) => d.device_id).sort()), 'id sets differ');
  assert(r.active_device_id === lastState.active_device_id, 'active differs');
});

await test('per-device action without device_id -> device_required', async () => {
  const r = await sendExpectErr({ action: 'ptz.recenter' });
  assert(r.err === 'device_required', `err=${r.err}`);
});

await test('unknown device_id -> not_found', async () => {
  const r = await sendExpectErr({ action: 'ptz.recenter', device_id: 'NOPE123' });
  assert(r.err === 'not_found', `err=${r.err}`);
});

await test('device.set_active unknown -> not_found', async () => {
  const r = await sendExpectErr({ action: 'device.set_active', device_id: 'NOPE123' });
  assert(r.err === 'not_found', `err=${r.err}`);
});

await test(`device.set_active -> ${otherCam} goes live (state event)`, async () => {
  const r = await send({ action: 'device.set_active', device_id: otherCam });
  assert(r.ok === true, 'not ok');
  await waitState((s) => s.active_device_id === otherCam, 6000, 'active flip');
});

await test('set_active back to original', async () => {
  await send({ action: 'device.set_active', device_id: activeAtStart });
  await waitState((s) => s.active_device_id === activeAtStart, 6000, 'active restore');
});

await test('device.rename round-trip + clear', async () => {
  await send({ action: 'device.rename', device_id: A, name: 'SMOKE_A' });
  await waitState(
    (s) => s.devices.find((d) => d.device_id === A)?.device.friendly_name === 'SMOKE_A',
    4000, 'rename visible');
  await send({ action: 'device.rename', device_id: A, name: '' });
  await waitState(
    (s) => s.devices.find((d) => d.device_id === A)?.device.friendly_name === '',
    4000, 'rename cleared');
});

await test('ptz.recenter routes per device (both cams ack ok)', async () => {
  assert((await send({ action: 'ptz.recenter', device_id: A })).ok === true, 'A recenter');
  assert((await send({ action: 'ptz.recenter', device_id: B })).ok === true, 'B recenter');
});

await test('preset.save on A is invisible on B', async () => {
  await send({ action: 'preset.save', device_id: A, preset_id: 5, name: 'SMOKE_TEST' });
  const s = await waitState(
    (st) => st.devices.find((d) => d.device_id === A)?.presets?.some((p) => p.id === 5 && p.name === 'SMOKE_TEST'),
    4000, 'preset on A');
  const bPresets = s.devices.find((d) => d.device_id === B)?.presets ?? [];
  assert(!bPresets.some((p) => p.id === 5 && p.name === 'SMOKE_TEST'), 'leaked to B');
  await send({ action: 'preset.delete', device_id: A, preset_id: 5 });
});

await test('MJPEG per-device endpoints', async () => {
  const a = await httpStatus(`/preview/${A}.mjpg?t=${token}`);
  const b = await httpStatus(`/preview/${B}.mjpg?t=${token}`);
  // A sleeping camera may legitimately answer 503; a wedge (timeout) may not.
  for (const [sn, r] of [[A, a], [B, b]]) {
    assert(r.status === 200 || r.status === 503, `${sn}: status=${r.status} (${r.type})`);
  }
});

await test('MJPEG active endpoint + unknown 404', async () => {
  const act = await httpStatus(`/preview/active.mjpg?t=${token}`);
  assert(act.status === 200 || act.status === 503, `active: status=${act.status}`);
  const nope = await httpStatus(`/preview/NOPE.mjpg?t=${token}`);
  assert(nope.status === 404, `unknown: status=${nope.status}`);
});

await test('MJPEG without token -> 401/403', async () => {
  const r = await httpStatus(`/preview/${A}.mjpg`);
  assert(r.status === 401 || r.status === 403, `status=${r.status}`);
});

console.log(`\n=== RESULTS ===\n${pass}/${pass + fail} passed`);
ws.close();
process.exit(fail === 0 ? 0 : 1);

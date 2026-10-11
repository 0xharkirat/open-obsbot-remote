// tests/obs_e2e.mjs - end to end through OBS Studio.
//
// The other batteries prove the bridge answers the protocol. This one proves
// the thing an operator actually relies on: OBS, holding a Media Source on
// /preview/active.mjpg (the setup README.md documents - not a Browser Source,
// which runs Chromium and lags), shows the camera, shows it MOVE when the bridge drives
// PTZ and zoom, and follows TAKE (cut and crossfade) without the source being
// reloaded. It reads OBS's own rendered output through obs-websocket, so a
// pass means pixels changed in OBS, not just that a command was acked.
//
// Needs:
//   - the bridge running with one OBSBOT attached (a paired token in auth.json)
//   - OBS 28+ running with Tools > WebSocket Server Settings > Enable on.
//     Password from $OBS_PASSWORD, else read from OBS's own config file.
//   - optional: a second, non-OBSBOT webcam, for the TAKE tests. Without one
//     those tests are skipped, not failed.
//
// Switches OBS's program scene to an "OBSBOT E2E" scene for the run (a Media
// Source only decodes while it is on air) and leaves it there. The
// scene and its "OBSBOT Active" Media Source are left in place for a visual
// check. Only that scene is touched. Restores the camera's pose, zoom and
// on-air choice.
//
//   node tests/obs_e2e.mjs
import WebSocket from 'ws';
import OBSWebSocket from 'obs-websocket-js';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { SUPPORT_DIR } from './paths.mjs';

const SCENE = 'OBSBOT E2E';
const INPUT = 'OBSBOT Active';
const SHOT_W = 160, SHOT_H = 90;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- bridge ----
const auth = JSON.parse(fs.readFileSync(`${SUPPORT_DIR}/auth.json`, 'utf8'));
const token = auth.tokens?.[0];
if (!token) { console.error('no paired token in auth.json; pair a client first'); process.exit(2); }

const ws = new WebSocket('ws://127.0.0.1:8765/v1');
let nextId = 1;
const acks = new Map();
let state = null;
ws.on('message', (raw) => {
  const j = JSON.parse(raw.toString());
  if (j.event === 'state') { state = j; return; }
  if (j.id && acks.has(j.id)) { acks.get(j.id)(j); acks.delete(j.id); }
});
function send(msg) {
  msg.id = String(nextId++);
  return new Promise((res, rej) => {
    const t = setTimeout(() => { acks.delete(msg.id); rej(new Error(`ack timeout ${msg.action}`)); }, 8000);
    acks.set(msg.id, (r) => { clearTimeout(t); res(r); });
    ws.send(JSON.stringify(msg));
  });
}
await new Promise((r, j) => { ws.once('open', r); ws.once('error', j); });
await send({ action: 'hello', token });
await send({ action: 'subscribe' });
for (let i = 0; i < 40 && !state?.devices?.length; i++) await sleep(100);
const cam = state?.devices?.find((d) => d.device?.connected && !String(d.device_id).startsWith('av:'));
if (!cam) { console.error('no OBSBOT camera attached to the bridge'); process.exit(2); }
const SN = cam.device_id;
const original = { yaw: cam.ptz.yaw, pitch: cam.ptz.pitch, zoom: cam.zoom.value, active: state.active_device_id };
console.log(`[bridge] camera ${SN} (${cam.device.model_display}) yaw=${original.yaw} pitch=${original.pitch} zoom=${original.zoom}`);

// ------------------------------------------------------------------- obs ----
function obsPassword() {
  if (process.env.OBS_PASSWORD) return process.env.OBS_PASSWORD;
  const base = process.platform === 'win32' ? process.env.APPDATA
    : process.platform === 'darwin' ? `${os.homedir()}/Library/Application Support`
    : `${os.homedir()}/.config`;
  try {
    const c = JSON.parse(fs.readFileSync(path.join(base, 'obs-studio', 'plugin_config', 'obs-websocket', 'config.json'), 'utf8'));
    return c.auth_required ? c.server_password : undefined;
  } catch { return undefined; }
}
const obs = new OBSWebSocket();
try {
  await obs.connect('ws://127.0.0.1:4455', obsPassword());
} catch (e) {
  console.error(`cannot reach obs-websocket on :4455 (${e.message}). Is OBS running with the WebSocket server enabled?`);
  process.exit(2);
}
const { obsVersion } = await obs.call('GetVersion');
console.log(`[obs] connected, OBS ${obsVersion}`);

// Never run against someone's real OBS setup. This test switches the program
// scene, creates and removes sources, and drives TAKEs that have crashed OBS
// before (CLAUDE.md gotcha #56), so it insists on a scene collection that
// exists only for it: Scene Collection > New > "OBSBOT E2E".
const { currentSceneCollectionName } = await obs.call('GetSceneCollectionList');
if (!currentSceneCollectionName.startsWith('OBSBOT E2E')) {
  console.error(`OBS's current scene collection is "${currentSceneCollectionName}".\n` +
    'Refusing to touch it. In OBS: Scene Collection > New > "OBSBOT E2E", ' +
    'switch to it, then rerun.');
  await obs.disconnect();
  process.exit(2);
}

const { scenes, currentProgramSceneName: userScene } = await obs.call('GetSceneList');
if (!scenes.some((s) => s.sceneName === SCENE)) await obs.call('CreateScene', { sceneName: SCENE });
await obs.call('SetCurrentProgramScene', { sceneName: SCENE });

// The README's Media Source settings, verbatim.
const url = `http://127.0.0.1:8766/preview/active.mjpg?t=${token}`;
const settings = {
  is_local_file: false,
  input: url,
  input_format: 'mjpeg',
  reconnect_delay_sec: 2,
  restart_on_activate: false,
  close_when_inactive: false,
  ffmpeg_options: 'reconnect=1 reconnect_streamed=1 reconnect_delay_max=2',
};
const { inputs } = await obs.call('GetInputList');
const existing = inputs.find((i) => i.inputName === INPUT);
if (existing && existing.inputKind !== 'ffmpeg_source') {
  // An earlier run of this test made a Browser Source under this name.
  await obs.call('RemoveInput', { inputName: INPUT });
  // Removal is asynchronous in OBS; the name stays taken for a moment.
  for (let i = 0; i < 50; i++) {
    const { inputs: now } = await obs.call('GetInputList');
    if (!now.some((x) => x.inputName === INPUT)) break;
    await sleep(100);
  }
}
if (existing && existing.inputKind === 'ffmpeg_source') {
  await obs.call('SetInputSettings', { inputName: INPUT, inputSettings: settings });
} else {
  await obs.call('CreateInput', { sceneName: SCENE, inputName: INPUT, inputKind: 'ffmpeg_source', inputSettings: settings });
}
// Fill the canvas so the screenshot is the camera, not mostly empty canvas.
const { sceneItemId } = await obs.call('GetSceneItemId', { sceneName: SCENE, sourceName: INPUT });
await obs.call('SetSceneItemTransform', {
  sceneName: SCENE, sceneItemId,
  sceneItemTransform: { boundsType: 'OBS_BOUNDS_SCALE_INNER', boundsWidth: (await obs.call('GetVideoSettings')).baseWidth,
    boundsHeight: (await obs.call('GetVideoSettings')).baseHeight, positionX: 0, positionY: 0 },
});

// A small BMP of what OBS renders for the source: uncompressed, so it can be
// read without an image library. Returns greyscale values, top-down.
async function shot() {
  const { imageData } = await obs.call('GetSourceScreenshot', {
    sourceName: INPUT, imageFormat: 'bmp', imageWidth: SHOT_W, imageHeight: SHOT_H,
  });
  const b = Buffer.from(imageData.split(',')[1], 'base64');
  const off = b.readUInt32LE(10), w = b.readInt32LE(18), hRaw = b.readInt32LE(22), bpp = b.readUInt16LE(28) / 8;
  const h = Math.abs(hRaw), stride = Math.ceil((w * bpp) / 4) * 4;
  const g = new Float64Array(w * h);
  for (let y = 0; y < h; y++) {
    const row = hRaw > 0 ? h - 1 - y : y;
    for (let x = 0; x < w; x++) {
      const p = off + row * stride + x * bpp;
      g[y * w + x] = 0.114 * b[p] + 0.587 * b[p + 1] + 0.299 * b[p + 2];
    }
  }
  return g;
}
const mean = (g) => g.reduce((a, v) => a + v, 0) / g.length;
const std = (g) => { const m = mean(g); return Math.sqrt(g.reduce((a, v) => a + (v - m) ** 2, 0) / g.length); };
const diff = (a, b) => a.reduce((s, v, i) => s + Math.abs(v - b[i]), 0) / a.length;

let pass = 0, fail = 0, skip = 0;
async function test(name, fn) {
  try { const note = await fn(); pass++; console.log(`  PASS  ${name}${note ? `  (${note})` : ''}`); }
  catch (e) { fail++; console.log(`  FAIL  ${name}: ${e.message}`); }
}
const skipTest = (name, why) => { skip++; console.log(`  SKIP  ${name}: ${why}`); };
const expect = (cond, msg) => { if (!cond) throw new Error(msg); };
// Every comparison below is meaningless on a dead feed (black equals black),
// so each one first demands a real picture.
const live = (g, what) => expect(mean(g) > 12 && std(g) > 6,
  `${what}: OBS shows no picture (mean ${mean(g).toFixed(1)}, stddev ${std(g).toFixed(1)})`);

console.log('\n=== OBS END-TO-END ===');
await send({ action: 'device.set_active', device_id: SN });
await sleep(4000);   // Media Source connect + ffmpeg probe + first frames

let base;
let noise = 0;   // frame-to-frame difference with no camera motion
let moved;       // the panned-away frame, for the return check
await test('OBS renders the camera (not black, not flat)', async () => {
  base = await shot();
  const m = mean(base), s = std(base);
  expect(m > 12, `mean luma ${m.toFixed(1)} - black frame`);
  expect(s > 6, `luma stddev ${s.toFixed(1)} - flat/blank frame`);
  return `mean ${m.toFixed(0)}, stddev ${s.toFixed(0)}`;
});

await test('OBS picture is live, not a frozen frame', async () => {
  live(base, 'baseline');
  // Frozen = byte-identical shots over 2s. A live camera always has sensor
  // noise, and usually a person moving, so the difference is never zero.
  const shots = [base];
  for (let i = 0; i < 4; i++) { await sleep(500); shots.push(await shot()); }
  const ds = shots.slice(1).map((g, i) => diff(shots[i], g));
  noise = Math.max(...ds);
  expect(ds.some((d) => d > 0.05), 'OBS shows the same frame for 2s - the stream is frozen');
  base = shots[shots.length - 1];
  return `scene noise up to ${noise.toFixed(1)}`;
});

await test('ptz.angle pan changes what OBS shows', async () => {
  const target = original.yaw > 0 ? original.yaw - 35 : original.yaw + 35;
  const r = await send({ action: 'ptz.angle', device_id: SN, yaw: target, pitch: original.pitch, roll: 0 });
  expect(r.ok, `ack not ok: ${JSON.stringify(r)}`);
  await sleep(3000);
  moved = await shot();
  live(moved, 'after pan');
  const d = diff(base, moved);
  expect(d > Math.max(12, 2 * noise), `OBS frame changed by only ${d.toFixed(1)} after a 35 deg pan (scene noise ${noise.toFixed(1)})`);
  return `diff ${d.toFixed(1)}`;
});

await test('ptz.angle back returns OBS to the original framing', async () => {
  await send({ action: 'ptz.angle', device_id: SN, yaw: original.yaw, pitch: original.pitch, roll: 0 });
  await sleep(3000);
  const back = await shot();
  live(back, 'after pan back');
  const d = diff(base, back);
  const away = diff(moved, back);
  expect(d < away / 2, `back-frame is ${d.toFixed(1)} from the start but only ${away.toFixed(1)} from the panned frame`);
  return `${d.toFixed(1)} from start vs ${away.toFixed(1)} from panned`;
});

await test('zoom.set 2.0x changes what OBS shows, and back', async () => {
  const r = await send({ action: 'zoom.set', device_id: SN, value: 2.0, final: true });
  expect(r.ok, `ack not ok: ${JSON.stringify(r)}`);
  await sleep(3000);
  const zoomed = await shot();
  live(zoomed, 'at 2x');
  const d = diff(base, zoomed);
  await send({ action: 'zoom.set', device_id: SN, value: original.zoom, final: true });
  await sleep(2500);
  expect(d > Math.max(10, 1.2 * noise), `OBS frame changed by only ${d.toFixed(1)} at 2x zoom (scene noise ${noise.toFixed(1)})`);
  return `diff ${d.toFixed(1)}`;
});

await test('ptz.velocity + ptz.stop: motion stops when told', async () => {
  await send({ action: 'ptz.velocity', device_id: SN, yaw_speed: 40, pitch_speed: 0, roll_speed: 0 });
  await sleep(800);
  await send({ action: 'ptz.stop', device_id: SN });
  await sleep(1200);
  const a = await shot();
  await sleep(1000);
  const b = await shot();
  live(a, 'after stop');
  const d = diff(a, b);
  await send({ action: 'ptz.angle', device_id: SN, yaw: original.yaw, pitch: original.pitch, roll: 0 });
  await sleep(2500);
  expect(d < Math.max(12, 1.5 * noise), `picture still changing by ${d.toFixed(1)} after ptz.stop (scene noise ${noise.toFixed(1)})`);
  return `post-stop drift ${d.toFixed(1)}`;
});

// ---- TAKE, using a second (non-OBSBOT) webcam as the other program source --
const { sources = [] } = await send({ action: 'source.list' });
const webcam = sources.find((s) => !s.obsbot);
let addedId = null;
if (!webcam) {
  skipTest('TAKE cut / crossfade in OBS', 'no second, non-OBSBOT webcam to switch to');
} else {
  console.log(`  [take] second source: ${webcam.name}`);
  await send({ action: 'source.add', unique_id: webcam.unique_id, label: 'E2E webcam' });
  addedId = `av:${webcam.unique_id}`;
  await sleep(2500);
  const obsbotShot = await shot();
  let webcamShot;
  live(obsbotShot, 'before TAKE');

  await test('TAKE cut: OBS switches to the other camera, same Media Source', async () => {
    const r = await send({ action: 'device.set_active', device_id: addedId });
    expect(r.ok, `ack not ok: ${JSON.stringify(r)}`);
    await sleep(1500);
    webcamShot = await shot();
    const d = diff(obsbotShot, webcamShot);
    live(webcamShot, 'after cut');
    expect(d > Math.max(12, 2 * noise), `OBS frame changed by only ${d.toFixed(1)} after the cut`);
    return `diff ${d.toFixed(1)}`;
  });

  await test('TAKE crossfade: OBS shows an in-between frame, then the target', async () => {
    const fadeMs = 2000;
    const r = await send({ action: 'device.set_active', device_id: SN, fade_ms: fadeMs });
    expect(r.ok, `ack not ok: ${JSON.stringify(r)}`);
    await sleep(fadeMs / 2);
    const mid = await shot();
    await sleep(fadeMs / 2 + 1200);
    const end = await shot();
    const total = diff(webcamShot, end);
    const fromStart = diff(webcamShot, mid), toEnd = diff(mid, end);
    const toObsbot = diff(obsbotShot, end), toWebcam = diff(webcamShot, end);
    expect(toObsbot < toWebcam / 2,
      `after the fade OBS is ${toObsbot.toFixed(1)} from the OBSBOT and ${toWebcam.toFixed(1)} from the webcam`);
    // A hard cut makes mid equal one endpoint; a dissolve sits between both.
    expect(fromStart > total * 0.2 && toEnd > total * 0.2,
      `mid-fade frame not between endpoints (from start ${fromStart.toFixed(1)}, to end ${toEnd.toFixed(1)}, total ${total.toFixed(1)})`);
    return `mid is ${(100 * fromStart / (fromStart + toEnd)).toFixed(0)}% of the way`;
  });
}

// ------------------------------------------------------------- restore ----
if (addedId) await send({ action: 'source.remove', device_id: addedId }).catch(() => {});
if (original.active) await send({ action: 'device.set_active', device_id: original.active }).catch(() => {});
await send({ action: 'ptz.angle', device_id: SN, yaw: original.yaw, pitch: original.pitch, roll: 0 }).catch(() => {});
await send({ action: 'zoom.set', device_id: SN, value: original.zoom, final: true }).catch(() => {});

console.log(`\n=== RESULTS ===\n${pass} passed, ${fail} failed, ${skip} skipped`);
console.log(`OBS scene "${SCENE}" left on air for a visual check; no other scene is touched.`);
await obs.disconnect();
ws.close();
process.exit(fail === 0 ? 0 : 1);

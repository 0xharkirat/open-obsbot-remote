#!/usr/bin/env node
// P4 library export/import round-trip. Needs the library-capable bridge.
//
//   node tests/library.mjs
//
// Proves the migrate-to-new-Mac path: export returns the authored library
// (sequences + mix + names), import merges a blob back, and a re-export
// reflects it. Presets are NOT part of the library (they live on the camera).

import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';

const AUTH = JSON.parse(
  fs.readFileSync(`${os.homedir()}/Library/Application Support/Open OBSBOT Bridge/auth.json`, 'utf8'));
const token = AUTH.tokens[0];

const ws = new WebSocket('ws://localhost:8765/v1');
let nextId = 1;
const acks = new Map();
function send(msg) {
  msg.id = String(nextId++);
  return new Promise((res, rej) => {
    const t = setTimeout(() => { acks.delete(msg.id); rej(new Error(`ack timeout ${msg.action}`)); }, 5000);
    acks.set(msg.id, { res: (r) => { clearTimeout(t); res(r); } });
    ws.send(JSON.stringify(msg));
  });
}
ws.on('message', (raw) => {
  const j = JSON.parse(raw.toString());
  if (j.event === 'state') return;
  if (j.id && acks.has(j.id)) { acks.get(j.id).res(j); acks.delete(j.id); }
});
ws.on('error', (e) => { console.error('[ws]', e.message); process.exit(2); });

let pass = 0, fail = 0;
const test = async (name, fn) => {
  try { await fn(); pass++; console.log(`  ${name}... PASS`); }
  catch (e) { fail++; console.log(`  ${name}... FAIL: ${e.message}`); }
};
const assert = (c, m) => { if (!c) throw new Error(m); };

await new Promise((r, j) => { ws.once('open', r); ws.once('error', j); });
await send({ action: 'hello', token });

console.log('=== P4 LIBRARY BATTERY ===');

await test('library.export returns version + sections', async () => {
  const r = await send({ action: 'library.export' });
  assert(r.ok === true, 'not ok');
  assert(r.library && typeof r.library === 'object', 'no library');
  assert(r.library.version === 1, `version=${r.library.version}`);
  assert('sequences' in r.library && 'mix' in r.library && 'names' in r.library, 'missing sections');
});

await test('import merges a mix entry; re-export reflects it', async () => {
  const blob = {
    version: 1,
    mix: { LIB_IMPORT_TEST: { mode: 'forward', cues: [] } },
    sequences: {},
    names: {},
  };
  const imp = await send({ action: 'library.import', library: blob });
  assert(imp.ok === true, 'import not ok');
  const r = await send({ action: 'library.export' });
  assert('LIB_IMPORT_TEST' in r.library.mix, 're-export missing imported mix');
});

await test('imported mix is loadable', async () => {
  const r = await send({ action: 'mix.load', name: 'LIB_IMPORT_TEST' });
  assert(r.ok === true, `load failed: ${r.err}`);
});

await test('import with no library object -> invalid_param', async () => {
  const r = await send({ action: 'library.import' });
  assert(r.ok === false && r.err === 'invalid_param', `err=${r.err}`);
});

// cleanup
await send({ action: 'mix.delete', name: 'LIB_IMPORT_TEST' });

console.log(`\n=== RESULTS ===\n${pass}/${pass + fail} passed`);
ws.close();
process.exit(fail === 0 ? 0 : 1);

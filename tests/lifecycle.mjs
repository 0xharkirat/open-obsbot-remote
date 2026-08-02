// Parent-death watchdog: does the bridge exit when its supervisor goes away?
//
// Both failure directions of this are silent, which is why it needs a test.
// If it stops firing, the orphan bug comes back and nobody notices until a
// camera is stuck. If it fires wrongly, a live bridge dies mid-service.
//
//   node tests/lifecycle.mjs [path-to-obsbot-bridge]
//
// Defaults to the dev build. Uses a spare port so it never disturbs a running
// bridge, and needs no camera: the watchdog is wired before any device work.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';

const BIN = process.argv[2] ?? 'apps/bridge_cpp/build-dev/obsbot-bridge';
const PORT = 8797;
const results = [];

function check(name, ok, detail = '') {
  results.push(ok);
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  ' + detail : ''}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const alive = (pid) => {
  try { process.kill(pid, 0); return true; } catch { return false; }
};

if (!existsSync(BIN)) {
  console.error(`bridge binary not found at ${BIN}`);
  console.error('build it first: cmake --build apps/bridge_cpp/build-dev --target obsbot-bridge');
  process.exit(1);
}

// A stand-in supervisor: spawns the bridge exactly the way the Flutter app
// does (stdin as a pipe it holds open), then dies when we kill it.
function startSupervised() {
  const sh = spawn('/bin/sh', ['-c', `exec "${BIN}" --port ${PORT}`], {
    stdio: ['pipe', 'ignore', 'ignore'],
  });
  return sh;
}

// 1. The child must NOT exit while its supervisor is alive and healthy.
//    This is the direction that would kill a live service, so it is checked
//    first and given the longest look.
{
  const sup = startSupervised();
  await sleep(4000);
  const stillUp = alive(sup.pid);
  check('bridge survives while the supervisor is alive', stillUp,
        stillUp ? '4s, no spurious exit' : 'exited on its own');
  sup.kill('SIGKILL');
  await sleep(1500);
}

// 2. SIGKILL the supervisor (the force-quit / crash case, where no cleanup
//    code inside the parent can possibly run). The child must notice the
//    pipe close and exit by itself, promptly.
{
  const sup = startSupervised();
  await sleep(2500);
  const kid = sup.pid;
  const t0 = Date.now();
  sup.kill('SIGKILL');

  let gone = false;
  while (Date.now() - t0 < 5000) {
    await sleep(100);
    if (!alive(kid)) { gone = true; break; }
  }
  const ms = Date.now() - t0;
  check('bridge exits when the supervisor is SIGKILLed', gone,
        gone ? `${ms}ms` : 'still running after 5s - camera would stay held');
  check('exit is prompt (under 2s)', gone && ms < 2000, `${ms}ms`);
  if (!gone) spawnSync('pkill', ['-9', '-f', `port ${PORT}`]);
}

// 3. The port must be free afterwards - a held listener is the other half of
//    the original bug and blocks the next launch.
{
  const r = spawnSync('lsof', ['-nP', `-iTCP:${PORT}`, '-sTCP:LISTEN'], { encoding: 'utf8' });
  check('listening port released', !r.stdout.trim(), r.stdout.trim() || 'free');
}

const passed = results.filter(Boolean).length;
console.log(`\n${passed}/${results.length} passed`);
process.exit(passed === results.length ? 0 : 1);

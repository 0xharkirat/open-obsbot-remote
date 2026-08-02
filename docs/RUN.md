# Run And Test

This is the manual test guide for a local source build or downloaded release bundle.

## Recommended Path: Run The App Bundle

1. Build the bundle:

   ```bash
   ./scripts/build-bridge-mac.sh
   ```

2. Quit OBSBOT Center and any other app controlling the camera.

3. Plug the camera into the computer over USB and wait for it to finish booting.

4. Launch the bridge app:

   ```bash
   open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
   ```

5. Allow the Camera and Local Network permission prompts.

6. Click `Reveal` in the bridge window. The app shows a 6-digit PIN, QR code, and local URL.

7. Open the shown URL from a phone, tablet, or browser on the same LAN.

8. Enter the PIN once. The remote should load the live preview and controls.

## Quick Smoke Test

After pairing, verify:

- Live preview updates.
- `Recenter` moves the camera to home.
- Joystick drag moves pan/tilt and release stops motion.
- Zoom slider moves between the shown min/max values.
- Save a preset, recall it, and confirm active preset highlight.
- Start a short two-step sequence, confirm it advances, then stop it.
- Sleep and wake work.
- Quit/reopen the phone browser and confirm it reconnects without asking for the PIN again.

## Bridge-Only Development

For C++ bridge work, run the subprocess directly:

```bash
./run-bridge.sh
```

This prints LAN URLs such as:

```text
ws://192.168.1.20:8765/v1
```

Health check:

```bash
curl http://localhost:8765/health
```

Expected response:

```text
ok
```

The direct bridge path is useful for protocol testing, but the terminal process needs macOS Camera permission for preview capture. The `.app` path is the realistic end-user path because the signed bundle controls the permission identity.

## Native Remote Development

The web remote is served automatically by the bridge app. To run native clients during development:

```bash
cd apps/rc
flutter devices
flutter run -d <device-id>
```

Connect to the bridge host shown in the bridge app, for example:

```text
192.168.1.20:8765
```

Android needs cleartext local-network traffic enabled; this is already set in the app manifest. iOS needs Local Network permission; allow it on first launch.

## WebSocket Fault Isolation

Because the bridge is PIN/token-gated, a raw WebSocket test needs a token. The easiest way to obtain one is through the HTTP pairing endpoint while the PIN is visible in the bridge app:

```bash
curl -s \
  -H 'Content-Type: application/json' \
  -d '{"pin":"123456"}' \
  http://localhost:8765/pair
```

Example response:

```json
{"ok":true,"token":"<token>"}
```

Then connect with a WebSocket client:

```bash
wscat -c ws://localhost:8765/v1
```

Send:

```json
{"action":"hello","id":"1","token":"<token>","client":{"name":"cli","version":"0"}}
```

Then:

```json
{"action":"subscribe","id":"2"}
{"action":"ptz.angle","id":"3","yaw":20,"pitch":0}
{"action":"zoom.set","id":"4","value":1.5}
{"action":"ptz.recenter","id":"5"}
```

The camera should move for each command and `state` events should flow back.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Bridge cannot find the SDK | Run `./scripts/verify-sdk.sh` and place the SDK at `third_party/obsbot-sdk/`. |
| Build fails because `cmake` or `asio.hpp` is missing | Run `brew install cmake asio`. |
| Preview is disabled | Confirm macOS Camera permission for the process you launched. Use the `.app` path for realistic permission behavior. |
| Phone cannot connect | Confirm both devices are on the same LAN and not isolated by guest Wi-Fi, VPN, or firewall rules. |
| Pairing fails | Click `Reveal` again and use the current PIN. If needed, reset pairing in the bridge UI. |
| PTZ returns `device_busy` | Quit OBSBOT Center or any other camera-control app, then restart Open OBSBOT Bridge. |
| Camera never appears | Replug the camera, try another USB cable/port, and wait for boot to finish. |
| Web remote looks stale after a new build | Use the cache-clear menu in the remote, then reload. Compare the version in the remote's footer against the bridge's Settings: if they differ, that browser is serving a cached build. |
| Camera indicator stays lit after quitting | Check for a surviving helper with `pgrep -x obsbot-bridge`. It should exit within a second of the app closing; if one is left, it predates v2.5.2 or was launched by hand. Run `pkill -9 -x obsbot-bridge`. |
| Remote will not load with the internet down | Confirm the build serves CanvasKit locally: `curl -s http://localhost:8765/flutter_bootstrap.js \| grep useLocalCanvasKit` should print `true`. Builds before v2.5.1 fetch the engine from a CDN and cannot start offline. |

## Reset Local State

Pairing and sequences are local files:

```text
~/Library/Application Support/Open OBSBOT Bridge/auth.json
~/Library/Application Support/Open OBSBOT Bridge/sequence.json
~/Library/Application Support/Open OBSBOT Bridge/sequences.json
```

Prefer using the bridge UI reset buttons. Delete these files only when debugging local development state.

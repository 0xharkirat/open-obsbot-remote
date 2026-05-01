# How to test the OBSBOT Tiny 2 Lite control app

## What's built

- `bridge/` — C++ WebSocket bridge that talks to the camera over USB. Already built at `bridge/build/obsbot-bridge`.
- `client/` — Flutter app (iOS + macOS targets) with PTZ pad, zoom slider, presets, AI/HDR toggles, FOV cycling.

## Step 1 — Plug in the camera

Connect the Tiny 2 Lite to the Mac via USB. Wait for the boot sequence to finish (LED stops flashing).

## Step 2 — Start the bridge

In a terminal:

```bash
cd /Users/hark/flutter_projects/obsbot.workspace
./run-bridge.sh
```

You should see:

```
ws server listening on 0.0.0.0:8765  path=/v1  health=/health
device session started; waiting for camera plug-in...
device plugged sn=ABC...
active device: ABC... (Tiny 2 Lite) fw=...
```

The script also prints your Mac's LAN URLs — copy one (e.g. `ws://10.250.1.51:8765/v1`).

Quick sanity check while the bridge runs (in another terminal):
```bash
curl http://localhost:8765/health    # → "ok"
```

## Step 3 — Run the Flutter client

### Easiest: macOS desktop (same Mac)

```bash
cd /Users/hark/flutter_projects/obsbot.workspace/client
flutter run -d macos
```

When the app opens, type `127.0.0.1:8765` (or `localhost:8765`) in the Bridge address field and tap **Connect**.

### Goal: iPhone 17 Pro over Wi-Fi

1. Plug iPhone into the Mac with a USB cable.
2. On iPhone: **Settings → Privacy & Security → Developer Mode → On** (requires reboot the first time).
3. Open Xcode once (`open -a Xcode`) and accept the license if prompted; sign in with your Apple ID under **Xcode → Settings → Accounts**.
4. Open the Runner project once: `open client/ios/Runner.xcworkspace`. Select the **Runner** target → **Signing & Capabilities** → set **Team** to your Personal Team. Close Xcode after the team is set.
5. List devices to confirm the iPhone appears:
   ```bash
   flutter devices
   ```
6. Run the app on the iPhone:
   ```bash
   cd client
   flutter run -d <iphone-id>
   ```
   The `<iphone-id>` comes from `flutter devices` (looks like a UDID).
7. The first launch shows a "Untrusted Developer" prompt on the iPhone — go to **Settings → General → VPN & Device Management → Developer App** and trust your Apple ID.
8. iOS will ask "Allow OBSBOT Control to find devices on your local network?" → **Allow**.
9. In the app, type the LAN address printed by `run-bridge.sh` (e.g. `10.250.1.51:8765`) and tap **Connect**.

## Step 4 — Use it

Once connected the control screen appears.

| Control | Effect |
|---|---|
| Drag the round pad | Pan/tilt at variable speed (faster as you drag farther from center). Bridge auto-disables AI on first move. |
| Release the pad | Camera stops moving |
| Vertical slider on the right | Set zoom level (1.0× – 4.0×) |
| **Recenter** | Move gimbal to yaw=0, pitch=0 |
| **Sleep / Wake** | Toggle camera sleep |
| **AI HUMAN** | Toggle Human tracking on/off |
| **HDR** | Toggle HDR (3 s debounce — second toggle within 3 s is rejected) |
| **FOV ##°** | Cycle 86° → 78° → 65° → 86° |
| **P1..P4** tap | Recall preset slot 0..3 |
| **P1..P4** long-press | Save current PTZ + zoom into that slot |
| Top status bar | Live yaw / pitch / zoom / AI / FOV from the bridge |
| `### ms` in title bar | Round-trip ping (refreshed every 3 s) |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Bridge prints `device unplugged` immediately or never sees camera | Unplug + replug, try a different cable. Camera must be powered (LED on). |
| `Connection refused` from phone | Mac and phone aren't on the same Wi-Fi. Check Mac IP shown by run-bridge; try other interface IPs (`ifconfig`). VPNs commonly break this. |
| `device_busy` errors after long use | Camera firmware glitch. Sleep it (`Sleep` button) and wake it again. |
| HDR toggle says `debounced` | Wait 3 s and try again. |
| Manual PTZ does nothing while AI is on | Bridge automatically turns AI off on first manual command — try once more. |
| Building bridge fails | Run `brew install cmake asio` then `rm -rf bridge/build && ./run-bridge.sh`. |
| iOS app can't connect | Confirm "Local Network" permission was granted (Settings → Privacy → Local Network). |

## Quick fault-isolation test (no Flutter)

If you suspect the bridge or camera, test with `wscat` (no phone needed):

```bash
brew install ws  # if you don't have wscat already
wscat -c ws://localhost:8765/v1
> {"action":"hello","id":"1","client":{"name":"cli","version":"0"}}
> {"action":"subscribe","id":"2"}
> {"action":"ptz.angle","id":"3","yaw":30,"pitch":-10}
> {"action":"zoom.set","id":"4","value":1.5}
> {"action":"ptz.recenter","id":"5"}
```

Camera should physically move on each command. State events flow back as JSON.

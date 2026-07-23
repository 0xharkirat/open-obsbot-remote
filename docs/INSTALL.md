# Install the bridge on macOS

This guide takes you from a downloaded release to a paired phone and a live picture in OBS.

The Homebrew cask clears the download quarantine for you, so it skips the Gatekeeper steps.
Use the DMG only when you want a specific version or cannot use Homebrew.

## Prerequisites

- You have a Mac running macOS 12 Monterey or later.
- You have at least 1 OBSBOT camera connected over USB.
- You have quit OBSBOT Center. Both apps claim the same camera control endpoint, and PTZ commands fail with `device_busy` while it runs.
- You have OBS installed on the same Mac, or on another machine on the same network.

## Install with Homebrew

Run:

```bash
brew install --cask 0xharkirat/tap/open-obsbot-bridge
```

The command taps [0xharkirat/homebrew-tap](https://github.com/0xharkirat/homebrew-tap), installs the app into `/Applications`, and clears the quarantine flag.
Upgrade later with `brew upgrade --cask open-obsbot-bridge`.

Open the app from `/Applications`, then continue at [Grant camera access](#grant-camera-access).

## Install from the DMG

1. Download `Open-OBSBOT-Bridge-universal.dmg` from the [latest release](https://github.com/0xharkirat/open-obsbot-remote/releases/latest). The build runs on both Apple Silicon and Intel.
2. Open the DMG and drag `Open OBSBOT Bridge.app` into `Applications`.
3. Clear the quarantine flag:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Open OBSBOT Bridge.app"
   ```

Step 3 replaces the 3 Gatekeeper dialogs described in [Clear Gatekeeper by hand](#clear-gatekeeper-by-hand).
After it, open the app and continue at [Grant camera access](#grant-camera-access).

### Clear Gatekeeper by hand

Take this route when you would rather not run the `xattr` command.
The app is ad-hoc signed rather than notarized, so macOS blocks the first launch.

1. Double-click `Open OBSBOT Bridge` in `Applications`. macOS reports that the app was not opened. Click **Done**. Do not click **Move to Bin**.

   <img src="images/step-1-click-done.png" alt="macOS reports that Open OBSBOT Bridge.app was not opened" width="260"/>

2. Open **System Settings** > **Privacy & Security**, and scroll to the Security section. Next to the message that the app was blocked, click **Open Anyway**.

   <img src="images/step-2-settings-privacy-security-open-anyway.png" alt="The Privacy and Security pane with the Open Anyway button" width="500"/>

3. At the confirmation dialog, click **Open Anyway** again, and enter your Mac password if you are asked for it.

   <img src="images/step-3-open-anyway-again.png" alt="The second confirmation dialog with the Open Anyway button" width="280"/>

These 3 dialogs appear only on the first launch.

## Grant camera access

1. At the Camera access prompt, click **Allow**.

   <img src="images/step-4-allow-camera.png" alt="The macOS camera access prompt for Open OBSBOT Bridge" width="400"/>

   Answer within 60 seconds. The capture path times out after that, and you have to grant access and restart the bridge.

2. At the firewall prompt, click **Allow** so `obsbot-bridge` can accept incoming connections.

   <img src="images/step-5-allow-incoming-connections.png" alt="The macOS prompt to allow incoming network connections" width="400"/>

## Pair a controller

1. In the bridge window, click **Reveal**. The pairing PIN and QR code show for 60 seconds.
2. Choose a controller:

   - Phone browser: scan the QR code. The web remote opens and pairs itself, because the QR encodes the PIN in the URL fragment.
   - Phone app: tap **Scan QR** on the connect screen.
   - Desktop app: click **Copy link** in the bridge window, then **Paste link** on the connect screen.
   - Any device, by hand: open `http://<mac-ip>:8765/` and enter the 6-digit PIN.

The controller stores a token, so later connections need no PIN.

## Point OBS at the bridge

1. In the bridge window, copy the OBS output URL.
2. In OBS, add a **Media Source**, and clear **Local File**.
3. Paste the URL into **Input**, and set **Input Format** to `mjpeg`.
4. Set **Reconnect Delay** to 2 seconds, and clear **Restart playback when source becomes active**.
5. In **FFmpeg Options**, enter:

   ```text
   reconnect=1 reconnect_streamed=1 reconnect_delay_max=2
   ```

A Media Source decodes the stream with ffmpeg. A Browser Source runs a full Chromium instance for the same job, drops frames under load, and never reconnects when a stream ends.

## Verification

- The bridge window shows each connected camera with a status dot and a preview.
- The remote shows the camera bus, and pressing **TAKE** changes which camera OBS displays.
- The bridge log records `video: capture session started`:

  ```bash
  grep "capture session started" ~/Library/Logs/Open\ OBSBOT\ Bridge/bridge.log
  ```

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Preview is blank | Confirm camera permission for Open OBSBOT Bridge in System Settings > Privacy & Security > Camera. If you left the first prompt unanswered, grant it and restart the bridge. |
| The controller cannot connect | Put the controller and the Mac on the same network. VPNs and guest Wi-Fi usually block local devices. |
| PTZ commands fail with `device_busy` | Quit OBSBOT Center, then restart the bridge. |
| A camera never appears | Try another USB cable or port. Cameras take 6 to 20 seconds to enumerate. |
| OBS shows a frozen frame | Confirm the source is a Media Source with a reconnect delay, not a Browser Source. |

## Next steps

- [Run and test](RUN.md) covers the manual test pass.
- [Cameras](CAMERAS.md) lists model support.
- [Build from source](BUILD.md) covers development builds.

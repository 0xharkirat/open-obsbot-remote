# Running the bridge on Windows

Windows gets the full desktop product, not just the headless binary: the same
Flutter supervisor window as macOS, a notification-area icon, and the bundled
`obsbot-bridge.exe` subprocess serving the WebSocket API on `:8765`, the MJPEG
preview on `:8766` and the web remote at `http://<pc>:8765/`.

Verified on Windows 11 (26H2), x64, MSVC 19.44, against a Tiny 2 Lite on
firmware 6.2.8.1.

## Prerequisites

- **Visual Studio 2022** with the "Desktop development with C++" workload.
  Build Tools alone is enough:
  ```powershell
  winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
  ```
  MSVC is required, not optional: `libdev.lib` is an MSVC import library and
  does not link with MinGW.
- **Flutter** on PATH.
- **Developer Mode** on (Settings > System > For developers). Flutter needs it
  to symlink plugins for any Windows or web build; without it the build stops
  with "Building with plugins requires symlink support".
- **The OBSBOT SDK** at `third_party/obsbot-sdk/`, including its `windows/`
  directory (`win64-release/libdev.lib`, `libdev.dll`, `w32-pthreads.dll`). See
  [Getting the SDK](GETTING_THE_SDK.md).

Standalone Asio is fetched by CMake at configure time (pinned to 1.30.2 by
hash), so there is nothing else to install.

## Build

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-bridge-windows.ps1                    # build
powershell -ExecutionPolicy Bypass -File scripts\build-bridge-windows.ps1 -Zip -Installer    # release
```

A release build writes three files to `dist\`:

| File | What it is |
| --- | --- |
| `Open-OBSBOT-Bridge-Setup-<ver>-x64.exe` | Inno Setup installer (needs [Inno Setup 6](https://jrsoftware.org/isdl.php) to build). Installs to Program Files, adds a Start menu entry, adds the Windows Firewall rule for `obsbot-bridge.exe` on Private and Public networks (venue Wi-Fi is usually classed Public), optional start-at-login, removes the rule on uninstall. Pairing state in `%APPDATA%` survives uninstall. Script: `apps/bridge/windows/installer/open-obsbot-bridge.iss`. |
| `Open-OBSBOT-Bridge-<ver>-windows-x64.zip` | The same files, portable. Windows prompts for the firewall the first time instead. |
| `SHA256SUMS-<ver>.txt` | Checksums to publish with the release. |

Both carry the VC++ runtime DLLs app-locally (from VS's `Microsoft.VC143.CRT`), so they run on a PC without the VC++ Redistributable.

The builds are not code-signed (neither is 7-Zip). SmartScreen shows "Windows protected your PC" for a new download; users click **More info > Run anyway**. Never change the installer's `AppId`: upgrades find the installed copy by it.

The zip and installer contain OBSBOT's `libdev.dll`. Check OBSBOT's SDK terms before publishing them.

That builds the C++ bridge, the web remote and the Flutter app, in that order,
and the Flutter build copies the first two into the bundle:

```
apps\bridge\build\windows\x64\runner\Release\
  open_obsbot_bridge.exe     the supervisor window + tray icon
  obsbot-bridge.exe          the C++ bridge subprocess
  libdev.dll, w32-pthreads.dll
  web\                       the remote, served at http://<pc>:8765/
  data\, flutter_windows.dll, *_plugin.dll
```

The folder is self-contained, VC++ runtime included, so it runs on another
machine as-is.

For C++-only iteration:

```powershell
cmake -S apps/bridge_cpp -B apps/bridge_cpp/build -G "Visual Studio 17 2022" -A x64
cmake --build apps/bridge_cpp/build --config Release
apps\bridge_cpp\build\Release\obsbot-bridge.exe --port 8765 --web-root apps\rc\build\web
```

`flutter run -d windows` in `apps/bridge` also works: the supervisor walks up
from the runner to find `apps\bridge_cpp\build\Release\obsbot-bridge.exe`.

## First run

1. Quit OBSBOT Center if it is running. Both drive the camera's control
   endpoint and PTZ will return `device_busy` (CLAUDE.md gotcha #19).
2. Windows Defender Firewall prompts for `obsbot-bridge.exe` the first time it
   listens. Allow **Private networks**, or phones on the Wi-Fi cannot connect.
   A dismissed prompt is undone under "Allow an app through Windows Defender
   Firewall", which the bridge window links to.
3. Camera access is one system switch, Settings > Privacy & security > Camera >
   "Let desktop apps access your camera". There is no per-app prompt on
   Windows. When it is off the bridge logs
   `mf: camera access denied ...` and the window shows the camera as denied.

## What differs from macOS

**Capture is Media Foundation.** `src/video_capture_win.cpp` asks an
`IMFSourceReader` for the camera's native MJPEG type (1080p, highest frame rate
up to 30) with video processing off, so MF hands back the camera's JPEG
untouched and capture is one copy per frame, as on Linux. A webcam that offers
no MJPEG falls back to RGB32 plus a WIC JPEG encode, which is what macOS does
for every camera. Measured: `active.mjpg` runs at about 81 Mbps at 1080p30,
matching the Linux figure.

**Fades work.** `jpeg_darken` and `jpeg_crossfade` decode, blend and re-encode
with Windows Imaging Component, which ships with the OS. This is the one place
Windows is ahead of Linux, which still hard-cuts.

**The SN join is exact, even with identical cameras.** `Device::videoDevPath()`
exists on Windows (it returns `std::wstring`), but it is the DirectShow
interface path, class `{65e8773d-...}` (KSCATEGORY_VIDEO), while MF enumerates
the same camera under `{e5323777-...}` (KSCATEGORY_VIDEO_CAMERA). Everything
before `#{` is the device instance and matches in both, so the bridge joins on
that. A Tiny 2 Lite reports no USB serial, but Windows derives the instance ID
from the port, so two of them still get distinct paths. Contrast Linux, where
the join is positional.

**Paths.** Settings and pairing state live in `%APPDATA%\Open OBSBOT Bridge\`
(`auth.json`, `sequence.json`, `sequences.json`, ...); the log is
`%LOCALAPPDATA%\Open OBSBOT Bridge\Logs\bridge.log`. The supervisor holds the log
open for writing, so read it with a tool that opens files share-read-write,
for example `Get-Content -Tail`.

**Dying with the supervisor** uses the same stdin pipe as macOS. Dart gives the
child an anonymous pipe; when the supervisor dies by any means, `ReadFile` on it
fails and the bridge logs `supervisor gone; exiting so the camera is released`
before exiting. Verified by force-killing `open_obsbot_bridge.exe`. Under a
console, stdin is a console handle, not a pipe, so the watchdog stays off.

**Tray.** `windows/runner/native_tray.cpp` implements the `obsbot.bridge/tray`
channel that `NativeTray.swift` does on macOS, so the Dart tray code is shared.
Left click shows the window, right click opens the menu. Template icons are
recoloured white or black to contrast with the taskbar theme.

**One instance.** A named mutex keeps a second copy from starting; launching
again brings the running window forward.

**No H.264 path.** `--h264` is Linux-only (it forks ffmpeg), and is not
compiled into the Windows build.

**The window still uses macos_ui.** It renders correctly on Windows, but it
looks like a Mac app. A Fluent restyle is separate work.

## Tests

The Node batteries in `tests/` read `auth.json` from the platform location via
`tests/paths.mjs`, so they run on Windows unchanged once a token exists (pair
once from a phone or the web remote). With one camera: `library.mjs` passes 4/4.
`fade.mjs` fails its dip check on every platform since crossfades landed: it
re-takes the camera already on air, so the "outgoing" frame is the same scene
and the dissolve never darkens. `bridge_smoke.mjs` and `exposure.mjs` still
expect the v1 `state.device` shape. `mix_sequence.mjs` and `two_cam_smoke.mjs`
need two cameras.

# Windows notes

This page is for developers.
To install a release, see [Install the bridge](INSTALL.md#install-on-windows).

On Windows, the bridge is the full desktop app, as on macOS.
It has 3 parts:

- `open_obsbot_bridge.exe`: the bridge window and the tray icon.
- `obsbot-bridge.exe`: the C++ bridge. It serves the WebSocket API on `:8765`, the MJPEG preview on `:8766`, and the web remote at `http://<pc>:8765/`.
- `libdev.dll` and `w32-pthreads.dll`: the OBSBOT SDK runtime.

Tested on Windows 11 (26H2), x64, MSVC 19.44, with a Tiny 2 Lite on firmware 6.2.8.1.

## Prerequisites

- Install Visual Studio 2022 with the **Desktop development with C++** workload. Build Tools is sufficient:

  ```powershell
  winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
  ```

  You must use MSVC. `libdev.lib` is an MSVC import library. It does not link with MinGW.

- Install Flutter, and put it on `PATH`.
- Turn on **Developer Mode**: **Settings** > **System** > **For developers**. Flutter needs it to make plugin symlinks. If it is off, the build stops with "Building with plugins requires symlink support".
- Put the OBSBOT SDK at `third_party/obsbot-sdk/`. Include its `windows/` directory: `win64-release/libdev.lib`, `libdev.dll` and `w32-pthreads.dll`. See [Getting the SDK](GETTING_THE_SDK.md).
- To make the installer, install [Inno Setup 6](https://jrsoftware.org/isdl.php).

CMake downloads Asio during configuration. The version is 1.30.2, checked by hash. You do not install it.

## Build

To build the app, run this command from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-bridge-windows.ps1
```

The script builds 3 items, in this sequence:

1. The C++ bridge, with MSVC.
2. The web remote.
3. The Flutter Windows app. This step copies the bridge, the SDK runtime and the web remote into the app folder.

The script also copies the VC++ runtime DLLs into the app folder, from `Microsoft.VC143.CRT` in Visual Studio. Thus the app runs on a PC that does not have the VC++ Redistributable.

The result is one folder that you can copy to a different PC:

```text
apps\bridge\build\windows\x64\runner\Release\
  open_obsbot_bridge.exe     bridge window and tray icon
  obsbot-bridge.exe          C++ bridge
  libdev.dll, w32-pthreads.dll
  vcruntime140*.dll, msvcp140*.dll
  web\                       web remote
  data\, flutter_windows.dll, *_plugin.dll
```

### Make a release

To make the release files, add `-Zip -Installer`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-bridge-windows.ps1 -Zip -Installer
```

The script writes 3 files to `dist\`:

| File | Contents |
| --- | --- |
| `Open-OBSBOT-Bridge-Setup-<ver>-x64.exe` | The installer. The script is `apps/bridge/windows/installer/open-obsbot-bridge.iss`. |
| `Open-OBSBOT-Bridge-<ver>-windows-x64.zip` | The same files, with no installer. |
| `SHA256SUMS-<ver>.txt` | Checksums. Publish this file with the release. |

The installer does these steps:

- It installs the app in Program Files, with a Start menu entry.
- It adds a Windows Firewall rule for `obsbot-bridge.exe` on private and public networks. Windows usually classes venue Wi-Fi as public. A rule for private networks only blocks all phones there.
- It can start the app when the user signs in. This is an option.
- It closes a running bridge before an upgrade.
- On uninstall, it removes the firewall rule. It keeps the pairing data in `%APPDATA%`.

Do not change `AppId` in the installer script. Upgrades use it to find the installed copy.

The builds are not code-signed. 7-Zip is not signed either. Thus SmartScreen shows "Windows protected your PC" for a new download. The user clicks **More info** > **Run anyway**.

The zip and the installer contain OBSBOT's `libdev.dll`. Read OBSBOT's SDK terms before you publish them.

### Build only the C++ bridge

```powershell
cmake -S apps/bridge_cpp -B apps/bridge_cpp/build -G "Visual Studio 17 2022" -A x64
cmake --build apps/bridge_cpp/build --config Release
apps\bridge_cpp\build\Release\obsbot-bridge.exe --port 8765 --web-root apps\rc\build\web
```

You can also run `flutter run -d windows` in `apps/bridge`.
The bridge window then finds `apps\bridge_cpp\build\Release\obsbot-bridge.exe` in the repository.

## First run

1. Quit OBSBOT Center. It uses the same camera control endpoint, and PTZ commands then fail with `device_busy`.
2. In OBS, remove any **Video Capture Device** that reads the OBSBOT. On Windows, only one app can use a camera at a time. OBS must read `active.mjpg` through a Media Source.
3. If you did not use the installer, Windows Firewall asks about `obsbot-bridge.exe`. Tick **Private** and **Public**, then click **Allow**.
4. Make sure that **Settings** > **Privacy & security** > **Camera** > **Let desktop apps access your camera** is on. Windows has no camera prompt for each desktop app. If this switch is off, the log shows `mf: camera access denied`.

## Differences from macOS

### Capture

`src/video_capture_win.cpp` uses Media Foundation.
It asks the camera for its own MJPEG format: 1080p, at the highest frame rate up to 30.
Video processing is off, so Media Foundation gives the camera's JPEG frames without change.
Capture is one copy for each frame, as on Linux.

Some webcams do not supply MJPEG.
For them, the bridge reads RGB32 and encodes JPEG with Windows Imaging Component (WIC).
macOS encodes every frame in this way.

At 1080p30, `active.mjpg` uses approximately 81 Mbps. This is the same as on Linux.

### A camera that a different app holds

On Windows, only one app can use a camera at a time.
If OBS, OBSBOT Center or a video call opens the camera first, the capture fails with `0xC00D3704`.
The bridge then tries again every 2 seconds, and logs `mf: camera is in use by another app`.
When the other app releases the camera, the preview starts again. You do not restart the bridge.

### One picture format for OBS

OBS's Media Source stops with an error if the frame size or the chroma format changes during an MJPEG stream.
We saw this in OBS 32.2.2: the crash is in `swscale-9.dll`, on `mp_media_thread`.

On Windows, camera frames go through without change. Thus a TAKE between 2 different cameras can change the format. For example, a Tiny 2 Lite sends 1080p 4:2:2, and a laptop webcam sends 720p.

To prevent this, the MJPEG server keeps each `active.mjpg` connection at the format of its first frame.
`jpeg_conform` converts each different frame to that format.
It letterboxes a camera with a different shape, as macOS does.
Fade frames use the chroma format of the camera.

### Fades

`jpeg_darken` and `jpeg_crossfade` decode, blend and encode with WIC. WIC is part of Windows.
Linux does not have this yet. On Linux, a fade is a hard cut.

### Camera identity

The bridge must find the video device of each camera, by its serial number.
On Windows, `Device::videoDevPath()` exists, and returns `std::wstring`.

The two paths do not match as full strings:

- libdev gives the DirectShow interface path, class `{65e8773d-...}`.
- Media Foundation lists the same camera under class `{e5323777-...}`.

The text before `#{` is the device instance. It is the same in the two paths. The bridge compares that part.

A Tiny 2 Lite has no USB serial number, but Windows makes the instance ID from the USB port. Thus 2 identical cameras have different paths, and the match is exact.
On Linux, the match uses the sequence of the cameras.

### Files

The settings and the pairing data are in `%APPDATA%\Open OBSBOT Bridge\`: `auth.json`, `sequence.json`, `sequences.json` and others.

The log is `%LOCALAPPDATA%\Open OBSBOT Bridge\Logs\bridge.log`.
The bridge window keeps the log open for writing. To read it, use a tool that shares the file, for example `Get-Content -Tail`.

### Exit with the bridge window

The C++ bridge stops when the bridge window stops, as on macOS.
The bridge window gives the C++ bridge an anonymous pipe on stdin.
If the bridge window stops for any reason, `ReadFile` on that pipe fails.
The C++ bridge then logs `supervisor gone; exiting so the camera is released`, and exits.
We tested this with a forced stop of `open_obsbot_bridge.exe`.

In a console window, stdin is not a pipe. Thus this check is off when you start the C++ bridge by hand.

### Tray icon

`windows/runner/native_tray.cpp` gives the same `obsbot.bridge/tray` channel as `NativeTray.swift` on macOS.
Thus the Dart tray code is the same on the two platforms.
A left click shows the window. A right click opens the menu.
The icon is white or black, for contrast with the taskbar.

### One copy of the app

A named mutex prevents a second copy of the app.
If you start the app again, the open window comes to the front.

### No H.264 stream

`--h264` is for Linux only. It starts ffmpeg with `fork`, and is not in the Windows build.

### Window style

The bridge window uses `macos_ui`. It works on Windows, but it looks like a Mac app.
A Windows style is planned work.

## Tests

The Node tests in `tests/` find `auth.json` through `tests/paths.mjs`. Thus they run on Windows without change.
They need a token. Pair a phone or the web remote one time before you run them.

Results with 1 camera:

| Test | Result |
| --- | --- |
| `library.mjs` | 4 of 4 pass. |
| `fade.mjs` | The dip check fails on all platforms. The test does a TAKE to the camera that is already on air, so the fade blends a scene into the same scene. |
| `bridge_smoke.mjs`, `exposure.mjs` | Fail on all platforms. They expect the old v1 `state.device` shape. |
| `mix_sequence.mjs`, `two_cam_smoke.mjs` | Need 2 cameras. |
| `obs_e2e.mjs` | Needs OBS with a scene collection named `OBSBOT E2E`. See the next section. |

### OBS test

`obs_e2e.mjs` reads the picture that OBS shows, through obs-websocket.
It checks that OBS shows the camera, that the picture moves when PTZ and zoom move, and that OBS follows a TAKE as a cut and as a crossfade.

The test changes the OBS program scene, and adds and removes sources.
Thus it runs only when the current OBS scene collection is `OBSBOT E2E`. In OBS, click **Scene Collection** > **New**, and name it `OBSBOT E2E`.
Do not run it on an OBS setup that you use for real work.

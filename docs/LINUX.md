# Running the bridge on Linux

The bridge runs headless on Linux. There is no Flutter supervisor, no menubar
and no GUI: `obsbot-bridge` is a plain binary that serves the same WebSocket
control API and MJPEG preview as the macOS app, so the existing remote connects
to it unchanged.

Verified on Arch Linux, kernel 7.1.8, x86_64, against a Tiny 2 Lite.

## Why this works at all

The bridge was always two pieces. `Open OBSBOT Bridge.app` is a macOS Flutter
supervisor that owns a tray icon and a permissions dialog; the bundled
`obsbot-bridge` subprocess does everything else. A server needs the second half
and none of the first.

Of the eleven translation units in `bridge_cpp`, ten were already portable C++
talking to libdev, Crow and Asio. Only the capture layer was Apple-specific.
That file now has a Linux twin, `video_capture_v4l2.cpp`.

The SDK ships a Linux build alongside the macOS and Windows ones. Discovery,
gimbal control, zoom, presets and the rest go through the same `libdev` calls
and behave identically, including the ~5s asynchronous discovery delay.

## Prerequisites

```bash
sudo pacman -S --needed cmake asio base-devel v4l-utils   # Arch
```

Your user must be in the `video` group to open `/dev/video*`. Check with
`id`; this is usually already true on a desktop install. Unlike macOS there is
no permission prompt: the open either succeeds or fails with `EACCES`
immediately.

Place the SDK at `third_party/obsbot-sdk/` as
[Getting the SDK](GETTING_THE_SDK.md) describes, and make sure you copy the
whole archive. The `linux/` directory is the part this build needs, and it is
easy to extract only `macos/` and wonder why CMake stops.

## Build

```bash
cmake -S apps/bridge_cpp -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

`libdev.so` and its SONAME symlinks are copied next to the binary and found
through an `$ORIGIN` runpath, so the build directory is self-contained.

### The web remote

The bridge serves the remote itself, so the built web app has to exist on the
Linux box. Build it from this checkout:

```bash
./scripts/build-web-remote.sh            # build only
./scripts/build-web-remote.sh nitro      # build, then deploy over ssh
```

Do **not** copy `Open OBSBOT Bridge.app/Contents/Resources/web` off a Mac
instead. Those assets are already built and are platform-independent, so the
shortcut looks safe, and it is the one that costs an afternoon.

A remote built from a different revision than its bridge connects fine,
authenticates fine, renders the entire control surface, and then sits on
"Connecting..." for good, with nothing in the browser console. The only thing
that fails is decoding the state event carrying the device list. An empty
device list means no selected camera, which means `previewUri()` has nothing to
build a URL from, which means the preview never even requests the stream. Every
symptom points at video; the cause is the device list.

The tell, if you hit it again: the bridge log shows `ws client connected` but
never `mjpeg: client connected`. The browser is not failing to fetch the
stream. It is not asking for it.

## Run

```bash
./build/obsbot-bridge --port 8765                      # LAN, like macOS
./build/obsbot-bridge --port 8765 --bind 127.0.0.1     # loopback only
```

`--bind` is new. It defaults to `0.0.0.0`, which is what a remote on the same
Wi-Fi needs and what the macOS app has always done. Pass `127.0.0.1` when
something else publishes the ports, so the bridge is not also reachable raw
from the local network. The MJPEG server on `port + 1` follows the same
address.

The pairing PIN is printed at startup and persisted, so it survives restarts:

```
[14:23:34.790 info ] auth: pairing PIN = 463093  (tokens: 0)
```

### Reaching it from anywhere

`tailscale serve` puts both ports behind real HTTPS on your tailnet, which is
why `--bind 127.0.0.1` exists:

```bash
sudo tailscale serve --bg --set-path=/ http://127.0.0.1:8765
sudo tailscale serve --bg --set-path=/preview http://127.0.0.1:8766
```

One thing to size before relying on it: MJPEG is not cheap. A 1080p frame off
this camera is around 340 KB, so 30fps is roughly 80 Mbps. That is nothing over
USB and fine on a LAN, and hopeless over a domestic upload link. Remote viewing
wants a lower resolution or frame rate, or an H.264 transcode.

### Stdin is not decorative

The process exits when stdin reaches EOF. That is how it dies with the macOS
supervisor holding the other end of the pipe, and it applies here too: running
it with `< /dev/null` gives an immediate EOF and the bridge exits at once. Run
it from a terminal, or use the systemd unit below, which handles this.

## As a service

`apps/bridge_cpp/packaging/linux/obsbot-bridge.service` is a `systemctl --user`
unit. It is not installed by the build; copy it, fix the paths, then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now obsbot-bridge
journalctl --user -u obsbot-bridge -f
```

For it to start at boot rather than at first login, the account needs
lingering:

```bash
loginctl enable-linger $USER
```

Without that, systemd tears the user manager down when the last session ends,
and on a headless server that means the bridge never runs at all.

## Watching it from outside the house

The MJPEG preview is the right stream on a LAN and the wrong one over the
internet. Measured on a Tiny 2 Lite: a 1080p frame is about 343 KB, at roughly
30 fps, so `/preview/active.mjpg` runs at about 80 Mbps. MJPEG sends a complete
JPEG every frame with no compression between frames, which is why. The domestic
link this was built against uploads 14.8 Mbps, so the preview is five times
more than the house can send.

`--h264` adds a second stream alongside it. Same picture, H.264, measured at
**2.64 Mbps** at 1080p25 - about a thirtieth of the MJPEG, because H.264
compresses between frames and a mostly-static room compresses very well. The
GPU encodes it, so it costs no CPU worth counting.

```bash
./build/obsbot-bridge --port 8765 --h264
./build/obsbot-bridge --port 8765 --h264 --h264-size 1280x720 --h264-bitrate 1200
```

| Flag | Default | Notes |
| --- | --- | --- |
| `--h264` | off | Nothing runs unless this is passed. |
| `--h264-size` | `1920x1080` | |
| `--h264-fps` | `25` | |
| `--h264-bitrate` | `2500` | kbps. Ceiling is set 30% above. |
| `--h264-encoder` | `h264_nvenc` | `libx264` works and costs real CPU. |
| `--h264-dir` | `$XDG_CACHE_HOME/obsbot-bridge/h264` | Must be writable; see the unit's `ReadWritePaths`. |

Play it at `http://<host>:8765/h264/live.m3u8?t=<token>`, with the same token
the MJPEG endpoint takes. The playlist is rewritten on the way out so each
segment line carries the token too, because a player will not invent one and
ffmpeg cannot append a query to the filenames it writes.

HLS costs 6 to 10 seconds of latency. That is fine for watching a room and
wrong for driving a gimbal, which is why PTZ stays on the WebSocket where the
round trip is milliseconds.

Two deliberate limits. The transcoder follows the on-air camera, re-resolved
every frame, so a TAKE swaps this stream too. And it is **not compiled into the
macOS build at all**: that host runs live services with two cameras and OBS,
and an extra encoder is the last thing it needs.

## What differs from macOS

**Fades are hard cuts.** `jpeg_darken` and `jpeg_crossfade` return their input
unchanged, which is the fallback the header already documents, so a TAKE with a
fade still switches correctly. Implementing them needs a JPEG decode and
re-encode; macOS gets that from Core Image and ImageIO, and the Linux version
wants libjpeg-turbo. Cosmetic, and the only feature gap.

**Multi-camera joins on USB port, not serial.** macOS matches a camera's SN to
its capture device through `Device::videoDevPath()`. The SDK header declares
that method only under `#ifdef _WIN32` and `#elif __APPLE__`, so on Linux
`Device` has no such member; `device_video_path()` finds the node itself. With
one camera that is exact. With several it is positional, because this camera
reports no USB iSerial - every Tiny 2 Lite yields the identical
`/dev/v4l/by-id/usb-Remo_Tech_Co.__Ltd._OBSBOT_Tiny_2_Lite-video-index0`. The
by-path link distinguishes ports, so the join is stable until something is
replugged. A wrong pairing shows up as the wrong preview under the right
controls, and the bridge logs a warning whenever it has to guess.

**Hotplug for generic sources polls.** `observe_av_devices` diffs the device
list every 2s rather than watching udev. OBSBOT attach and detach still come
from libdev's own hotplug thread, so this only affects non-OBSBOT webcams.

**No encoder in the capture path.** This one is in Linux's favour. macOS
captures native frames and runs VideoToolbox to produce JPEGs. The Tiny 2 Lite
emits MJPEG natively over UVC, so V4L2 hands over JPEG bytes that go straight
to the socket, and the capture path is a single memcpy.

**Config lives in the XDG location**, `~/.config/open-obsbot-bridge/auth.json`,
rather than `~/Library/Application Support`.

# Client shell design

Status: design, not built.
Audience: the engineer who builds this next.

This doc describes the "client shell", a macOS app that presents the live camera to OBS as a single virtual webcam.
It is a design and a recommendation, not an implementation spec.
The wire protocol it depends on is already defined in `PROTOCOL.md`; this doc does not restate it.

## Recommendation up front

Ship Path A (OBS Browser Source) first.
It needs zero new code and zero new signing story, and it unblocks the gurdwara today once the bridge serves `/preview/active.mjpg`.
Treat Path B (a CoreMediaIO Camera Extension) as the proper follow-up, and start it only once the project has a paid Apple Developer ID and a notarization pipeline.
Path B is the better product, but it is gated on signing work this project has not done yet, so it must not block the first useful release.

## Purpose

Today a gurdwara AV operator runs two OBSBOT cameras as two separate USB capture sources in OBS, and switches OBS scenes to change which camera is on air.
That means the person deciding the shot has to be at the OBS machine.

The goal is to remove scene switching entirely.
OBS should see one stable capture device whose content is whatever camera is currently marked live.
The person on the phone marks a different camera live with `device.set_active`, and OBS's single capture source silently follows.
The OBS operator never touches the camera selection.

The bridge already does the hard half: it exposes `/preview/active.mjpg`, an MJPEG stream that follows `active_device_id`.
The client shell's only job is to turn that stream into something OBS treats as an ordinary webcam.

## Path A - OBS Browser Source (ship first)

OBS adds a Browser Source pointed at:

```text
http://<mac>:8766/preview/active.mjpg?t=<token>
```

That is the whole setup.
No app to install, no code to write, no system extension, no signing.
It works the moment the bridge serves the endpoint, which it does in v2.0.

What it costs:

- A browser-engine hop. OBS runs the URL through its embedded Chromium, which adds latency and CPU over a native capture device.
- The token sits in plain text inside an OBS scene-collection config file on disk.
- No audio. This is a video-only path.
- OBS's Browser Source can be finicky about `multipart/x-mixed-replace`. Some OBS versions render the first frame and stall, or need the source refreshed after the stream re-points. This needs testing against the OBS build the gurdwara actually runs.

Path A is not elegant, but it is real and it is available now.
For a two-camera gurdwara setup it is very likely good enough.

## Path B - macOS CoreMediaIO Camera Extension (ship properly)

A System Extension that registers a video device named "OBSBOT Bridge".
OBS, and every other app, sees it as an ordinary webcam in the camera dropdown.
No browser hop, no URL, no token in a config file.
This is what the product should be.

What it requires:

- A `.systemextension` bundle embedded inside the app.
- The `com.apple.developer.system-extension.install` entitlement.
- Real code signing. This is the sting: Camera Extensions must be signed by a genuine Apple Developer ID, and they are generally expected to be notarized as well.

That last point is the blocker.
This project currently ships ad-hoc signed and un-notarized.
Distribution is a GitHub Release ZIP or a source build, and the Homebrew cask runs `xattr -dr com.apple.quarantine` in its postflight to let an un-notarized app launch at all.
A CoreMediaIO Camera Extension cannot ride that path.
It forces a paid Apple Developer account (100 USD/year at time of writing) and a notarization step in the build pipeline before it will install on a normal user's Mac.

Spell that out to whoever schedules this work: Path B is not just more code, it is a change to how the whole project is signed and distributed.

There is an older approach, the CoreMediaIO DAL plugin, that predates System Extensions and works on pre-Ventura macOS.
It is a fallback only.
It is deprecated, Apple is progressively tightening what unsigned DAL plugins can do, and newer macOS increasingly blocks them.
Do not build on the DAL plugin unless a specific old-macOS deployment forces it.

### Frame path for Path B

Once the extension is registered, it needs to turn bridge frames into `CMSampleBuffer`s that OBS reads:

```text
GET /preview/active.mjpg  ->  MJPEG multipart stream
  -> decode each JPEG frame
  -> CVPixelBuffer
  -> CMSampleBuffer (with timing)
  -> CMIOExtensionStream.send(...)
```

Two things to get right:

Format negotiation.
OBS asks the extension for a resolution and framerate.
The extension must advertise a format the camera actually produces, and then deliver frames in exactly that format.
Advertise something the source cannot fill and OBS will show a broken or empty device.

Stable advertised format across a live swap.
When the live camera changes, the advertised format must not change.
OBS binds to the format when it opens the device, and if the format changes underneath it, OBS drops the source, which is exactly the scene-cut we are trying to eliminate.
If the two cameras produce different resolutions, the extension must scale each camera's frames to one fixed advertised format before sending.
For two identical Tiny 2 Lite cameras this is a non-issue today, but it is a real constraint the moment a mixed-model setup appears, and it is flagged as an open question below.

## Camera switching

The shell subscribes to the bridge's state events (it is an authenticated WebSocket client).
When `active_device_id` changes, the shell re-points its frame source.

For Path A there is nothing to do: `active.mjpg` already follows the live camera server-side, so the browser source keeps pulling the same URL and the content changes underneath it.
For Path B the shell either follows `active.mjpg` the same way, or it switches which per-camera stream it decodes; either way the switch is triggered by the state event, and the phone is what triggered the state event by sending `device.set_active`.

Latency budget: the swap should complete within one or two frames.
A brief black frame during the swap is acceptable.
A dropped OBS source is not.
That asymmetry is the whole design constraint on the swap: favour continuity of the OBS device over cleanliness of the transition.

## Discovery and auth

The shell needs the bridge's host, port, and a token.

Simplest, and the recommended approach: the shell runs on the same Mac as the bridge.
It hits `localhost:8765` for WebSocket and `localhost:8766` for MJPEG, and it reads the existing token straight out of `auth.json` at:

```text
~/Library/Application Support/Open OBSBOT Bridge/auth.json
```

No pairing UI, no PIN entry, no network discovery.
The shell is a local peer of the bridge and shares its auth state.

The alternative is Bonjour service discovery (`_obsbot-bridge._tcp`) plus the shell doing its own PIN pairing like the phone does.
That would let the shell run on a different Mac from the bridge.
It is not needed for v2.0.
The whole point of the shell is to feed OBS on the same machine the cameras are plugged into, so localhost plus a shared `auth.json` is the right amount of mechanism.

## What the UI is

Almost nothing.
The phone is the control surface; the shell must not become a second one.

The shell UI is:

- A status line, for example "Connected. Live: Tiny 2 Lite (Vocal)".
- A preview of the live feed.
- A start/stop toggle for the virtual camera.
- A link that opens the bridge window.

Resist the urge to add camera controls, a device picker, or preset buttons.
Every one of those already lives on the phone, and duplicating them splits the source of truth and doubles the maintenance.
If an operator wants to change the shot, they use the phone.

## Open questions

These are unresolved and should be answered before Path B is scheduled:

- Notarization cost and timeline. A CoreMediaIO Camera Extension needs a paid Apple Developer ID and a notarization pipeline. Who owns that account, and when does the pipeline land? Path B cannot ship before this is real.
- Mismatched camera resolutions. If two attached cameras produce different resolutions, the extension must scale to one fixed advertised format so a live swap does not change the format OBS bound to. What is the target format, and where does the scaling happen? Not an issue for two identical Tiny 2 Lite cameras, but unspecified for a mixed setup.
- Localhost firewall prompt. Does OBS (Path A) or the shell (Path B) consuming `active.mjpg` on `localhost:8766` trigger a macOS local-network or firewall prompt, and does that prompt survive the ad-hoc-signing situation? Needs testing on a clean machine.
- Distribution of a system extension via Homebrew cask. The project ships through a cask that strips quarantine from an un-notarized app. It is unspecified whether a System Extension can be delivered and approved through that channel at all, or whether Path B forces a signed installer package (`.pkg`) instead of the current ZIP/cask flow.
- Swap mechanism detail. `PROTOCOL.md` describes `active.mjpg` re-pointing on a live change but leaves the exact multipart behaviour (does the same HTTP connection continue, how long is any black-frame window) as a bridge implementation detail. Whichever path is built has to verify the real behaviour against real OBS, not assume it.

# Map: Service Reliability Hardening

`wayfinder:map` - charted 2026-07-24

## Destination

A decided hardening plan for real-service reliability: every open decision behind the failures hit in live use at the gurdwara, resolved into a ready-to-build spec.

The map is done when nothing is left to decide before someone goes and builds. It decides; it does not build.

## Notes

- **Domain:** Open OBSBOT Remote - a C++ bridge on macOS driving OBSBOT cameras over USB, serving a Flutter remote and an MJPEG feed that OBS consumes. Shipped at v2.5.0 and in real use at a gurdwara for multi-hour services.
- **The customer is one operator at one venue.** Reliability for that user beats breadth, features, or reach. Anything justified by hypothetical other users belongs to a different effort.
- **Skills every session should consult:** `superpowers:systematic-debugging` for anything behaving unexpectedly (root cause before fixes, always), `grilling` and `domain-modeling` for decision tickets.
- **Standing constraints:** never push without being asked; run Flutter and Dart tests through the very_good_cli MCP tool, never `flutter test` directly; no em dashes in any file.
- **Tracker:** local markdown for now. Migrates to GitHub issues on request.

## Tickets

The frontier is every open ticket with nothing blocking it. Blocked tickets wait.

| Ticket | Type | Status |
| --- | --- | --- |
| [Gather frame-drop evidence on the mini](tickets/01-mini-frame-drop-evidence.md) | task, HITL | frontier |
| [Decide the frame-drop mitigation](tickets/02-frame-drop-mitigation.md) | grilling, HITL | blocked by ticket 01 |

## Decisions so far

<!-- one line per closed ticket: enough to judge relevance, then open the ticket for detail -->

- [Decide the mix sequence authoring and persistence model](tickets/05-sequence-authoring-model.md) - **Separate what is SAVED, what is RUNNING, and what is being EDITED.** Root cause found in code: `mix_set` clears `mix_loaded_`, so editing detaches from the saved sequence by design and edits reach a live show instantly. Now: Run freezes a snapshot, edits go to a bridge-persisted draft, Save and Apply are separate acts, and navigation is list -> read-only detail -> edit mode with Duplicate replacing Save As.
- [Decide what a cue does when its preset is missing or moved](tickets/04-preset-binding-semantics.md) - **Be strict where it is free, permissive where it is expensive.** Mid-sequence a missing preset holds the current shot and carries on, loudly. At Run it warns clearly but never blocks, because a service starts at a fixed time. `preset.recall` on an empty slot now errors with `empty_preset`, and the solver validates every cue against the camera's real presets and publishes warnings. Slot-versus-pose binding is explicitly deferred: it fixes nothing now broken and costs portability.
- [Trace what happens to a sequence when a preset moves](tickets/03-preset-reference-trace.md) - Nothing is stale: engine, saved library, and UI all follow the live slot, proven on hardware (a re-saved preset landed 0.2 deg from its new pose, 65 deg from the old). The operator's symptom is instead a **silent no-op**: recalling an empty slot returns `ok: true` and moves nothing, and all 4 of their saved sequences depend on a P2 that is empty on the main camera.

## Done outside the map

Root-caused during charting, with nothing left to decide, so fixed inline rather than ticketed:

- **Audio and video out of sync by 1 to 2 seconds in OBS.** The Media Source was buffering 2 MB, which at roughly 60 KB per frame is a second or more of video held back while audio played live. Operator action: set Network Buffering to 0 and add `fflags=nobuffer probesize=32 analyzeduration=0` to the FFmpeg Options.
- **Nagle delaying frames on the wire.** MJPEG client sockets now set `TCP_NODELAY` (commit `7aa653a`). Each frame ships as several small writes that Nagle was holding back to coalesce. Compile-verified only; not yet stream-measured, because the camera is at the venue.
- **Quitting the bridge left the camera held** (commit pending). The helper was orphaned to launchd on every quit path except the tray menu, because `supervisor.stop()` was called from Flutter's `State.dispose()`, which never runs at shutdown. It now watches the pipe it shares with the supervisor and exits when that closes, in about 100ms, covering force quit and crash as well. Cross-reviewed by codex and agy, then researched against XNU source, the Dart VM, and OBS/ffmpeg internals; `tests/lifecycle.mjs` pins both directions. Notably, the fix both reviewers agreed on (passing the supervisor pid explicitly) was the wrong one on macOS - pid reuse makes a named pid unsafe, and it does not close the startup race.
- **The remote needed the internet to load, on a LAN-only product** (commit `d87c4e0`). Reported after a venue outage left the operator unable to control cameras from the bridge machine itself. `flutter build web` defaults `--web-resources-cdn` to on, so the app fetched its 7.2 MB CanvasKit engine from `gstatic.com` on every cold load while an identical copy sat bundled at `web/canvaskit/`. Adding `--no-web-resources-cdn` sets `useLocalCanvasKit`, verified over the wire from localhost. **Every release including v2.5.0 carries this bug, so it needs a rebuild and release to reach the mini.**

## Not yet specified

The fog toward the destination. In scope, not yet sharp enough to ticket.

- **On-air camera dies mid-service.** The operator's own pick for scariest failure. A camera glitches on USB, sleeps, or gets bumped while live: what does OBS show, does the bridge fail over to another camera, does the operator get told which one died, does a re-plug recover on its own? The shape of this depends on what the frame-drop evidence says about USB and host behaviour, so it graduates after [Gather frame-drop evidence on the mini](tickets/01-mini-frame-drop-evidence.md).
- **Control plane dies silently.** The phone backgrounds, the screen locks, Wi-Fi roams, or the WebSocket drops, and the operator keeps tapping a surface that no longer drives anything. Auto-reconnect exists in places; whether it is trustworthy, and whether loss of control is visible, is undecided.
- **Whether anything else still reaches the internet.** The CanvasKit fix removed the one that broke the product outright. A later audit of the shipped bundle found the only other runtime fetch is CanvasKit's `fontFallbackBaseUrl` (`fonts.gstatic.com`), which downloads fallback fonts on demand, so a preset or sequence named in Gurmukhi would not render offline. Every other external URL in the bundle is license text inside vendored libraries and is never requested. Open: whether to self-host the Noto fallbacks, and whether a LAN-only product should assert zero outbound requests as a tested guarantee rather than an audited observation.
- **Whether a phone stays on a Wi-Fi network that has no internet.** Distinct from the app-side fix, and not our code: Android notices an internet-less Wi-Fi and may prompt to switch to mobile data, or disconnect from it. Traffic to a `192.168.x.x` bridge should keep using Wi-Fi because it matches a directly-connected subnet route, but this varies by Android version and vendor and has never been tested on the venue's phones. The native app is inherently safer here than the web app, which is one more reason the installed app matters. Needs a real test with the router's uplink unplugged before it can be called decided.
- **Which deferred review findings actually matter for reliability.** GitHub issue #62 collects findings parked during the v2 release. Some are reliability-relevant (the device re-attach race), some are hygiene (value equality). Needs triage against this destination rather than wholesale adoption.
- **What the two-camera solver verification must prove.** GitHub issue #57 is open as a checklist written before the solver shipped. Whether that checklist is the right one is itself undecided. The preset trace added a case it does not currently cover: a cue landing on a camera whose slot is empty while the other camera's is not, which only appears with 2 cameras attached.
- **Whether the pre-2.1 saved sequences should be migrated.** All 4 of the operator's sequences are the old fully-pinned format, so they run verbatim and never re-derive cameras. They work, but they sit outside everything the 2.1 solver does, and they hard-code serials that will not survive a camera replacement. Migrating them is a decision about whether the old format stays supported indefinitely.

## Out of scope

Beyond this destination. Never graduates; returns only as a separate effort.

- **Richer app features.** The operator flagged that the phone, Mac, and web apps are thin on capability. Real, and explicitly ruled a separate wayfinding effort: it adds surface, while this map makes existing surface trustworthy. The Mobbin MCP is now available to that effort for interface research.
- **Store distribution** (GitHub #71), **Windows and Linux builds** (#75), **bridge and remote convergence** (#76), **the CoreMediaIO virtual camera** (#70). All reach or capability, none reliability.

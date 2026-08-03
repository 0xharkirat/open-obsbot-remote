# The end-to-end mobile browser flow

`wayfinder:spec` - charted 2026-08-02 - status: **open, on the frontier**

The destination in one artifact: what a volunteer moves through, from not having the app open to the service being over, **in a mobile browser tab**.

Grounded in three things, and it says which is which throughout.
The four Mobbin flow-research passes in [`../ui-ux-research/`](../ui-ux-research/).
The code as it stands, read 2026-08-02, so every "today" claim below is verified rather than remembered.
The browser itself, which is the part a native app never has to think about and which turns out to drive most of the decisions here.

## The one thing that makes this different from designing an app

A native app has an icon.
That single fact carries more weight than it looks like it does, because the icon is not decoration, it is **the durable handle on the thing**.
It survives a week of not being used, it survives the phone restarting, and it does not care what IP address the Mac got from DHCP this morning.

A browser tab has no such handle.
The operator's only route back is a URL, and our URL is `http://192.168.1.50:8765`, where that number is assigned by the venue's router and **can differ week to week**.
A bookmark saved in June is a dead link in July.

So the flow below is organised around replacing the icon rather than mourning it, and the replacement is a **stable name** rather than a stable icon.
That reframing is why mDNS moves in this document from a discoverability nicety to a structural requirement.

Everything else the browser does to us is a hazard to be closed off, and those are enumerated in [The browser layer](#the-browser-layer) at the end.

---

## Stage 0 - Getting to the app at all

### What happens today

The bridge window shows a QR, hidden by default behind a Reveal button that re-hides after 60 seconds.
The QR encodes `http://<ip>:8765/#pair?pin=NNNNNN`.

The phone's camera app scans it, the browser opens, `autoDetectHostPort()` in `main.dart:67` reads the host from the served page, the fragment is parsed for the PIN, and `client.connect(hp, autoPin: pin)` runs.
**Connected and paired with zero typing.**
A fragment never leaves the browser, so the PIN never appears in a server log.

This is already the best thing in the product, and nothing below should disturb it.

### What is decided

**The QR is the front door, and everything else is a fallback.**
Not one of several equal options: the front door.
Every other route costs the volunteer either an IP address they do not know or a PIN they have to read across a room.

**The 60-second auto-hide fights the flow and should be reconsidered as a security control.**
It exists to stop a PIN sitting on a screen indefinitely, which is reasonable.
But the volunteer has to unlock their phone, find the camera app, and frame the QR, and a slow phone burns most of a minute doing it.
Options are a longer window, a countdown so the disappearance is not a surprise, or auto-extending while the bridge can see nobody has paired yet.
This is a bridge-window change and the bridge window is out of scope for this map, so it is **handed over rather than decided here**.

**A stable name is required, not optional.**
`obsbot.local:8765` via mDNS is the browser app's substitute for a home screen icon.
It survives DHCP, it works with the venue's internet down, it can be written on a label and stuck to the Mac, and it is the only thing that makes "open it again next week" a one-step action.
Without it, the honest description of the product is that the phone must be re-paired from the QR every time the router reassigns, which is a re-onboarding disguised as a launch.

**The bridge should teach the return journey at the moment of first success, on the Mac's screen.**
The volunteer has just scanned; the Mac knows a phone paired seconds ago.
That is the moment to display "Next time, open `obsbot.local:8765`" where somebody is already looking.
This is the browser-native equivalent of the install prompt we are no longer building, and it costs one line of text.

### Failure branches

| The volunteer sees | Actual cause | What must happen |
| --- | --- | --- |
| No QR on the Mac | Bridge launched hidden, or the reveal timer expired | Out of scope here; handed to the bridge window |
| Browser cannot load the page at all | Phone on mobile data, or on a guest SSID isolated from the LAN | See Stage 1 - this is indistinguishable from a dead bridge unless we make it distinguishable |
| Page loads, then sits | Bridge process gone, camera unplugged | Distinguishable at the protocol level and currently is not distinguished |

---

## Stage 1 - Pairing

### What happens today

`main.dart:166` routes to `PinEntryScreen` when the socket is open but there is no token.
Six digits, autofocused, auto-submitting on the sixth character, with the bridge address shown in monospace above and a friendly inline error below.
Gotcha #41 is respected: the bridge's raw protocol hint never reaches the screen.

The screen is good.
Two things are missing from it, and both are the same kind of miss.

### What is decided

**Name the Reveal click.**
Today the copy reads "Enter the 6-digit PIN displayed in the 'Open OBSBOT Bridge' window on your Mac."
A volunteer who walks to the Mac sees **no PIN**, because it is hidden until somebody clicks Reveal.
The instruction describes a screen state that does not exist yet, which is the most confusing kind of wrong instruction, because it makes the reader doubt they are looking at the right window.
The fix is one clause: on the Mac, click **Reveal**, then type the six digits it shows.

[The pairing research](../ui-ux-research/flows-pairing-first-run.md) found the stronger version of this and it is worth taking whole.
Hue never opens a scanner cold: it shows a picture of the physical thing the code is printed on, then gates on an observable fact rather than a spinner.
Ours would be a small render of the bridge's PIN panel, and the question "Is the Bridge window showing a 6-digit PIN right now?"
**A silent wrong assumption becomes impossible**, which is worth more than the screen real estate it costs.

**Say that nothing leaves the LAN.**
A gurdwara handing a controller to volunteers will be asked where the video goes, and the pair screen is where that question forms.
One sentence: the PIN travels between this phone and the Mac on your Wi-Fi, and nothing is sent to the internet.
It is true, it is reassuring, and it is free.

**Distinguish the failure causes, because the protocol already does.**
A rejected `pair` is not a refused TCP connection, which is not a timeout.
Today all three funnel toward generic copy or, worse, toward the Connect screen.
[Fitbit's model](https://mobbin.com/flows/6283ce10-f407-4690-8526-889549b93aeb) is the one to copy: split one symptom into headed causes, each carrying its own action.
Wrong PIN says so and clears the field.
Cannot reach the bridge names the network the phone is actually on, the way [Shangri-La names the hotel Wi-Fi](https://mobbin.com/flows/3252e7af-942b-4c20-9597-708defe3c95c).

**Manual entry stays permanently available, which it already is.**
Recorded so it does not get optimised away: on mobile web the camera may be unavailable entirely, and a borrowed phone will deny it.
Note `_canScan` is `!kIsWeb && (Android || iOS)`, so **the Scan QR button does not exist in the browser at all**.
That is correct - the phone's own camera app is the scanner here, and the browser is the thing it opens - but it means the browser's Connect screen has exactly two routes, typing and pasting, and both must stay first class.

---

## Stage 2 - Before the service

This stage does not exist in the product today, and the research says it should.

### What is decided

**A rehearsal is a first-class step, in principle.**
[Whatnot tracks "Rehearse going live" as an unlockable checklist item](https://mobbin.com/flows/755fb39e-e5e8-4644-9a8d-cab36f103e9a) and elsewhere makes the no-consequence promise in one sentence: "Practice Swiping. You won't be charged this time."

This matters here more than it does for Whatnot.
A gurdwara rotates sevadars, so somebody is operating for the first time most weeks, and **there is no way to learn what a TAKE feels like except to do one**.
Doing one on air, during diwan, in front of the congregation, is the only practice currently on offer.

The mechanism is not decided here and is genuinely hard, because the bridge does not know whether OBS is streaming.
`active.mjpg` always has a camera on it.
A rehearsal mode would have to be a bridge-side concept where the program output holds a frozen frame or a slate while every control still works, and that is a build decision for the reliability side rather than a layout decision for this map.
**Decided in principle, deferred in mechanism, and explicitly not blocked on.**

**A readiness check is a normal row, not a gate.**
[Craft's "Diagnostics - Check if everything is online"](https://mobbin.com/flows/126208d3-2ecc-443b-943f-f1064b4873b0) is the register: an ordinary settings row, not a ceremony.
What it checks: bridge reachable, every expected camera enumerated, preview actually flowing rather than merely connected, and - browser-only - whether the wakelock actually engaged.

**It must never gate.**
Whatnot puts padlocks on its checklist and we must not, for a reason that is not a preference: **the service starts at its time whether or not the second camera enumerated.**
Any required step between the operator and a working screen is a hazard on a clock.

---

## Stage 3 - Running the service

The 95% state.
Everything above happens once; this is where the operator lives for three hours.

### What happens today

`live_screen.dart` under 900px wide renders a `Column`:
`_TopStrip` (status dot, staged camera name, Sequences, Settings), then an `Expanded` **`SingleChildScrollView`** containing the stage (preview plus on-air PiP), the camera bus, and either the preset grid or the framing panel, then `_actionBar` (Frame toggle, cut/fade toggle, TAKE), then `AppFooter`.

### What is decided

**The operating surface does not scroll. Two planes, one pinned.**

This is the load-bearing decision of the whole stage, and it is worth being precise about why, because there are three independent reasons and any one of them would be sufficient.

The design reason: [Roku's remote](https://mobbin.com/flows/e41d66fd-733f-4025-996b-72b5c43086eb) pins the control plane and slides the context plane underneath, so the control an operator reaches for by memory is always in the same place.

The product reason: today the preview is **inside** the scroll view (`live_screen.dart:104-119`), so scrolling to reach a preset scrolls the picture off the screen.
The operator loses sight of the shot while choosing where to point it.

The browser reason, which is the decisive one: a scroll view sitting at offset zero is what **arms pull-to-refresh**.
A downward drag on the preset area reloads the page, drops the WebSocket, and dumps the operator on the Connect screen, mid-service.
Pinning the preview and the action bar, and letting only the lower plane scroll within its own bounds, closes that structurally rather than by CSS alone.

It also retires gotcha #24 permanently.
The joystick used to eat surrounding scroll gestures; in a two-plane layout there is no surrounding scroll to eat.

**The big preview carries a permanent PREVIEW or ON AIR label.**

Today the small PiP has a red `ON AIR` badge and **the large preview filling most of the screen has no label at all**.
An operator glancing down sees a camera and cannot tell whether they are looking at the shot the congregation sees.
When there is only one camera, or the staged camera is the live one, the PiP is not drawn (`live_screen.dart:147`), so at that moment there is **nothing on screen anywhere saying whether this is live**.

That is the highest-consequence ambiguity in the product, and it is the one thing an operator must never have to reason about.

[Circle carries a grey `BACKSTAGE` versus red `LIVE` badge plus one plain sentence](https://mobbin.com/flows/40cf4d4f-9bed-4194-a453-b07ef2067931).
Ours is green `PREVIEW` and red `ON AIR`, on the frame itself, always, including the single-camera case.
The existing colour convention already says red is on air and green is staged; this makes it legible without a legend.

**The badge doubles as the TAKE confirmation, and on iPhone it is the only one.**
`live_screen.dart:441` fires `HapticFeedback.mediumImpact()` on TAKE.
**iOS Safari does not support the Vibration API at all**, so on an iPhone that call does nothing and the operator gets no confirmation that the most consequential button in the app did anything.
Once the badge exists, the confirmation is the badge moving, which works on every browser.

**TAKE's position is fixed and never shares its row with a mode control.**
[X moves the commit control when the session changes state and never shows two of them at once](https://mobbin.com/flows/cd56d1ad-4054-4ced-84a0-6295520fbe82), on the principle that an operator whose eyes are on the room reaches by memory.
Today TAKE sits in a `Row` with the Frame toggle and, conditionally, a crossfade-length popup that **appears and disappears based on whether crossfade is on** (`live_screen.dart:407`), shifting everything beside it.
A control that moves depending on a setting is a control you cannot reach without looking.

**The Frame toggle is retired.**
It is a binary mode switch that hides the presets to show the manual controls.
In a two-plane layout the lower plane carries its own segmented selector - Presets, Frame, Sequences - which is the same information without a mode the operator has to remember they are in.
This also removes the toggle from TAKE's row, which the previous decision requires anyway.

**Faults appear per camera, never as a takeover.**
Deferred in detail to Stage 4, noted here because it constrains the layout: the Live screen must have somewhere for a persistent fault to live without displacing the preview or TAKE.

---

## Stage 4 - When something breaks

In a native app this is an edge case.
**In a browser tab it is a certainty**, because the browser will freeze or discard a backgrounded tab under memory pressure, and the operator will background it - to answer a call, to check a message, to use the torch.

### What happens today, verified in code

There is **no auto-reconnect anywhere in the client**.
`obsbot_api_client.dart:35` maps `onDone` straight to `_shutdown`.
`WsClient` has no retry timer, no backoff, and no lifecycle observer.

So the socket dies, `_connected` goes false, and `main.dart:162` returns `ConnectScreen`.

Mid-service, the operator's entire screen is replaced by a form titled **"Connect to bridge"** with a hint reading `192.168.0.10:8765` and advice to find the Mac's IP in System Settings.
The preview, the presets, the camera bus and TAKE are all gone.
On web the Scan QR button is not even offered, because `_canScan` excludes `kIsWeb`.

Every device-offline pattern the research surveyed does this same full-screen takeover, and the research's verdict applies exactly: **fine when nothing is live, fatal mid-service**, because it hides the preview and TAKE behind troubleshooting text.

### What is decided

**Reconnect automatically, and say so while it happens.**
The address is known, the token is stored, and on web the host is derivable from the page's own origin.
There is nothing for the operator to supply, so there is nothing to ask them for.

**Degrade in place, never navigate away.**
[Sonos keeps the screen's shape as skeletons and pins a banner reading a statement plus a repair verb](https://mobbin.com/flows/a5202be7-d44d-46b7-a1ba-6e1ebe3bfa5b): "Unable to connect to Sonos. **Let's fix it**".
The Live screen stays on screen.
The controls grey.
A banner states what is wrong and carries the action.

**Faults persist; they never toast.**
[LARQ keeps OFFLINE on the device card and a red banner pinned to the bottom until resolved](https://mobbin.com/screens/6b859147-a151-4dd4-b92e-9e8e5fd0ae81).
Our operator will be mid-seva when a fault fires and will never see a three-second snackbar.

**Attribute per camera.**
[Starlink gives every dependent row its own reason](https://mobbin.com/screens/a79e31e4-17b1-4ae9-a9c7-1bc3239b3f83) rather than one global failure.
C2 losing USB while C1 is live is one card going grey, not a screen.

**State has an age, and stale state is rendered as stale.**
This is the browser-specific one and it has no native equivalent.
When a tab is frozen, the last state event stays on screen looking perfectly current.
The operator taps a preset, nothing moves, and **nothing on screen explains why**, because the UI is faithfully displaying state from four minutes ago.
[LARQ states staleness as elapsed time rather than a boolean](https://mobbin.com/flows/8becc79a-e731-4115-9317-1a0e3ab87144) - "hasn't connected in a while".
Ours: past a threshold, the preview dims and the surface says how old it is.
This also covers gotcha #39, where the MJPEG stream can wedge silently while the socket stays healthy.

**On return from background, prove it rather than assume it.**
The browser gives us `visibilitychange`, and it is the only reliable signal that a frozen tab is awake again.
On resume: assume nothing, re-verify the socket, and show the reconnecting state until a fresh state event arrives.

**The Connect screen keeps its full-screen form, and only its full-screen form.**
It is correct for a cold start, where the operator has nothing and needs to supply something.
It is wrong as an error state for a session that was working ten seconds ago.
Those are two different screens that currently share one widget.

---

## Stage 5 - The end of the session

Almost nothing to design, and that is the correct amount.

**No summary, no stats, no grading.**
The research is unambiguous and the reasoning transfers exactly: the operator's definition of success is that nobody noticed them, and grading seva on viewer counts is meaningless and mildly disrespectful.

**Nothing destructive goes near the end of a session**, which is when the operator is least attentive.

**Ending is closing a tab**, which needs no ceremony.
The only real design work here is that closing the tab is also how the next session starts badly, because a week later the URL is gone.
That loops back to Stage 0, and it is the reason the stable name is a structural requirement rather than a convenience.

---

## The browser layer

Cross-cutting hazards that exist only because this is a tab.
Every "today" here was verified against `apps/rc/web/index.html` and the Dart sources on 2026-08-02.

| # | Hazard | Today | Decision |
| --- | --- | --- | --- |
| B1 | **Pull-to-refresh reloads the app.** A downward drag at scroll offset 0 in Chrome Android reloads the page, dropping the socket mid-shot. | `overscroll-behavior` appears nowhere in the project. The Live screen's scroll view sits at offset 0. | Set `overscroll-behavior: none`. Belt and braces with the two-plane layout, which removes the page-level scroll that arms it. |
| B2 | **The URL bar collapses and expands on scroll**, resizing the viewport and reflowing the preview mid-service. | The middle of the Live screen scrolls, so this fires constantly. | Fixed by the two-plane layout. A surface that does not scroll does not trigger it. |
| B3 | **Chrome tints the address bar with `theme_color`.** | `manifest.json` is the untouched Flutter scaffold: `theme_color` is `#1976D2`, Flutter's blue, over an app whose surface is `#0F1115`. Name is `obsbot_control` and the description is still "A new Flutter project." | Set `theme_color` to the app's surface so the bar reads as part of the app. This is a mobile-browser fix, not PWA work: it is visible in a plain tab. |
| B4 | **iOS Safari ignores `user-scalable=no`.** A stray pinch during a PTZ drag zooms the whole page, and there is no obvious way back. | `user-scalable=no, maximum-scale=1.0` is set and has been ignored by iOS since iOS 10. | Suppress gesture zoom at the elements that receive drags, and accept it elsewhere. Do not rely on the meta tag. |
| B5 | **Swipe-back at the root leaves the app.** iOS Safari's left-edge swipe is browser back. | Settings and Sequences are `Navigator.push`, which Flutter web maps to history entries, so swipe-back works correctly inside the app. At the Live screen it exits to whatever preceded us. | Accept inside the app. The exit-at-root case is mitigated by Stage 0's stable name making return cheap. |
| B6 | **The wakelock can fail silently.** On web `wakelock_plus` needs either the Screen Wake Lock API or a user gesture for its fallback. | `WakelockPlus.enable()` is called unconditionally in `initState` (`live_screen.dart:43`), which on web is **before any user gesture has occurred**. | Verify it engaged; re-arm on first interaction; surface failure in the readiness check rather than discovering it when the screen locks during Anand Sahib. |
| B7 | **No haptics on iOS Safari.** | `HapticFeedback.mediumImpact()` on TAKE. | Covered by Stage 3: the ON AIR badge is the confirmation. Keep the haptic for Android, where it works. |
| B8 | **Orientation cannot be locked.** | `SystemChrome.setPreferredOrientations` is called in `main.dart:24` and **does nothing on web**. | The phone will rotate. Landscape on a phone is short and wide, which is a distinct layout, not a stretched portrait one. Needs a deliberate pass rather than an assumption. |
| B9 | **Backgrounded tabs freeze or get discarded.** | No lifecycle handling of any kind. | Covered by Stage 4: `visibilitychange` drives re-verification. |
| B10 | **Long-press may raise the browser's own callout.** Presets are tap-to-recall, long-press-to-save. | Not verified on device. | Test on iOS Safari before this is called decided. `user-select: none` and a `touchstart` preventDefault at the tiles is the usual remedy. |

B1 and B3 are one-line changes that fix live defects and depend on nothing else in this document.

---

## What this leaves open

**Ticket 02, the Live screen layout**, now has its structure decided (two planes, pinned preview and action bar, segmented lower plane, permanent PREVIEW/ON AIR badge) but not its composition: what exactly is in the pinned plane at what size, and how the lower plane's segments are ordered.

**Ticket 03, health visibility**, has its rules decided here (persist, attribute per camera, age the state, never take over) but not its vocabulary: what the operator is actually shown, in what words, at what threshold.

**Ticket 04, pairing and first run**, is largely answered by Stage 1 and should be re-read against it rather than run cold.

**Landscape** (B8) and **long-press behaviour** (B10) are unresolved and need a device.

**The rehearsal mechanism** is deferred to the reliability side, since it is a bridge behaviour rather than a phone layout.

**mDNS** is now a dependency of this map's Stage 0 rather than a nice-to-have, and it lives outside this map because it is bridge work.
That handover should be explicit rather than assumed.

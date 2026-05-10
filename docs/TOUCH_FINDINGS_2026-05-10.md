# Mobile touch findings — 2026-05-10

Reproduced via Playwright Chromium with CDP touch emulation
(`Emulation.setTouchEmulationEnabled` + mobile UA + 1× device-scale).
All tests dispatched real `PointerEvent` with `pointerType: 'touch'`,
`isPrimary: true`. WS hook on `WebSocket.prototype.send` records
every command emitted by the Flutter web client.

## Viewports tested

| Device profile | Viewport | UA | Body height | Overflow |
|---|---|---|---|---|
| iPhone 14 Pro (portrait) | 390 × 844 | iOS Safari | 850 | +6 |
| Pixel 6 (portrait) | 360 × 800 | Android Chrome | 856 | +56 |
| iPad (portrait) | 768 × 1024 | mobile Safari | 1080 | +56 |

## Results

### Joystick (PtzPad)

| Drag direction | iPhone 390×844 | Pixel 360×800 | iPad 768×1024 |
|---|---|---|---|
| Pure horizontal (right) | 16 velocity ✅ | 10 velocity ✅ | (not tested, expected ✅) |
| Pure vertical (down) | (not tested) | **0 velocity** ❌ | **0 velocity** ❌ |
| Diagonal (right + down) | 17 velocity ✅ | (not tested) | (not tested) |

**Diagnosis:** at any viewport where total content height > viewport
(56px overflow on Pixel + iPad), Flutter's `SingleChildScrollView`
ancestor wins the gesture arena over `PtzPad`'s `GestureDetector` for
*vertical-first* drags. The browser hands the touch to the scrollable
parent. The joystick's `onPanStart` is never called; only
`onPanCancel → _end()` fires, sending a lone `ptz.stop`.

This matches the user's livestream feedback exactly:
- "Joystick doesn't get the input."
- "When I try to use the joystick it starts scrolling."

### Zoom slider

Material `Slider` recognizer claims the pointer at `pointerdown` (eager
arena win). Vertical drag works on all sizes. **Not affected.**

### Directional hold-buttons

`_HoldDirBtn` uses `Listener.onPointerDown/Up`. Tapping (no drag) on
iPhone 390×844 fired 8 ptz.velocity ticks at 80ms cadence + 1 stop —
clean. The user's "sometimes work, sometimes don't" report is most
likely not the button itself but the user inadvertently dragging
slightly during a hold (gesture arena re-evaluation), or scroll-conflict
when content overflows. Re-test on real Android once P0-2 lands.

### PTZ sign convention (confirmed inverted)

- Joystick drag DOWN sent `pitch_speed: -17`. User reports camera
  tilted UP. → positive pitch_speed = camera tilts DOWN, negative =
  UP. **App-side mapping is inverted.**
- Earlier smoke test: `yaw_speed: +60` moved snap_.ptz.yaw negative.
  → positive yaw_speed = camera rotates LEFT (in viewer frame), negative
  = RIGHT. **App-side mapping is inverted on yaw too.**

Phone and hold-buttons emit positive yaw for "right" intent — confirmed
backwards. Fix in **bridge** so all current and future clients get
consistent semantics:

```cpp
// In cmd_ptz_velocity, before passing to SDK:
const float yaw_camera   = -yaw_speed;    // user-frame → camera-frame
const float pitch_camera = -pitch_speed;
int32_t r = dev_->aiSetGimbalSpeedCtrlR(pitch_camera, yaw_camera, roll_speed);
```

Document positive convention in `docs/PROTOCOL.md`:
- positive yaw_speed → camera pans **right** in viewer frame
- positive pitch_speed → camera tilts **up**
- positive roll_speed → camera rolls clockwise from operator POV

Smoke test must assert direction not |delta|.

## Fix priorities

### P0-2 fix (concrete)

Restructure `_buildPortrait` so preview + joystick + zoom slider are
NEVER inside a scrollable. Two options:

**Option A — Fixed top, scrollable bottom (preferred):**

```dart
return Column(
  children: <Widget>[
    _statusBar(s),                                    // 56-80px
    Padding(child: PreviewWidget()),                  // ~206px
    SizedBox(                                         // 280px FIXED
      height: 280,
      child: Row(children: [PtzPad, ZoomSlider]),
    ),
    Expanded(                                         // remaining: scrolls
      child: SingleChildScrollView(
        child: _bottomBarOnly(s),                     // action rows
      ),
    ),
  ],
);
```

**Option B — Wrap PtzPad in `Listener`:**

`Listener` doesn't enter the gesture arena. It receives raw pointer
events before any `GestureDetector`. PtzPad would need a small refactor
to use `onPointerDown/Move/Up/Cancel`.

Recommend Option A for production — matches mobile UX expectation
(hero controls always visible, only preset rows scroll).

### P0-1 fix (concrete)

Single-line negate in `cmd_ptz_velocity`. Update smoke test predicate
to assert direction. Bump protocol version note.

## Reproduction recipe (for future regression)

```bash
# Bridge running on :8765
node tests/bridge_smoke_touch.mjs   # to be added in P2-4
```

Or interactively via Playwright MCP at any viewport:
1. CDP `Emulation.setDeviceMetricsOverride` with `mobile: true`.
2. CDP `Emulation.setTouchEmulationEnabled` enabled.
3. Hook `WebSocket.prototype.send`.
4. Dispatch `PointerEvent('pointerdown'/'pointermove'/'pointerup')`
   with `pointerType:'touch'`, `pointerId`, `isPrimary:true` on
   `flt-glass-pane`.
5. Assert message count + content.

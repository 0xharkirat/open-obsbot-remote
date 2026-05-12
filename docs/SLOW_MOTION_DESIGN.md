# Slow-motion floor - design

> **Status: shipped, with a wire-format change.** This was the original
> design for an `ultra` / `cinema` slow-motion tier driven by a
> `MoveSpeed` enum. What shipped (in PR #2 / v1.1) replaces the enum
> with an explicit `duration_ms` integer everywhere a move duration
> matters: `ptz.angle`, `zoom.set`, `preset.recall`, sequence steps.
> The MotionPlanner architecture described below (worker thread,
> waypoint interpolation, ease-in-out-sine, adaptive tick,
> cancel-replace) all landed as-is.
>
> Two more deltas landed during v1.2:
>
> 1. **Zoom uses the float-API.** This design called for
>    `cameraSetZoomWithSpeedAbsoluteR(zoom_pct, zoom_speed)`. Empirical
>    probing on Tiny 2 Lite showed that the uint-API gets stuck around
>    1.33x regardless of speed, and the speed param is SDK-tagged
>    "tail2 / tail2s only" so on Tiny 2 Lite it is ignored anyway. The
>    bridge now uses `cameraSetZoomAbsoluteR(value, -1)` which takes a
>    float in [1.0, 2.0] and produces smooth continuous motion (1.0x to
>    2.0x in about 3 seconds at default speed). See gotcha #26 in
>    `CLAUDE.md`.
> 2. **No adaptive tick on the zoom axis.** The original design
>    stretched the tick when per-tick delta dropped below 0.1 deg
>    equivalent. The float-API accepts sub-percent waypoints, so the
>    zoom path keeps the fine 100 ms cadence at any duration. The
>    adaptive stretch still applies to the gimbal axes.
>
> The rest of this doc is preserved as a design log so future work can
> revisit the rationale.

Goal: every camera operation (pan, tilt, zoom, preset recall, sequencer
step) honors a single move-duration, and the slowest tier delivers true
cinematographer-grade slow movement (much slower than the SDK's own
minimum).

## What "ultra slow" means in practice

| Tier | Goal duration for 90° pan | Goal duration for 1.0×→2.0× zoom |
|---|---|---|
| Instant | <0.5 s | <0.5 s |
| Fast | ~1 s | ~0.6 s |
| Medium | ~2 s | ~1 s |
| Slow | ~5 s | ~3 s |
| Cinema | ~22 s | ~6 s |
| **Ultra** | **2-5 min (configurable)** | **15-30 s** |

Ultra is meant to be visually almost-imperceptible motion — useful for
weddings, religious ceremonies, theatre.

## Why we can't just lower the SDK speed parameter

Two SDK functions matter for absolute moves:

```cpp
// position-with-speed: motor goes to (roll,pitch,yaw) at given rate
gimbalSetSpeedPositionR(roll, pitch, yaw, s_roll, s_pitch, s_yaw);
//   valid range: -90..90 (deg/s) per axis (SDK header)

// zoom with discrete speed enum
cameraSetZoomWithSpeedAbsoluteR(zoom_ratio_pct, zoom_speed);
//   zoom_speed: 0=default, 1=slowest, 10=fastest, 255=max
```

`s_yaw=1` is the SDK's floor. Any value below 1 is undefined behaviour
(empirical: motor jitters or ignores). `zoom_speed=1` likewise — there's
no `0.5` enum member.

To go slower than the SDK floor, we must **synthesise** the slow motion
in the bridge: break the move into tiny waypoints and meter them out
over time. We're using the firmware's *fastest* motion across each tiny
gap, but the gap is small enough that the perceived motion is whatever
rate we want.

## Architecture: the interpolator

A new bridge component in `apps/bridge_cpp/src/`:

### `motion_planner.h` / `.cpp`

Single class `MotionPlanner` per `DeviceSession`. Owns one worker
thread that drives at-most-one *active move* at a time. New moves
cancel the in-flight one.

```cpp
struct MotionTarget {
    // All fields optional — set only the axes you want to move.
    std::optional<float> yaw_deg;
    std::optional<float> pitch_deg;
    std::optional<float> roll_deg;
    std::optional<float> zoom_ratio;          // 1.0..2.0 etc

    // Total wall-clock duration to reach the target.
    int duration_ms;                          // 0 = instant (no interp)

    // Tick cadence for waypoints. 100ms is smooth enough for 30fps
    // preview without overloading the SDK queue.
    int tick_ms = 100;

    // Optional ID for telemetry / cancellation.
    std::string tag;
};

class MotionPlanner {
public:
    explicit MotionPlanner(Device* dev);
    ~MotionPlanner();

    // Cancels any in-flight move and starts a new one. Non-blocking.
    void start(MotionTarget t);

    // Cancel any in-flight move. Camera stays where it is.
    void cancel();

    // True if a move is currently being driven.
    bool busy() const;

    // Snapshot of the planner's current target — useful for debug + UI.
    MotionTarget active_target() const;
};
```

### Tick algorithm (per move)

```
read  start_yaw, start_pitch, start_roll, start_zoom from snapshot
tick_count = duration_ms / tick_ms
for i in 1..tick_count:
    if cancelled: break
    progress = i / tick_count                  // 0..1
    eased    = ease(progress)                  // ease-in-out for cinema feel

    if target.yaw set:
        intermediate_yaw = lerp(start_yaw, target.yaw, eased)
    similar for pitch, roll, zoom

    // Issue waypoint at SDK floor speed. Each waypoint is at most
    // 0.5 deg from previous (small enough that motor reaches before
    // next tick fires).
    if any of yaw/pitch/roll changed:
        gimbalSetSpeedPositionR(intermediate_roll, intermediate_pitch,
                                intermediate_yaw, 90, 90, 90)
        // ↑ pass max-speed so motor reaches each waypoint quickly;
        //   we're in control of the *target* update rate, not the
        //   per-segment motion rate.

    if zoom changed:
        cameraSetZoomWithSpeedAbsoluteR(intermediate_zoom_pct, 10)

    update snap_.yaw/pitch/zoom inline (so state events show
    intermediate value, not start)
    sleep tick_ms
```

Easing function: `ease_in_out_sine(t) = 0.5 * (1 - cos(pi * t))`. Looks
deliberately decelerating into the target — cinematographer-style.
Linear (`progress` raw) is fine too, configurable.

### Why this works smoother than "lower the SDK parameter"

- SDK's own slow rate `s_yaw=1` produces visible motor stepping for
  long moves (the camera's quartz timer drives in 50ms increments).
- Our planner lets us fire more frequent, smaller waypoints — at
  100ms cadence with 0.3°/tick steps for a 90° / 5min move, the motor
  visibly draws a smooth arc instead of stepping.
- Cancel semantics are clean: stop the worker thread, leave the
  camera at whatever waypoint it last reached. No "queued at SDK
  level" weirdness.

### Why we don't use velocity mode (`aiSetGimbalSpeedCtrlR`)

Velocity mode requires the bridge to *poll* the current attitude every
tick and stop when within tolerance. That's an extra round-trip per
tick and the camera's reported attitude lags by ~50ms anyway. Using
position waypoints with speed-floor 90 is one-way and fits the SDK's
"give me a target" model better. We measured: same quality of motion,
half the jitter.

## Mapping to MoveSpeed tiers

```cpp
// Total duration the planner targets for a move scaled by the angular
// distance. 90° pan reference; shorter pans take proportionally less.
int duration_ms_for(MoveSpeed s, float yaw_delta, float pitch_delta,
                    float roll_delta, float zoom_delta) {
    const float dist = std::max({
        std::abs(yaw_delta),
        std::abs(pitch_delta) * 1.5f,           // pitch axis is shorter
        std::abs(zoom_delta) * 90.0f,           // 1× zoom equiv to 90° pan
    });
    if (dist < 0.1f) return 0;                  // nothing meaningful

    // ms per degree of equivalent distance:
    float ms_per_deg = 0;
    switch (s) {
        case MoveSpeed::instant:  return 0;
        case MoveSpeed::fast:     ms_per_deg = 11;  break;   // 90° in ~1s
        case MoveSpeed::medium:   ms_per_deg = 22;  break;   // ~2s
        case MoveSpeed::slow:     ms_per_deg = 55;  break;   // ~5s
        case MoveSpeed::cinema:   ms_per_deg = 250; break;   // ~22s
        case MoveSpeed::ultra:    ms_per_deg = 3300; break;  // ~5min
    }
    return (int)(ms_per_deg * dist);
}
```

`ultra` ms_per_deg is empirically tuned. User can fine-tune later via
a "speed bias" multiplier.

## Wiring per command

### `cmd_preset_recall(id, speed)`

Old path (instant): `aiTrgGimbalPresetR(id)` — fastest hardware recall.
Old path (slow/medium/fast/cinema): `gimbalSetSpeedPositionR` with
mapped `s_yaw` etc, plus `cameraSetZoomWithSpeedAbsoluteR` paced via
`zoom_speed_for_duration()`.

New path:

```cpp
if (speed == MoveSpeed::instant) {
    aiTrgGimbalPresetR(id);  // hardware path stays
    cameraSetZoomWithSpeedAbsoluteR(p.zoom * 100, 10);  // also instant zoom
    snap_.zoom = p.zoom;  pending_zoom_ = p.zoom;
} else {
    // Compute total duration based on the LARGEST axis delta.
    const int ms = duration_ms_for(speed,
        p.yaw - cur_yaw, p.pitch - cur_pitch,
        p.roll - cur_roll, p.zoom - cur_zoom);

    MotionTarget t;
    t.yaw_deg     = p.yaw;
    t.pitch_deg   = p.pitch;
    t.roll_deg    = p.roll;
    t.zoom_ratio  = p.zoom;
    t.duration_ms = ms;
    t.tag         = "preset.recall id=" + std::to_string(id);
    motion_planner_->start(std::move(t));
}
```

Both axes finish at the same tick because the planner drives them
together — no zoom-snap-while-pan-slow.

### `cmd_zoom_set(value, terminal)` at ultra speed

If the global session move-speed (set via `setMoveSpeed`) is `ultra` or
`cinema`, route the zoom through the planner:

```cpp
if (session_speed_ == MoveSpeed::ultra ||
    session_speed_ == MoveSpeed::cinema) {
    MotionTarget t;
    t.zoom_ratio = v;
    t.duration_ms = duration_ms_for(session_speed_, 0, 0, 0, v - prev_v);
    t.tag = "zoom.set ultra";
    motion_planner_->start(std::move(t));
    snap_.zoom = v;  pending_zoom_ = v;
    return ok();
}
// else: existing one-shot SDK path
```

A new `cmd_zoom_set` while a planner zoom is in-flight: cancel the
previous, start a fresh interpolation from current observed zoom to
the new target. Mid-drag feels smooth; release just keeps the last
target.

### `cmd_ptz_velocity` (joystick / hold buttons)

Velocity mode is *already* arbitrary-rate via `aiSetGimbalSpeedCtrlR`.
At ultra speed, just clamp `yaw_speed`/`pitch_speed` to a much smaller
range:

```cpp
if (session_speed_ == MoveSpeed::ultra) {
    yaw_speed   = std::clamp(yaw_speed   * 0.05f, -2.0f, 2.0f);   // 5%
    pitch_speed = std::clamp(pitch_speed * 0.05f, -2.0f, 2.0f);
} else if (session_speed_ == MoveSpeed::cinema) {
    yaw_speed   *= 0.30f;
    pitch_speed *= 0.30f;
}
```

Phone joystick that previously pushed 60 deg/s now pushes 3 deg/s at
ultra — visible-but-slow.

### `cmd_ptz_angle(yaw, pitch, roll)`

Absolute angle move. Honors session_speed_ same way preset recall does:
ultra/cinema/slow → planner; instant → direct SDK call.

### Sequencer step trigger

Each `SequenceStep` already carries its own `MoveSpeed`. The trigger
fires `cmd_preset_recall(step.preset_id, step.speed)` — already routed
through the planner above. No sequencer-side change needed.

## Cancellation matrix

| Triggering event | Effect on in-flight planner move |
|---|---|
| New preset recall | Cancel + start new |
| New zoom.set | Cancel + start new (at ultra) |
| ptz.velocity (any speed) | Cancel + switch to velocity mode |
| ptz.recenter | Cancel + start hardware reset |
| ptz.stop | Cancel; gimbal stays put |
| Sequencer step boundary | Cancel previous step's move + start next |
| Device disconnect | Cancel; planner thread idles |

Cancel is non-blocking. Planner sets `cancel_=true`, the worker thread
checks at the top of each tick.

## Ultra tier: gimbal sub-degree-per-second behaviour

Empirical concern: at `duration_ms=300_000` for a 90° pan, the planner
fires 3000 waypoints at 100ms cadence with 0.03° step each. The motor
might struggle to settle on such tiny moves. Mitigation:

- **Adaptive tick.** If `delta_per_tick < 0.1°`, increase tick cadence
  to keep step ≥0.1° (e.g. 300ms tick for 0.03° steps becomes 600ms
  tick with 0.06° steps; smoother).
- Test empirically; if motor jitters, fall back to `s_yaw=1` direct
  call for moves where `total_duration < (90°) / (1°/s) = 90s`. Above
  90s, planner kicks in.

## Smoke battery additions

`tests/slow_motion.mjs`:

```
test('preset.recall ultra: 90° pan takes >2 minutes')
test('preset.recall cinema: 90° pan takes 15-30s')
test('zoom.set ultra 1.0→2.0 takes >12s')
test('ptz.velocity ultra clamps yaw_speed to <=2 deg/s')
test('cancel mid-flight: new recall preempts old in <300ms')
test('sequencer step at ultra: gimbal + zoom finish together')
```

All measured against real Tiny 2 Lite by recording state events and
timestamping the moment `pending_zoom_` clears or `Math.abs(s.ptz.yaw -
target) < 0.5`.

## Risk register

- **Worker thread leaks** if cancel doesn't deterministically join the
  thread. Use `std::jthread` (C++20) or explicit join in
  `MotionPlanner::cancel()`. Tested with thread-sanitizer once.
- **Planner outliving DeviceSession** if the lambda captures `dev_`
  raw. Use `std::weak_ptr`. Cancel on `~MotionPlanner`.
- **State events flooding** at 100ms cadence × 5min = 3000 events.
  Throttle: don't broadcast state more than 5/s (already ~5/s anyway
  via the camera-status poll loop). Planner updates snap_ but doesn't
  trigger broadcasts directly.
- **Cinema/ultra mid-drag zoom loops** if user drags rapidly. Cancel +
  restart is correct; just verify thread churn is acceptable. Worst
  case: drag 60 times/second → 60 thread-restarts/s. Use a single
  worker thread with a swap-target signal instead of restart.

## Implementation order

PR-wise but in a single branch:
1. Add `MotionPlanner` class with thread + cancellation.
2. Add `duration_ms_for()` helper.
3. Wire `cmd_preset_recall` (most impactful).
4. Wire `cmd_zoom_set` (ultra/cinema only).
5. Wire `cmd_ptz_angle`.
6. Wire `cmd_ptz_velocity` (clamp).
7. Add `MoveSpeed::ultra` to enum + protocol + Flutter client.
8. Add ultra to control_screen + simple_mode_screen menus.
9. Smoke tests `tests/slow_motion.mjs`.
10. Manual real-camera verification at ultra: a 90° pan looks visibly
    cinematographic (no stepping, smooth deceleration into target).

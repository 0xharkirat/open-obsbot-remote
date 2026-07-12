/// PTZ precision model - every tunable in one place (v3 P1).
///
/// The v2 model mapped joystick deflection linearly to 120 deg/s (half
/// stick was already 60 deg/s) and the hold-pad fired a fixed high
/// speed from the first millisecond - both overshoot instantly. The
/// v3 model, from the design exploration:
///
///   tap  (< 250 ms)  -> one NUDGE: absolute-position step. A position
///                       command cannot overshoot; this is the primary
///                       precision verb.
///   hold (>= 250 ms) -> GLIDE: velocity ramps from a slow floor up to
///                       the selected ceiling, so short holds stay slow.
///   joystick         -> squared response curve into the same ceiling;
///                       half deflection = quarter speed.
///
/// Numbers here are first-pass; tune against real cameras.
library;

/// Manual-PTZ speed preset. Applies to nudge step, glide ceiling, and
/// joystick ceiling. Distinct from preset-recall move DURATIONS, which
/// remain their own concept.
enum PtzSpeed { fine, normal, fast }

PtzSpeed ptzSpeedFromWire(String s) => switch (s) {
  'fine' => PtzSpeed.fine,
  'fast' => PtzSpeed.fast,
  _ => PtzSpeed.normal,
};

String ptzSpeedToWire(PtzSpeed s) => switch (s) {
  PtzSpeed.fine => 'fine',
  PtzSpeed.normal => 'normal',
  PtzSpeed.fast => 'fast',
};

/// One tap = one step of this many degrees, applied as an absolute
/// position command over [kNudgeMoveDuration].
double nudgeStepDeg(PtzSpeed s) => switch (s) {
  PtzSpeed.fine => 0.2,
  PtzSpeed.normal => 0.5,
  PtzSpeed.fast => 1.5,
};

/// Velocity ceiling in deg/s for hold-glide and full joystick deflection.
double ceilingDegPerSec(PtzSpeed s) => switch (s) {
  PtzSpeed.fine => 4,
  PtzSpeed.normal => 15,
  PtzSpeed.fast => 45,
};

/// A press shorter than this is a tap (nudge); longer is a hold (glide).
const kTapHoldThreshold = Duration(milliseconds: 250);

/// How often a held control refreshes its velocity. Must stay well
/// under the bridge's 400 ms velocity watchdog.
const kVelocityRefresh = Duration(milliseconds: 100);

/// Release sends stop immediately and again after this delay - two
/// independent packets so a single loss cannot leave the gimbal
/// running (the bridge watchdog is the final backstop).
const kDoubleStopDelay = Duration(milliseconds: 120);

/// Glide ramp: start at [kRampFloorDegPerSec], reach the ceiling after
/// [kRampDuration] of continuous hold.
const kRampFloorDegPerSec = 2.0;
const kRampDuration = Duration(milliseconds: 1200);

/// The nudge's absolute move plays over this duration - long enough to
/// look damped, short enough to feel immediate.
const kNudgeMoveDuration = Duration(milliseconds: 200);

/// Velocity for a hold that has lasted [held]. Linear ramp from the
/// floor to [ceiling]; never above the ceiling, never below the floor
/// (a ceiling below the floor - not a real preset - would clamp down).
double rampVelocity(Duration held, double ceiling) {
  if (ceiling <= kRampFloorDegPerSec) return ceiling;
  final t = held.inMilliseconds / kRampDuration.inMilliseconds;
  if (t >= 1) return ceiling;
  return kRampFloorDegPerSec + (ceiling - kRampFloorDegPerSec) * t;
}

/// Signed per-axis joystick speed: squared curve into the ceiling.
/// deflection is -1..1; half stick = quarter speed.
double joystickAxisSpeed(double deflection, double ceiling) {
  final d = deflection.clamp(-1.0, 1.0);
  return d.sign * d * d * ceiling;
}

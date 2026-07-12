/// How a sequence loops once it finishes its last step.
enum LoopMode {
  /// Play once then stop on the last step.
  once,

  /// Restart at step 1 (P1 -> P2 -> P3 -> P1 -> P2 -> P3 ...).
  forward,

  /// Reverse direction at each end (P1 -> P2 -> P3 -> P2 -> P1 ...).
  /// Useful when P3 -> P1 is a long ugly transition you want to
  /// skip on the loop.
  pingPong,
}

String loopModeToWire(LoopMode m) => switch (m) {
      LoopMode.once => 'once',
      LoopMode.forward => 'forward',
      LoopMode.pingPong => 'ping_pong',
    };

LoopMode loopModeFromWire(String s) => switch (s) {
      'once' => LoopMode.once,
      'ping_pong' => LoopMode.pingPong,
      _ => LoopMode.forward,
    };

// v3 P1: the PTZ precision model.
//
// The tuning functions are pure - test the curve math directly. The
// gesture contract (tap = one nudge, hold = ramped glide, release =
// double stop) is tested through HoldDirBtn with a recording client,
// because that split IS the fix for "one press moves too far".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/control_screen.dart';
import 'package:obsbot_control/ptz_tuning.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingClient extends WsClient {
  final nudges = <({double yawSign, double pitchSign})>[];
  final velocities = <({double yawSpeed, double pitchSpeed})>[];
  int stops = 0;

  @override
  void ptzNudge({double yawSign = 0, double pitchSign = 0}) {
    nudges.add((yawSign: yawSign, pitchSign: pitchSign));
  }

  @override
  void ptzVelocity({double yawSpeed = 0, double pitchSpeed = 0}) {
    velocities.add((yawSpeed: yawSpeed, pitchSpeed: pitchSpeed));
  }

  @override
  void ptzStop() => stops++;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('tuning math', () {
    test('nudge steps grow with the preset', () {
      expect(nudgeStepDeg(PtzSpeed.fine), 0.2);
      expect(nudgeStepDeg(PtzSpeed.normal), 0.5);
      expect(nudgeStepDeg(PtzSpeed.fast), 1.5);
    });

    test('ramp starts at the floor and reaches the ceiling', () {
      const ceiling = 15.0;
      expect(rampVelocity(Duration.zero, ceiling), kRampFloorDegPerSec);
      expect(rampVelocity(kRampDuration, ceiling), ceiling);
      expect(rampVelocity(const Duration(seconds: 9), ceiling), ceiling);
      // Midpoint sits between floor and ceiling.
      final mid = rampVelocity(
        Duration(milliseconds: kRampDuration.inMilliseconds ~/ 2),
        ceiling,
      );
      expect(mid, greaterThan(kRampFloorDegPerSec));
      expect(mid, lessThan(ceiling));
    });

    test('joystick curve: half deflection = quarter speed, sign kept', () {
      expect(joystickAxisSpeed(1.0, 40), 40);
      expect(joystickAxisSpeed(0.5, 40), closeTo(10, 0.001));
      expect(joystickAxisSpeed(-0.5, 40), closeTo(-10, 0.001));
      expect(joystickAxisSpeed(0, 40), 0);
      // Out-of-range deflection clamps rather than overshooting.
      expect(joystickAxisSpeed(2.0, 40), 40);
    });
  });

  group('HoldDirBtn gesture contract', () {
    Future<_RecordingClient> pumpBtn(WidgetTester tester) async {
      final client = _RecordingClient();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 100,
              height: 100,
              child: HoldDirBtn(
                icon: Icons.east,
                label: 'Right',
                client: client,
                yawSpeed: 1,
                pitchSpeed: 0,
              ),
            ),
          ),
        ),
      );
      return client;
    }

    testWidgets('tap (under the threshold) = exactly one nudge, no motors', (
      tester,
    ) async {
      final client = await pumpBtn(tester);
      final g = await tester.startGesture(
        tester.getCenter(find.byType(HoldDirBtn)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await g.up();
      await tester.pump(kDoubleStopDelay + const Duration(milliseconds: 50));

      expect(client.nudges, hasLength(1));
      expect(client.nudges.single.yawSign, 1);
      expect(client.velocities, isEmpty);
      expect(client.stops, 0);
    });

    testWidgets('hold = ramped velocities then double stop on release', (
      tester,
    ) async {
      final client = await pumpBtn(tester);
      final g = await tester.startGesture(
        tester.getCenter(find.byType(HoldDirBtn)),
      );
      // Cross the threshold and glide for a while.
      await tester.pump(const Duration(milliseconds: 900));
      final duringHold = client.velocities.length;
      expect(duringHold, greaterThan(2)); // refreshing under the watchdog
      // Ramp: a later tick is faster than the first.
      expect(
        client.velocities.last.yawSpeed,
        greaterThan(client.velocities.first.yawSpeed),
      );
      // Never above the Normal ceiling.
      for (final v in client.velocities) {
        expect(
          v.yawSpeed,
          lessThanOrEqualTo(ceilingDegPerSec(PtzSpeed.normal)),
        );
      }
      await g.up();
      await tester.pump(kDoubleStopDelay + const Duration(milliseconds: 50));

      expect(client.nudges, isEmpty);
      expect(client.stops, 2); // immediate + delayed
    });
  });
}

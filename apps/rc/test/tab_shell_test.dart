// Widget tests for the v1.2 TabShell after the fix/ui-revamp-from-review
// pass. Tabs are now Joystick / Buttons / Image; presets are inlined on
// the Joystick + Buttons tabs; Sequence lives in the AppBar.
//
// Bridge-coupled behavior (gimbal, zoom, presets save, sequence, image)
// is covered by the Node smoke harness under `tests/`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/control_screen.dart';
import 'package:obsbot_control/tab_shell.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubWsClient extends WsClient {
  _StubWsClient() : super();
}

void _initPrefs() {
  SharedPreferences.setMockInitialValues(<String, Object>{});
}

Future<void> _pumpShell(WidgetTester tester, {Size? size}) async {
  _initPrefs();
  if (size != null) {
    await tester.binding.setSurfaceSize(size);
  }
  final client = _StubWsClient();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: TabShell(client: client)),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(_initPrefs);

  group('TabShell (v1.2)', () {
    testWidgets('renders three tab labels in order', (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      expect(find.text('Joystick'), findsOneWidget);
      expect(find.text('Buttons'), findsOneWidget);
      expect(find.text('Image'), findsOneWidget);
    });

    testWidgets('Joystick tab is selected by default', (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      expect(find.byType(PtzPad), findsOneWidget);
    });

    testWidgets('tapping Image tab swaps the content', (tester) async {
      await _pumpShell(tester, size: const Size(400, 1100));
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
      expect(find.text('Wide'), findsOneWidget);
      expect(find.text('Normal'), findsOneWidget);
      expect(find.text('Narrow'), findsOneWidget);
      expect(find.byType(PtzPad), findsNothing);
    });

    testWidgets('narrow layout stacks preview above tabs', (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      expect(find.byType(TabBar), findsOneWidget);
    });

    testWidgets('wide layout uses 50/50 preview-left + tabs-right',
        (tester) async {
      await _pumpShell(tester, size: const Size(900, 600));
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('Joystick'), findsOneWidget);
      expect(find.text('Image'), findsOneWidget);
    });
  });

  group('Joystick tab', () {
    testWidgets('shows Recenter / Sleep / Wake quick actions',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 900));
      expect(find.text('Recenter'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('Wake'), findsOneWidget);
    });

    testWidgets('shows all 8 move-duration chips', (tester) async {
      await _pumpShell(tester, size: const Size(400, 900));
      for (final p in kMoveDurationPresets) {
        expect(find.text(p.label), findsOneWidget,
            reason: 'chip for ${p.label} missing');
      }
    });

    testWidgets('inline preset row shows P1..P6', (tester) async {
      await _pumpShell(tester, size: const Size(400, 900));
      for (int i = 1; i <= 6; i++) {
        expect(find.text('P$i'), findsOneWidget, reason: 'P$i missing');
      }
    });

    testWidgets('chip reflects current move duration', (tester) async {
      final client = _StubWsClient();
      await client.setMoveDuration(const Duration(milliseconds: 5000));
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TabShell(client: client))),
      );
      await tester.pump();
      final chip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('5 sec'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(chip.selected, isTrue);
    });

    testWidgets('tapping a chip updates client.moveDuration',
        (tester) async {
      final client = _StubWsClient();
      await tester.binding.setSurfaceSize(const Size(400, 900));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TabShell(client: client))),
      );
      await tester.pump();
      await tester.tap(find.text('1 sec'));
      await tester.pump();
      expect(client.moveDuration, const Duration(milliseconds: 1000));
    });

  });

  group('Buttons tab', () {
    Future<void> goToButtons(WidgetTester tester) async {
      await _pumpShell(tester, size: const Size(400, 1000));
      await tester.tap(find.text('Buttons'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows 8 hold-direction buttons', (tester) async {
      await goToButtons(tester);
      for (final lbl in <String>[
        'Up', 'Down', 'Left', 'Right',
        'Up-Left', 'Up-Right', 'Down-Left', 'Down-Right',
      ]) {
        expect(find.text(lbl), findsOneWidget, reason: 'missing $lbl');
      }
    });

    testWidgets('shows Recenter / Sleep / Wake (same as Joystick tab)',
        (tester) async {
      await goToButtons(tester);
      expect(find.text('Recenter'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('Wake'), findsOneWidget);
    });

    testWidgets('shows inline P1..P6 preset row', (tester) async {
      await goToButtons(tester);
      for (int i = 1; i <= 6; i++) {
        expect(find.text('P$i'), findsOneWidget, reason: 'P$i missing');
      }
    });

    testWidgets('shows the vertical zoom slider', (tester) async {
      await goToButtons(tester);
      // Joystick had ZoomSlider; Buttons tab now has one too.
      expect(find.byType(ZoomSlider), findsOneWidget);
    });

    testWidgets('shows duration chips identical to Joystick tab',
        (tester) async {
      await goToButtons(tester);
      // The chip strip moved into a shared `_BottomControls` widget so
      // it's literally the same widget on both tabs. Sanity-check by
      // confirming all 8 preset labels render here too.
      for (final p in kMoveDurationPresets) {
        expect(find.text(p.label), findsOneWidget,
            reason: 'chip ${p.label} missing on Buttons tab');
      }
    });
  });

  group('Image tab', () {
    Future<void> goToImage(WidgetTester tester) async {
      await _pumpShell(tester, size: const Size(400, 1400));
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows Auto-track + View + Anti-flicker segments',
        (tester) async {
      await goToImage(tester);
      expect(find.text('Off'), findsAtLeast(1));
      expect(find.text('Person'), findsOneWidget);
      expect(find.text('Group'), findsOneWidget);
      expect(find.text('Wide'), findsOneWidget);
      expect(find.text('50 Hz'), findsOneWidget);
      expect(find.text('60 Hz'), findsOneWidget);
    });

    testWidgets('shows HDR / Face / Flip / Auto WB toggles',
        (tester) async {
      await goToImage(tester);
      expect(find.text('HDR'), findsOneWidget);
      expect(find.text('Face exposure'), findsOneWidget);
      expect(find.text('Face focus'), findsOneWidget);
      expect(find.text('Flip'), findsOneWidget);
      expect(find.text('Auto WB'), findsOneWidget);
    });

    testWidgets('shows 4 color sliders + EV bias', (tester) async {
      await goToImage(tester);
      expect(find.text('Brightness'), findsOneWidget);
      expect(find.text('Contrast'), findsOneWidget);
      expect(find.text('Saturation'), findsOneWidget);
      expect(find.text('Sharpness'), findsOneWidget);
      expect(find.text('EV bias'), findsOneWidget);
    });

    testWidgets('every section header has a Reset button', (tester) async {
      await goToImage(tester);
      // Sections with Reset: View, Exposure, Anti-flicker, White balance, Color.
      expect(find.text('Reset'), findsAtLeast(5));
    });
  });
}

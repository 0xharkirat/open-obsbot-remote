// Widget tests for the v1.2 TabShell scaffolding (PR A: feat/tab-bar-shell).
//
// These tests run offline — no bridge needed. They use a stub WsClient that
// returns sensible defaults so the widgets can render. The bridge-coupled
// behavior (gimbal, zoom, presets, sequence, image) is covered by the Node
// smoke harness under `tests/` — run those against a real Tiny 2 Lite.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/control_screen.dart';
import 'package:obsbot_control/tab_shell.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubWsClient extends WsClient {
  _StubWsClient() : super();
  // Inherits all defaults — the un-connected state still renders the tabs;
  // PreviewWidget falls through to its "Connecting..." placeholder.
}

void _initPrefs() {
  // WsClient hits SharedPreferences in its constructor and in
  // setMoveDuration; without this mock, those calls hang under
  // flutter_test, which has no real platform plugins.
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
  group('TabShell', () {
    testWidgets('renders five tab labels in order', (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      // The TabBar renders both an icon and a text label per tab. We assert
      // on the text labels because they are stable across icon swaps.
      expect(find.text('Joystick'), findsOneWidget);
      expect(find.text('Buttons'), findsOneWidget);
      expect(find.text('Presets'), findsOneWidget);
      expect(find.text('Sequence'), findsOneWidget);
      expect(find.text('Image'), findsOneWidget);
    });

    testWidgets('Joystick tab is selected by default', (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      // PtzPad lives only inside the Joystick tab.
      expect(find.byType(PtzPad), findsOneWidget);
    });

    testWidgets('tapping Image tab swaps the content', (tester) async {
      await _pumpShell(tester, size: const Size(400, 1100));
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
      // Image tab content includes the View FOV segmented control.
      expect(find.text('Wide'), findsOneWidget);
      expect(find.text('Normal'), findsOneWidget);
      expect(find.text('Narrow'), findsOneWidget);
      // Joystick pad disappears (tab swap, not pinned).
      expect(find.byType(PtzPad), findsNothing);
    });

    testWidgets('tapping Sequence tab shows inline editor controls',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      await tester.tap(find.text('Sequence'));
      await tester.pumpAndSettle();
      // SequencerEditor seeds a default step on a fresh client, so we
      // see the Add step button + the step's Hold/Move controls.
      expect(find.text('Add step'), findsOneWidget);
      // "Save & start" is the primary action when not running.
      expect(find.text('Save & start'), findsOneWidget);
    });

    testWidgets('narrow layout stacks preview above tabs', (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      // Confirm a TabBar exists in the tree (no Row split with preview-left).
      expect(find.byType(TabBar), findsOneWidget);
    });

    testWidgets('wide layout uses 50/50 preview-left + tabs-right',
        (tester) async {
      await _pumpShell(tester, size: const Size(900, 600));
      expect(find.byType(TabBar), findsOneWidget);
      // At wide breakpoint the shell uses a top-level Row; render must still
      // produce the tab labels.
      expect(find.text('Joystick'), findsOneWidget);
      expect(find.text('Image'), findsOneWidget);
    });
  });

  group('Joystick tab (PR B)', () {
    testWidgets('shows Recenter / Sleep / Wake quick actions',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      expect(find.text('Recenter'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('Wake'), findsOneWidget);
    });

    testWidgets('shows all 8 move-duration chips', (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      // ChoiceChip renders the preset label as a Text child.
      for (final p in kMoveDurationPresets) {
        expect(find.text(p.label), findsOneWidget,
            reason: 'chip for ${p.label} missing');
      }
    });

    testWidgets('chip reflects current move duration', (tester) async {
      final client = _StubWsClient();
      // Force a duration that's guaranteed to match a chip preset.
      await client.setMoveDuration(const Duration(milliseconds: 5000));
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TabShell(client: client)),
        ),
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
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TabShell(client: client)),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('1 sec'));
      await tester.pump();
      expect(client.moveDuration, const Duration(milliseconds: 1000));
    });
  });

  group('Buttons tab (PR C)', () {
    Future<void> goToButtons(WidgetTester tester) async {
      await _pumpShell(tester, size: const Size(400, 900));
      await tester.tap(find.text('Buttons'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows 8 hold-direction buttons (4 cardinal + 4 diagonal)',
        (tester) async {
      await goToButtons(tester);
      for (final lbl in <String>[
        'Up', 'Down', 'Left', 'Right',
        'Up-Left', 'Up-Right', 'Down-Left', 'Down-Right',
      ]) {
        expect(find.text(lbl), findsOneWidget, reason: 'missing $lbl');
      }
    });

    testWidgets('shows speed slider with Slow / Fast labels',
        (tester) async {
      await goToButtons(tester);
      expect(find.text('Slow'), findsOneWidget);
      expect(find.text('Fast'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      // Default 100%.
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('shows Recenter / Sleep / Wake quick actions',
        (tester) async {
      await goToButtons(tester);
      expect(find.text('Recenter'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('Wake'), findsOneWidget);
    });
  });

  group('Sequence tab (PR E)', () {
    Future<void> goToSeq(WidgetTester tester) async {
      // The sequencer has many vertical sections (library bar, step
      // cards, mode selector, action row) — use a taller surface so
      // multiple step cards fit on-screen.
      await _pumpShell(tester, size: const Size(400, 1200));
      await tester.tap(find.text('Sequence'));
      await tester.pumpAndSettle();
    }

    testWidgets('seeds one step + shows Add step / Save & start',
        (tester) async {
      await goToSeq(tester);
      // Fresh client seeds a default step, so Hold/Move card is present.
      expect(find.text('Hold'), findsOneWidget);
      expect(find.text('Move'), findsOneWidget);
      expect(find.text('Add step'), findsOneWidget);
      expect(find.text('Save & start'), findsOneWidget);
    });

    testWidgets('Add step button appends a second step card',
        (tester) async {
      await goToSeq(tester);
      // Sanity: starts with one step.
      expect(find.text('Hold'), findsOneWidget);
      await tester.tap(find.text('Add step'));
      await tester.pumpAndSettle();
      // Two steps → two "Hold" labels in the timeline.
      expect(find.text('Hold'), findsNWidgets(2));
    });
  });

  group('Image tab (PR F)', () {
    Future<void> goToImage(WidgetTester tester) async {
      await _pumpShell(tester, size: const Size(400, 1200));
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows Auto-track segmented (Off / Person / Group)',
        (tester) async {
      await goToImage(tester);
      // "Off" appears twice on the Image tab: once for Auto-track,
      // once for Anti-flicker (added in PR G).
      expect(find.text('Off'), findsAtLeast(1));
      expect(find.text('Person'), findsOneWidget);
      expect(find.text('Group'), findsOneWidget);
    });

    testWidgets('shows View segmented (Wide / Normal / Narrow)',
        (tester) async {
      await goToImage(tester);
      expect(find.text('Wide'), findsOneWidget);
      expect(find.text('Normal'), findsOneWidget);
      expect(find.text('Narrow'), findsOneWidget);
    });

    testWidgets('shows HDR / face / flip toggles', (tester) async {
      await goToImage(tester);
      expect(find.text('HDR'), findsOneWidget);
      // PR J shortened labels so forui FButton fits at 2-per-row 360 px.
      expect(find.text('Face exposure'), findsOneWidget);
      expect(find.text('Face focus'), findsOneWidget);
      expect(find.text('Flip'), findsOneWidget);
    });

    testWidgets('shows 4 color sliders with names', (tester) async {
      await goToImage(tester);
      expect(find.text('Brightness'), findsOneWidget);
      expect(find.text('Contrast'), findsOneWidget);
      expect(find.text('Saturation'), findsOneWidget);
      expect(find.text('Sharpness'), findsOneWidget);
      // 4 color sliders + 1 EV bias slider when in auto exposure.
      // (5 total on default state since wb is auto so no temp slider.)
      expect(find.byType(Slider), findsAtLeast(4));
    });

    testWidgets('shows Exposure Auto/Manual segmented + Anti-flicker',
        (tester) async {
      await goToImage(tester);
      expect(find.text('Auto'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);
      // Anti-flicker segmented: Off / 50 Hz / 60 Hz.
      // (Note: "Off" is also in Auto-track segmented.)
      expect(find.text('50 Hz'), findsOneWidget);
      expect(find.text('60 Hz'), findsOneWidget);
    });

    testWidgets('shows White balance section + Auto WB toggle',
        (tester) async {
      await goToImage(tester);
      // Label shortened to "Auto WB" so the forui FButton fits the row.
      expect(find.text('Auto WB'), findsOneWidget);
    });
  });

  group('Presets tab (PR D)', () {
    Future<void> goToPresets(WidgetTester tester) async {
      await _pumpShell(tester, size: const Size(400, 900));
      await tester.tap(find.text('Presets'));
      await tester.pumpAndSettle();
    }

    testWidgets('renders all 6 preset badges P1..P6', (tester) async {
      await goToPresets(tester);
      for (int i = 1; i <= 6; i++) {
        expect(find.text('P$i'), findsOneWidget, reason: 'P$i missing');
      }
    });

    testWidgets('empty presets show "(empty)" + "Hold to save here"',
        (tester) async {
      await goToPresets(tester);
      // No presets saved on a stub client → all 6 are empty.
      expect(find.text('(empty)'), findsNWidgets(6));
      expect(find.text('Hold to save here'), findsNWidgets(6));
    });
  });
}

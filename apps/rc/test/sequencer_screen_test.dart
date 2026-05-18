// Widget tests for the v1.4 sequencer step card (fix B3).
//
// v1.4 splits each step's timing into two visible fields so the
// operator can read move-time and stay-time independently:
//
//   Move to P_X over: [ dropdown chip ]
//   Stay for:         [ N ] seconds
//                                       ≈ N s total
//
// Pre-v1.4 these shared one collapsed line; users misread "stay 40 s
// + move 30 s" as 40 s of wall-clock when it was really 70 s. The
// trailing total label is the operator's wall-clock cross-check.
//
// Bridge-coupled behaviour (sequence start/stop, persistence, motion
// timings) is still covered by the Node smoke harness under
// `tests/sequencer_save.mjs` + `tests/slow_motion.mjs`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/sequencer_screen.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubWsClient extends WsClient {
  _StubWsClient() : super();
}

void _initPrefs() {
  SharedPreferences.setMockInitialValues(<String, Object>{});
}

Future<_StubWsClient> _pumpEditor(WidgetTester tester, {Size? size}) async {
  _initPrefs();
  await tester.binding.setSurfaceSize(size ?? const Size(400, 1000));
  final client = _StubWsClient();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SequencerEditor(client: client, showTopBar: false),
      ),
    ),
  );
  await tester.pump();
  return client;
}

void main() {
  setUp(_initPrefs);

  group('Sequencer step card (v1.4 B3 split fields)', () {
    testWidgets('2-step sequence shows both Move + Stay labels per step',
        (tester) async {
      await _pumpEditor(tester);
      // Default editor hydrates with one seed step. Add a second so we
      // can assert the labels appear once per step.
      await tester.tap(find.text('Add step'));
      await tester.pumpAndSettle();

      // Header lines confirm we really have 2 steps.
      expect(find.textContaining('Step 1:'), findsOneWidget);
      expect(find.textContaining('Step 2:'), findsOneWidget);

      // Each step renders a "Move to <preset> over" line and a
      // "Stay for" line. With 2 steps that's 2 of each.
      expect(find.textContaining('Move to'), findsNWidgets(2));
      expect(find.text('Stay for'), findsNWidgets(2));
      expect(find.text('seconds'), findsNWidgets(2));
    });

    testWidgets(
        'typing 90 in stay + selecting 30 sec move renders ≈ 120 s total',
        (tester) async {
      await _pumpEditor(tester);
      // Default: 1 step, seconds=60, transition=1000ms ⇒ ≈ 61 s total.
      expect(find.text('≈ 61 s total'), findsOneWidget);

      // Type 90 in the only stay field (matches by widget type since
      // there's exactly one TextField in the editor body for the single
      // step's seconds input).
      await tester.enterText(find.byType(TextField), '90');
      await tester.pump();
      // After 90 s stay + 1 s move = 91 s.
      expect(find.text('≈ 91 s total'), findsOneWidget);

      // Open the move-duration dropdown (currently shows "1 sec") and
      // pick "30 sec".
      await tester.tap(find.text('1 sec'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 sec').last);
      await tester.pumpAndSettle();

      // Now 30 s move + 90 s stay = 120 s total.
      expect(find.text('≈ 120 s total'), findsOneWidget);
    });

    // Regression: the split-fields layout needs to fit a 360 px column
    // without overflow. Move-row + Stay-row each carry a label, an
    // input, and trailing copy ("seconds"); a missing Flexible/Expanded
    // would push the row past its slot. Mirrors the v1.2.1 320 px
    // overflow guard in `tab_shell_test.dart`.
    testWidgets('step card does not overflow at 360 px', (tester) async {
      final prev = FlutterError.onError;
      final overflows = <FlutterErrorDetails>[];
      FlutterError.onError = (FlutterErrorDetails d) {
        if (d.exceptionAsString().contains('overflow')) overflows.add(d);
      };
      try {
        await _pumpEditor(tester, size: const Size(360, 1000));
        // Add a second step too; both rows must coexist cleanly.
        await tester.tap(find.text('Add step'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Move to'), findsNWidgets(2));
        expect(overflows, isEmpty,
            reason: 'step card must not overflow at 360 px');
      } finally {
        FlutterError.onError = prev;
      }
    });

    testWidgets('stay-seconds field enforces minimum of 3', (tester) async {
      await _pumpEditor(tester);
      // Default: seconds=60, transition=1000ms ⇒ ≈ 61 s total.
      expect(find.text('≈ 61 s total'), findsOneWidget);

      // Typing 2 (below the min) must NOT update the in-memory seconds.
      // The trailing total should still read 61.
      await tester.enterText(find.byType(TextField), '2');
      await tester.pump();
      expect(find.text('≈ 61 s total'), findsOneWidget,
          reason: 'below-min input must not change the step total');

      // Typing 3 (the minimum) MUST update: 1 s move + 3 s stay = 4 s.
      await tester.enterText(find.byType(TextField), '3');
      await tester.pump();
      expect(find.text('≈ 4 s total'), findsOneWidget);
      expect(find.text('≈ 61 s total'), findsNothing);
    });
  });

  // v1.5 W1 fix #3: the old "Save & start" implicitly persisted to the
  // library; users hit it expecting a quick test-run. Now Start is
  // separate from Bookmark - start sends the scratch + begins; bookmark
  // opens the explicit name prompt.
  group('v1.5 W1 footer (Start + Bookmark)', () {
    testWidgets('footer shows Add step + Start + Bookmark icon',
        (tester) async {
      await _pumpEditor(tester);
      expect(find.text('Add step'), findsOneWidget);
      // Primary action is Start (was "Save & start" pre-v1.5).
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('Save & start'), findsNothing);
      // Bookmark is icon-only - find by tooltip.
      expect(find.byTooltip('Bookmark sequence...'), findsOneWidget);
    });

    testWidgets('Bookmark opens save dialog', (tester) async {
      await _pumpEditor(tester);
      await tester.tap(find.byTooltip('Bookmark sequence...'));
      await tester.pumpAndSettle();
      expect(find.text('Save sequence'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });
  });

  // v1.5 W1 fix #4: 3-radio ListTile column for loop mode replaced
  // with a single segmented row [ Once | Loop | Ping-pong ].
  group('v1.5 W1 loop-mode segmented', () {
    testWidgets('three labels rendered in one row', (tester) async {
      await _pumpEditor(tester);
      expect(find.text('Once'), findsOneWidget);
      expect(find.text('Loop'), findsOneWidget);
      expect(find.text('Ping-pong'), findsOneWidget);
      // Old verbose subtitles are gone.
      expect(find.textContaining('stop at end'), findsNothing);
      expect(find.textContaining('P1 -> P2 -> P3 -> P1'), findsNothing);
    });
  });

  // v1.5 W1 fix #4: Add step debounces for 300ms after a tap to
  // prevent the second of two rapid taps from appending a duplicate.
  group('v1.5 W1 Add step debounce', () {
    testWidgets('two rapid taps only add one card', (tester) async {
      await _pumpEditor(tester);
      // Seed = 1 step. Tap Add twice without pumping the timer.
      await tester.tap(find.text('Add step'));
      await tester.pump();
      await tester.tap(find.text('Add step'), warnIfMissed: false);
      await tester.pump();
      // Should still be 2 steps total, not 3.
      expect(find.textContaining('Step 1:'), findsOneWidget);
      expect(find.textContaining('Step 2:'), findsOneWidget);
      expect(find.textContaining('Step 3:'), findsNothing);
      // Wait out the debounce + highlight to clean up timers.
      await tester.pump(const Duration(milliseconds: 700));
    });
  });
}

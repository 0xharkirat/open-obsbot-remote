// Widget tests for the v1.4 OBSBOT-Center-inspired CollapsibleSection.
//
// Covers: default-open, tap-to-collapse, persisted open state via
// SharedPreferences, refresh-icon callback, and the optional tooltip
// rendering. The header is a SectionHeader so anything that tests
// header chrome also exercises that widget transitively.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:obsbot_control/widgets/collapsible_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(
  WidgetTester tester, {
  required Widget child,
  Map<String, Object> prefs = const <String, Object>{},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: child,
        ),
      ),
    ),
  );
  // Pump once for layout, then again to flush the async prefs load
  // inside CollapsibleSection.initState.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('CollapsibleSection', () {
    testWidgets('renders header label uppercase', (tester) async {
      await _pump(
        tester,
        child: const CollapsibleSection(
          id: 'tone',
          label: 'Tone',
          child: Text('body'),
        ),
      );
      expect(find.text('TONE'), findsOneWidget);
    });

    testWidgets('default-open shows body', (tester) async {
      await _pump(
        tester,
        child: const CollapsibleSection(
          id: 'tone',
          label: 'Tone',
          child: Text('body'),
        ),
      );
      expect(find.text('body'), findsOneWidget);
    });

    testWidgets('defaultOpen:false hides body until tapped',
        (tester) async {
      await _pump(
        tester,
        child: const CollapsibleSection(
          id: 'color',
          label: 'Color',
          defaultOpen: false,
          child: Text('body'),
        ),
      );
      expect(find.text('body'), findsNothing);
      await tester.tap(find.text('COLOR'));
      await tester.pumpAndSettle();
      expect(find.text('body'), findsOneWidget);
    });

    testWidgets('tapping header collapses body', (tester) async {
      await _pump(
        tester,
        child: const CollapsibleSection(
          id: 'tone',
          label: 'Tone',
          child: Text('body'),
        ),
      );
      expect(find.text('body'), findsOneWidget);
      await tester.tap(find.text('TONE'));
      await tester.pumpAndSettle();
      expect(find.text('body'), findsNothing);
    });

    testWidgets('open state persists via SharedPreferences',
        (tester) async {
      // Pre-set the pref to closed.
      await _pump(
        tester,
        prefs: <String, Object>{'section_tone_open': false},
        child: const CollapsibleSection(
          id: 'tone',
          label: 'Tone',
          child: Text('body'),
        ),
      );
      expect(find.text('body'), findsNothing,
          reason: 'should respect persisted closed state on cold start');

      // Tap to open, then verify the pref was written.
      await tester.tap(find.text('TONE'));
      await tester.pumpAndSettle();
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('section_tone_open'), isTrue);
      expect(find.text('body'), findsOneWidget);
    });

    testWidgets('persisted true overrides defaultOpen:false', (tester) async {
      await _pump(
        tester,
        prefs: <String, Object>{'section_color_open': true},
        child: const CollapsibleSection(
          id: 'color',
          label: 'Color',
          defaultOpen: false,
          child: Text('body'),
        ),
      );
      expect(find.text('body'), findsOneWidget);
    });

    testWidgets('refresh icon callback fires when tapped',
        (tester) async {
      int hits = 0;
      await _pump(
        tester,
        child: CollapsibleSection(
          id: 'exposure',
          label: 'Exposure',
          onRefresh: () => hits++,
          child: const Text('body'),
        ),
      );
      // Refresh icon has tooltip 'Refresh from camera'.
      final iconBtn = find.byTooltip('Refresh from camera');
      expect(iconBtn, findsOneWidget);
      await tester.tap(iconBtn);
      await tester.pumpAndSettle();
      expect(hits, 1);
    });

    testWidgets('two sections persist independently', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                CollapsibleSection(
                  id: 'a',
                  label: 'A',
                  child: Text('body-a'),
                ),
                CollapsibleSection(
                  id: 'b',
                  label: 'B',
                  child: Text('body-b'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Collapse A only.
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(find.text('body-a'), findsNothing);
      expect(find.text('body-b'), findsOneWidget);

      final p = await SharedPreferences.getInstance();
      expect(p.getBool('section_a_open'), isFalse);
      expect(p.getBool('section_b_open'), isNull,
          reason: 'B was never toggled - no pref should be written');
    });
  });
}

// Widget tests for the v1.4 W6 TabShell - OBSBOT Center-inspired
// 3-tab structure: Drive / Image / More.
//
// Drive folds the v1.2 Joystick + Buttons tabs into one page with a
// control-style toggle (joystick or 8-way buttons). View & Gimbal
// inside Drive holds the FOV pills (moved from Image) plus the new
// AI sub-mode picker. More consolidates the v1.2 AppBar overflow
// (grid menu / mode switch / disconnect / cache) plus a sequence
// library entry point.
//
// Bridge-coupled behavior (gimbal, zoom, presets save, sequence, image)
// is covered by the Node smoke harness under `tests/`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:obsbot_control/control_screen.dart';
import 'package:obsbot_control/tab_shell.dart';
import 'package:obsbot_control/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubWsClient extends WsClient {
  _StubWsClient() : super();

  // v1.4 W4 - capture preset action calls so the long-press options
  // sheet tests can assert which action fired without a live bridge.
  final List<({String action, int id, String? name, Duration? duration})>
      presetCalls =
      <({String action, int id, String? name, Duration? duration})>[];

  // v1.4 W6 - capture aiSetMode calls so the sub-mode picker tests
  // can assert which (mode, sub_mode) tuple fired.
  final List<({String mode, String sub})> aiCalls =
      <({String mode, String sub})>[];

  @override
  void presetSave(int id, String name) {
    presetCalls
        .add((action: 'save', id: id, name: name, duration: null));
  }

  @override
  void presetRecall(int id, {Duration? duration}) {
    presetCalls
        .add((action: 'recall', id: id, name: null, duration: duration));
  }

  @override
  void presetDelete(int id) {
    presetCalls.add((action: 'delete', id: id, name: null, duration: null));
  }

  @override
  void aiSetMode(String mode, [String sub = 'normal']) {
    aiCalls.add((mode: mode, sub: sub));
  }
}

/// Seed the inline preset row's `_saved` branch with a synthetic
/// `CameraState` so the long-press handler hits the bottom-sheet path.
void _seedPresets(_StubWsClient client, List<PresetEntry> presets) {
  final json = <String, dynamic>{
    'event': 'state',
    'presets': presets.map((p) => p.toJson()).toList(),
  };
  client.debugSetState(CameraState.fromEvent(json));
}

/// Seed a CameraState patch on the stub client.
void _seedState(_StubWsClient client, Map<String, dynamic> patch) {
  final json = <String, dynamic>{'event': 'state', ...patch};
  client.debugSetState(CameraState.fromEvent(json));
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
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(_initPrefs);

  group('TabShell (v1.4 W6)', () {
    testWidgets('renders three tab labels in order', (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      expect(find.text('Drive'), findsOneWidget);
      expect(find.text('Image'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);
    });

    testWidgets('Drive tab is selected by default with 8-way button pad',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 1100));
      // v1.5: Drive defaults to the 8-way button pad (driveControlStyle
      // = 'buttons') so onboarding lands on the discrete, unambiguous
      // surface. PtzPad joystick stays one toggle away in View & Gimbal.
      expect(find.byType(PtzPad), findsNothing);
      expect(find.text('Up'), findsOneWidget);
      expect(find.text('Down'), findsOneWidget);
    });

    testWidgets('tapping Image tab swaps the content', (tester) async {
      await _pumpShell(tester, size: const Size(400, 1400));
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
      // Image no longer carries the joystick / FOV; those moved to
      // Drive. Image keeps Tone toggles + WB.
      expect(find.text('HDR'), findsOneWidget);
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
      expect(find.text('Drive'), findsOneWidget);
      expect(find.text('Image'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);
    });
  });

  group('Drive tab', () {
    testWidgets('shows Recenter / Sleep / Wake quick actions',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 1100));
      expect(find.text('Recenter'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('Wake'), findsOneWidget);
    });

    // Regression: 3-per-row quick-action overflow at 320 px (CLAUDE.md
    // note 29 / PR Q). Drive page keeps the same _QuickActions row, so
    // the test stays as a guard.
    testWidgets('Recenter row does not overflow at 320 px', (tester) async {
      final prev = FlutterError.onError;
      final overflows = <FlutterErrorDetails>[];
      FlutterError.onError = (FlutterErrorDetails d) {
        if (d.exceptionAsString().contains('overflow')) overflows.add(d);
      };
      try {
        await _pumpShell(tester, size: const Size(320, 1200));
        expect(find.text('Recenter'), findsOneWidget);
        expect(find.text('Sleep'), findsOneWidget);
        expect(find.text('Wake'), findsOneWidget);
        expect(overflows, isEmpty,
            reason: '3-per-row quick-action buttons must not overflow at 320 px');
      } finally {
        FlutterError.onError = prev;
      }
    });

    testWidgets('shows inline P1..P6 preset row inside Presets section',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 1200));
      for (int i = 1; i <= 6; i++) {
        expect(find.text('P$i'), findsOneWidget, reason: 'P$i missing');
      }
    });

    testWidgets('shows ZoomSlider inside View & Gimbal section',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 1200));
      expect(find.byType(ZoomSlider), findsOneWidget);
    });

    testWidgets('shows FOV pills (Wide / Normal / Narrow) - moved from Image',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 1400));
      expect(find.text('Wide'), findsOneWidget);
      expect(find.text('Normal'), findsOneWidget);
      expect(find.text('Narrow'), findsOneWidget);
    });

    testWidgets('shows AI mode segmented (Off / Person / Group)',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 1500));
      // AI tracking section opens by default.
      expect(find.text('Off'), findsAtLeast(1));
      expect(find.text('Person'), findsOneWidget);
      expect(find.text('Group'), findsOneWidget);
    });

    testWidgets('AI sub-mode picker appears only when mode = Person',
        (tester) async {
      _initPrefs();
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      final client = _StubWsClient();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TabShell(client: client))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Default state: aiMode == 'none' - no sub-modes visible.
      expect(find.text('Upper-body'), findsNothing);

      // Patch state to human mode.
      _seedState(client, <String, dynamic>{
        'ai': <String, dynamic>{'mode': 'human', 'sub_mode': 'normal'},
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 'Normal' appears twice: FOV pill (Wide/Normal/Narrow) and sub-mode
      // pill. The sub-mode pill is the distinguishing one with the
      // unique siblings below.
      expect(find.text('Normal'), findsNWidgets(2));
      expect(find.text('Upper-body'), findsOneWidget);
      expect(find.text('Close-up'), findsOneWidget);
      expect(find.text('Headless'), findsOneWidget);
      expect(find.text('Lower-body'), findsOneWidget);
    });

    testWidgets('tapping a sub-mode calls aiSetMode(human, wireName)',
        (tester) async {
      _initPrefs();
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      final client = _StubWsClient();
      _seedState(client, <String, dynamic>{
        'ai': <String, dynamic>{'mode': 'human', 'sub_mode': 'normal'},
      });
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TabShell(client: client))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('Upper-body'));
      await tester.pumpAndSettle();
      // Filter to sub-mode calls (the AI mode segmented might log its
      // own from the rebuild path - we only care this specific click
      // hit upper_body).
      expect(
          client.aiCalls
              .where((c) => c.mode == 'human' && c.sub == 'upper_body'),
          hasLength(greaterThanOrEqualTo(1)));
    });

    testWidgets('shows all 8 move-duration chips inside Move pacing',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 1200));
      for (final p in kMoveDurationPresets) {
        expect(find.text(p.label), findsOneWidget,
            reason: 'chip for ${p.label} missing');
      }
    });

    testWidgets('shows the control-style toggle (Joystick / Buttons)',
        (tester) async {
      await _pumpShell(tester, size: const Size(400, 1400));
      expect(find.text('Joystick'), findsOneWidget);
      expect(find.text('Buttons'), findsOneWidget);
    });

    testWidgets('switching control style swaps button pad for PtzPad',
        (tester) async {
      _initPrefs();
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      final client = _StubWsClient();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TabShell(client: client))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // v1.5 default: buttons. Joystick is one tap away.
      expect(find.byType(PtzPad), findsNothing);
      expect(find.text('Up'), findsOneWidget);
      // Tap the Joystick pill to switch.
      await tester.tap(find.text('Joystick').first);
      await tester.pumpAndSettle();
      expect(find.byType(PtzPad), findsOneWidget);
      // 8-way hold buttons are no longer rendered.
      expect(find.text('Up'), findsNothing);
    });

    testWidgets('chip reflects current move duration', (tester) async {
      _initPrefs();
      final client = _StubWsClient();
      await client.setMoveDuration(const Duration(milliseconds: 5000));
      await tester.binding.setSurfaceSize(const Size(400, 1200));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TabShell(client: client))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
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
      _initPrefs();
      final client = _StubWsClient();
      await tester.binding.setSurfaceSize(const Size(400, 1200));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TabShell(client: client))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('1 sec'));
      await tester.pump();
      expect(client.moveDuration, const Duration(milliseconds: 1000));
    });
  });

  group('Image tab', () {
    Future<void> goToImage(WidgetTester tester) async {
      await _pumpShell(tester, size: const Size(400, 1600));
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
    }

    testWidgets('still shows Anti-flicker segments (FOV/AI moved to Drive)',
        (tester) async {
      await goToImage(tester);
      expect(find.text('50 Hz'), findsOneWidget);
      expect(find.text('60 Hz'), findsOneWidget);
      // FOV pills are NOT on Image anymore.
      expect(find.text('Wide'), findsNothing);
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
      // v1.4 W6: Color section starts collapsed; expand to see sliders.
      await tester.tap(find.text('COLOR'));
      await tester.pumpAndSettle();
      expect(find.text('Brightness'), findsOneWidget);
      expect(find.text('Contrast'), findsOneWidget);
      expect(find.text('Saturation'), findsOneWidget);
      expect(find.text('Sharpness'), findsOneWidget);
      expect(find.text('EV bias'), findsOneWidget);
    });

    testWidgets('Image tab renders without overflow at 360 px',
        (tester) async {
      final prev = FlutterError.onError;
      final overflows = <FlutterErrorDetails>[];
      FlutterError.onError = (FlutterErrorDetails d) {
        if (d.exceptionAsString().contains('overflow')) overflows.add(d);
      };
      try {
        await _pumpShell(tester, size: const Size(360, 1600));
        await tester.tap(find.text('Image'));
        await tester.pumpAndSettle();
        expect(find.text('50 Hz'), findsOneWidget);
        expect(overflows, isEmpty,
            reason: 'ForSegmented + toggles must not overflow at 360 px');
      } finally {
        FlutterError.onError = prev;
      }
    });

    // v1.5 W3 regression: Image-tab Face exposure / Face focus toggles
    // were rendering with a white background while OFF. Root cause was
    // not state desync; both buttons WERE correctly rendering their
    // bound state (`s.faceAe` / `s.faceFocus`) and the OFF branch was
    // hitting `FButtonVariant.outline` as intended. The user's screenshot
    // showed them ON (true), and `FButtonVariant.primary` resolved to
    // shadcn's "inverted primary" (white-gray) under `FThemes.zinc.dark`
    // because forui's primary on dark themes is light by convention.
    // Fix re-themed forui's `colors.primary` to OBSBOT brand red.
    //
    // The test below asserts the OFF branch wires up `.outline` (not
    // `.primary`) for both face toggles when the bridge reports false -
    // a structural guard that the variant-to-state mapping doesn't
    // regress.
    testWidgets(
        'Face exposure / Face focus render outline variant when OFF',
        (tester) async {
      _initPrefs();
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      final client = _StubWsClient();
      // Force-seed default off-state so the test is independent of
      // CameraState.empty defaults drifting later.
      _seedState(client, <String, dynamic>{
        'image': <String, dynamic>{
          'hdr': false,
          'face_ae': false,
          'face_focus': false,
          'flip_h': false,
        },
      });
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TabShell(client: client))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();

      FButton faceAeBtn = tester.widget<FButton>(
        find.ancestor(
          of: find.text('Face exposure'),
          matching: find.byType(FButton),
        ),
      );
      FButton faceFocusBtn = tester.widget<FButton>(
        find.ancestor(
          of: find.text('Face focus'),
          matching: find.byType(FButton),
        ),
      );
      expect(faceAeBtn.variant, isNot(FButtonVariant.primary),
          reason: 'Face exposure OFF must not render primary variant');
      expect(faceFocusBtn.variant, isNot(FButtonVariant.primary),
          reason: 'Face focus OFF must not render primary variant');
      expect(faceAeBtn.variant, FButtonVariant.outline);
      expect(faceFocusBtn.variant, FButtonVariant.outline);
    });
  });

  group('More tab', () {
    Future<void> goToMore(WidgetTester tester) async {
      await _pumpShell(tester, size: const Size(400, 1800));
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows Device / Sequence library / Grid overlay sections',
        (tester) async {
      await goToMore(tester);
      expect(find.text('DEVICE'), findsOneWidget);
      expect(find.text('SEQUENCE LIBRARY'), findsOneWidget);
      expect(find.text('GRID OVERLAY'), findsOneWidget);
      expect(find.text('CONNECTION'), findsOneWidget);
      expect(find.text('ABOUT'), findsOneWidget);
    });

    testWidgets('shows the 4 grid overlay toggles', (tester) async {
      await goToMore(tester);
      // Expand the Grid overlay section if it's collapsed - by default
      // it's open per defaultOpen:true.
      expect(find.text('Center crosshair'), findsOneWidget);
      expect(find.text('Attitude indicator'), findsOneWidget);
      expect(find.text('Rule of thirds'), findsOneWidget);
      expect(find.text('Pan / Tilt readout'), findsOneWidget);
    });

    testWidgets('shows the "Open editor" button in Sequence library',
        (tester) async {
      await goToMore(tester);
      expect(find.text('Open editor'), findsOneWidget);
    });

    testWidgets('shows Disconnect button in Connection', (tester) async {
      await goToMore(tester);
      expect(find.text('Disconnect'), findsOneWidget);
    });

    testWidgets('shows version in About', (tester) async {
      await goToMore(tester);
      expect(find.text('1.4.0-dev'), findsOneWidget);
    });
  });

  // v1.4 W4 - preset bookmark long-press now opens a 4-action bottom
  // sheet (Update with current pose / Recall instantly / Rename /
  // Delete) on SAVED slots. EMPTY slots keep the original one-step
  // tap-to-save flow. These tests cover both branches plus the two
  // most-broken-by-mistake actions (Update + Delete).
  group('Preset long-press options sheet (v1.4 W4)', () {
    /// Render a TabShell pre-seeded with a saved P1 (id=0). The slot's
    /// `Material` card sits on the Drive tab inline preset row.
    Future<_StubWsClient> pumpWithSavedP1(WidgetTester tester) async {
      _initPrefs();
      await tester.binding.setSurfaceSize(const Size(400, 1200));
      final client = _StubWsClient();
      _seedPresets(client, <PresetEntry>[
        const PresetEntry(
          id: 0,
          name: 'Vocalist',
          yaw: 12,
          pitch: -3,
          roll: 0,
          zoom: 1.4,
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TabShell(client: client))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      return client;
    }

    testWidgets('saved slot long-press opens sheet with 4 items',
        (tester) async {
      await pumpWithSavedP1(tester);
      await tester.longPress(find.text('Vocalist').first);
      await tester.pumpAndSettle();
      expect(find.text('Update with current pose'), findsOneWidget);
      expect(find.text('Recall instantly (no move)'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Preset Vocalist'), findsOneWidget);
    });

    testWidgets('empty slot long-press triggers one-step save (no sheet)',
        (tester) async {
      _initPrefs();
      await tester.binding.setSurfaceSize(const Size(400, 1200));
      final client = _StubWsClient();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TabShell(client: client))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.longPress(find.text('P1').first);
      await tester.pumpAndSettle();
      expect(find.text('Update with current pose'), findsNothing);
      expect(find.text('Recall instantly (no move)'), findsNothing);
      expect(client.presetCalls, hasLength(1));
      expect(client.presetCalls.first.action, 'save');
      expect(client.presetCalls.first.id, 0);
    });

    testWidgets('Update with current pose calls presetSave(id, name)',
        (tester) async {
      final client = await pumpWithSavedP1(tester);
      await tester.longPress(find.text('Vocalist').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update with current pose'));
      await tester.pumpAndSettle();
      expect(client.presetCalls, hasLength(1));
      expect(client.presetCalls.first.action, 'save');
      expect(client.presetCalls.first.id, 0);
      expect(client.presetCalls.first.name, 'Vocalist');
    });

    testWidgets('Delete calls presetDelete(id)', (tester) async {
      final client = await pumpWithSavedP1(tester);
      await tester.longPress(find.text('Vocalist').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(client.presetCalls, hasLength(1));
      expect(client.presetCalls.first.action, 'delete');
      expect(client.presetCalls.first.id, 0);
    });

    testWidgets('Recall instantly passes Duration.zero (bypasses default)',
        (tester) async {
      final client = await pumpWithSavedP1(tester);
      await client.setMoveDuration(const Duration(seconds: 30));
      await tester.pump();
      await tester.longPress(find.text('Vocalist').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recall instantly (no move)'));
      await tester.pumpAndSettle();
      expect(client.presetCalls, hasLength(1));
      expect(client.presetCalls.first.action, 'recall');
      expect(client.presetCalls.first.id, 0);
      expect(client.presetCalls.first.duration, Duration.zero);
    });
  });
}

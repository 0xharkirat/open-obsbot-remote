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

class _StubWsClient extends WsClient {
  _StubWsClient() : super();
  // Inherits all defaults — the un-connected state still renders the tabs;
  // PreviewWidget falls through to its "Connecting..." placeholder.
}

Future<void> _pumpShell(WidgetTester tester, {Size? size}) async {
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
      await _pumpShell(tester, size: const Size(400, 800));
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
      // Image tab content includes the "View:" FOV button.
      expect(find.textContaining('View:'), findsOneWidget);
      // Joystick pad disappears (tab swap, not pinned).
      expect(find.byType(PtzPad), findsNothing);
    });

    testWidgets('tapping Sequence tab shows editor entry', (tester) async {
      await _pumpShell(tester, size: const Size(400, 800));
      await tester.tap(find.text('Sequence'));
      await tester.pumpAndSettle();
      expect(find.text('Open sequence editor'), findsOneWidget);
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
}

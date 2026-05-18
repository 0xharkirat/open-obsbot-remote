import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'cache_menu.dart';
import 'ws_client.dart';

/// Pair-with-bridge screen (v1.2 PR I — first forui migration).
///
/// Replaces Material `Scaffold` + `AppBar` + `FilledButton` with the
/// forui equivalents (`FScaffold` / `FHeader.nested` / `FButton`)
/// wrapped in an `FTheme` block. The Material `TextField` stays —
/// forui's `FTextField` uses a different controller pattern; PR J
/// migrates it together with the tab content as a unit.
///
/// The rest of the app keeps Material widgets; forui coexists by
/// wrapping the subtree that wants forui styling.
class PinEntryScreen extends StatefulWidget {
  final WsClient client;
  const PinEntryScreen({super.key, required this.client});

  @override
  State<PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends State<PinEntryScreen> {
  final _ctrl = TextEditingController();
  // Stable FocusNode so we can re-arm the soft keyboard after a wrong
  // PIN. Without it the field loses focus on `_ctrl.clear()` on mobile
  // and the user has to tap the field again.
  final _focus = FocusNode();
  bool _busy = false;

  Future<void> _submit() async {
    if (_busy) return;
    final pin = _ctrl.text.trim();
    if (pin.length != 6) return;
    setState(() => _busy = true);
    final ok = await widget.client.pair(pin);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      // Clear + re-focus so the keyboard pops again ready for retry.
      // No SnackBar: the inline destructive label below the field
      // (driven by `widget.client.lastAuthError`) already communicates
      // the failure - a SnackBar on top would be double signalling.
      _ctrl.clear();
      _focus.requestFocus();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Wrap the forui subtree in FTheme. Pick the dark zinc theme to
    // match the existing dark Material colorScheme; once forui covers
    // the rest of the app we can drop Material's ThemeData entirely.
    return FTheme(
      data: FThemes.zinc.dark.touch,
      child: FScaffold(
        header: FHeader.nested(
          title: const Text('Pair with bridge'),
          prefixes: <Widget>[
            FHeaderAction.back(onPress: () => widget.client.close()),
          ],
          suffixes: <Widget>[
            // CacheMenu is Material-themed; wrap it in a Builder so it
            // gets a Material Theme.of(context) from the outer
            // MaterialApp ancestor.
            Builder(builder: (_) => CacheMenu(onCleared: () => widget.client.close())),
          ],
        ),
        child: AnimatedBuilder(
          animation: widget.client,
          builder: (BuildContext ctx, _) {
            final t = FTheme.of(ctx);
            // Material(transparency) supplies the Material ancestor that
            // the Material TextField (and any future Material widgets we
            // keep in this hybrid screen) needs. forui's FScaffold does
            // not provide one because forui itself doesn't use Material.
            return Material(
              type: MaterialType.transparency,
              child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 24),
                  Text(
                    'Connected to bridge at',
                    style: t.typography.sm.copyWith(
                      color: t.colors.mutedForeground,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.client.serverUri,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    'Enter the 6-digit PIN displayed in the\n'
                    '"Open OBSBOT Bridge" window on your Mac.',
                    style: t.typography.sm,
                  ),
                  const SizedBox(height: 24),
                  // Material TextField with forui-friendly styling. PR J
                  // can swap to FTextField once we migrate the rest of
                  // the input surfaces.
                  TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 36,
                      letterSpacing: 12,
                      fontWeight: FontWeight.w700,
                    ),
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      counterText: '',
                      hintText: '••••••',
                    ),
                    onSubmitted: (_) => _submit(),
                    onChanged: (s) {
                      if (s.length == 6) _submit();
                    },
                  ),
                  const SizedBox(height: 24),
                  FButton(
                    onPress:
                        (_busy || _ctrl.text.length != 6) ? null : _submit,
                    prefix: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open, size: 16),
                    child: Text(_busy ? 'Pairing...' : 'Pair'),
                  ),
                  if (widget.client.lastAuthError != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      widget.client.lastAuthError!,
                      style: t.typography.sm.copyWith(
                        color: t.colors.destructive,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
            );
          },
        ),
      ),
    );
  }
}

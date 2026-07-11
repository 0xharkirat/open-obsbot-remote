import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cache_menu.dart';
import 'ws_client.dart';

/// Pair-with-bridge screen. Enter the 6-digit PIN shown in the Mac
/// bridge window; the bridge issues a token the app reuses on every
/// reconnect.
///
/// Pure Material as of v3 (forui retired app-wide). The inline error
/// under the field carries a wrong-PIN message - deliberately friendly
/// copy, never the bridge's raw protocol hint (see CLAUDE.md #41).
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
      // The inline error below the field already communicates failure;
      // a SnackBar on top would be double signalling.
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair with bridge'),
        leading: BackButton(onPressed: widget.client.close),
        actions: <Widget>[CacheMenu(onCleared: widget.client.close)],
      ),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: widget.client,
          builder: (BuildContext ctx, _) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 24),
                  Text(
                    'Connected to bridge at',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
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
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
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
                  FilledButton.icon(
                    onPressed: (_busy || _ctrl.text.length != 6)
                        ? null
                        : _submit,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open, size: 16),
                    label: Text(_busy ? 'Pairing...' : 'Pair'),
                  ),
                  if (widget.client.lastAuthError != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      widget.client.lastAuthError!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

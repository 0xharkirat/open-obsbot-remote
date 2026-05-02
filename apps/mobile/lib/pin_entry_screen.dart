import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ws_client.dart';

class PinEntryScreen extends StatefulWidget {
  final WsClient client;
  const PinEntryScreen({super.key, required this.client});

  @override
  State<PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends State<PinEntryScreen> {
  final _ctrl = TextEditingController();
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
      _ctrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.client.lastAuthError ?? 'Wrong PIN')),
      );
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair with bridge'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => widget.client.close(),
        ),
      ),
      body: AnimatedBuilder(
        animation: widget.client,
        builder: (BuildContext context, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: 24),
              Text('Connected to bridge at',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  )),
              const SizedBox(height: 4),
              Text(widget.client.serverUri,
                  style: const TextStyle(
                      fontFamily: 'Menlo', fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 32),
              Text(
                'Enter the 6-digit PIN displayed in the\n"Open OBSBOT Bridge" window on your Mac.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _ctrl,
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
                onPressed: (_busy || _ctrl.text.length != 6) ? null : _submit,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.lock_open),
                label: Text(_busy ? 'Pairing...' : 'Pair'),
              ),
              if (widget.client.lastAuthError != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  widget.client.lastAuthError!,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

import 'connection_link.dart';
import 'qr_scan_screen.dart';
import 'ws_client.dart';

class ConnectScreen extends StatefulWidget {
  final WsClient client;
  const ConnectScreen({super.key, required this.client});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.client.loadLastServer().then((String? v) {
      if (v != null && _ctrl.text.isEmpty) {
        setState(() => _ctrl.text = v);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    // Hand-typed OR pasted into the field: both go through the link parser,
    // so pasting the full bridge link into the text box also just works.
    final parsed = parseConnectionLink(t);
    if (parsed == null) {
      await widget.client.connect(t);
      return;
    }
    _ctrl.text = parsed.hostPort;
    await widget.client.connect(parsed.hostPort, autoPin: parsed.pin);
  }

  Future<void> _applyLink(String? raw, String sourceLabel) async {
    if (!mounted) return;
    final parsed = raw == null ? null : parseConnectionLink(raw);
    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$sourceLabel is not a bridge link')),
      );
      return;
    }
    setState(() => _ctrl.text = parsed.hostPort);
    await widget.client.connect(parsed.hostPort, autoPin: parsed.pin);
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QrScanScreen()),
    );
    if (raw != null) await _applyLink(raw, 'That QR');
  }

  Future<void> _pasteLink() async {
    final data = await Clipboard.getData('text/plain');
    await _applyLink(data?.text, 'The clipboard');
  }

  bool get _canScan => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to bridge')),
      body: AnimatedBuilder(
        animation: widget.client,
        builder: (BuildContext context, _) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Bridge address',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  'Format: hostname-or-ip:port (default port 8765).\n'
                  'Find your Mac\'s IP in System Settings > Network.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _ctrl,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _connect(),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '192.168.0.10:8765',
                  ),
                  style: const TextStyle(fontFamily: 'Menlo'),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed:
                      (widget.client.socketOpen || widget.client.connecting)
                      ? null
                      : _connect,
                  icon: widget.client.connecting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(
                    widget.client.connecting
                        ? 'Connecting...'
                        : widget.client.socketOpen
                        ? 'Connected  -  waiting for camera...'
                        : 'Connect',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    if (_canScan) ...<Widget>[
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _scanQr,
                          icon: const Icon(Icons.qr_code_scanner, size: 18),
                          label: const Text('Scan QR'),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pasteLink,
                        icon: const Icon(Icons.content_paste_go, size: 18),
                        label: const Text('Paste link'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _canScan
                      ? 'Scan or paste the link from the bridge window - it '
                            'connects and pairs in one step.'
                      : 'Copy the link from the bridge window and paste it - '
                            'it connects and pairs in one step.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (widget.client.lastError != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    widget.client.lastError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

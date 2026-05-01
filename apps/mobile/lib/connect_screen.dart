import 'package:flutter/material.dart';
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
    await widget.client.connect(t);
  }

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
                  'Find your Mac\'s IP in System Settings → Network.',
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
                  onPressed: (widget.client.socketOpen || widget.client.connecting)
                      ? null
                      : _connect,
                  icon: widget.client.connecting
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(
                    widget.client.connecting
                        ? 'Connecting...'
                        : widget.client.socketOpen
                            ? 'Connected — waiting for camera...'
                            : 'Connect',
                  ),
                ),
                if (widget.client.lastError != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    widget.client.lastError!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
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

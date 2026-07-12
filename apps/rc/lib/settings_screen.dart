import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'cache_menu.dart';
import 'footer.dart';
import 'image_controls.dart';
import 'ws_client.dart';

/// Everything set-and-forget, behind the studio's gear: the selected
/// camera's image settings, its maintenance actions, the grid-overlay
/// defaults, and the connection. Dense on purpose - this is setup time,
/// not service time.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.client});

  final WsClient client;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final s = client.state;
        final multi = client.bridge.devices.length > 1;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: <Widget>[
                if (multi) ...<Widget>[
                  _label(ctx, 'Camera'),
                  _CameraSelector(client: client),
                  const SizedBox(height: 8),
                ],
                // Maintenance for the selected camera.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: () => _rename(ctx, s),
                      icon: const Icon(Icons.edit, size: 18),
                      label: const Text('Rename'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => client.runStatus(
                        s.runStatus == 'sleep' ? 'run' : 'sleep',
                      ),
                      icon: Icon(
                        s.runStatus == 'sleep' ? Icons.wb_sunny : Icons.bedtime,
                        size: 18,
                      ),
                      label: Text(s.runStatus == 'sleep' ? 'Wake' : 'Sleep'),
                    ),
                    OutlinedButton.icon(
                      onPressed: client.ptzRecenter,
                      icon: const Icon(Icons.filter_center_focus, size: 18),
                      label: const Text('Recenter'),
                    ),
                  ],
                ),
                const Divider(height: 28),
                _label(ctx, 'Image  -  ${s.displayName}'),
                ImageControls(client: client),
                const Divider(height: 28),
                _label(ctx, 'Grid overlay'),
                _GridToggles(client: client),
                const Divider(height: 28),
                _label(ctx, 'Library'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: () => _exportLibrary(ctx),
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: const Text('Export'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _importLibrary(ctx),
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Import'),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Sequences, mixes, and camera names, to move to a new Mac. '
                    'Presets live on the camera.',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const Divider(height: 28),
                _label(ctx, 'Connection'),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.link),
                  title: Text(
                    client.serverUri.isEmpty
                        ? 'Not connected'
                        : client.serverUri,
                  ),
                  trailing: CacheMenu(onCleared: client.close),
                ),
                TextButton.icon(
                  onPressed: () {
                    client.close();
                    Navigator.of(ctx).popUntil((r) => r.isFirst);
                  },
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Disconnect'),
                ),
                const AppFooter(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _label(BuildContext ctx, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 4),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
        color: Theme.of(ctx).colorScheme.primary,
        letterSpacing: 1.0,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Future<void> _rename(BuildContext ctx, DeviceState s) async {
    final ctrl = TextEditingController(text: s.friendlyName);
    final name = await showDialog<String>(
      context: ctx,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Rename camera'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(
            hintText: 'e.g. Vocal, Stage, Audience',
          ),
          onSubmitted: (_) => Navigator.of(c).pop(ctrl.text.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null) return;
    await client.renameDevice(s.deviceId, name);
  }

  Future<void> _exportLibrary(BuildContext ctx) async {
    final lib = await client.exportLibrary();
    if (lib == null) return;
    final text = const JsonEncoder.withIndent('  ').convert(lib);
    await Clipboard.setData(ClipboardData(text: text));
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text('Library copied to clipboard (${text.length} chars)'),
      ),
    );
  }

  Future<void> _importLibrary(BuildContext ctx) async {
    final ctrl = TextEditingController();
    try {
      final text = await showDialog<String>(
        context: ctx,
        builder: (BuildContext c) => AlertDialog(
          title: const Text('Import library'),
          content: TextField(
            controller: ctrl,
            maxLines: 8,
            minLines: 4,
            decoration: const InputDecoration(
              hintText: 'Paste the exported library JSON',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(c).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(c).pop(ctrl.text),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (text == null || text.trim().isEmpty) return;
      Map<String, dynamic>? decoded;
      try {
        decoded = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {
        decoded = null;
      }
      if (!ctx.mounted) return;
      if (decoded == null) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Import failed: not valid JSON')),
        );
        return;
      }
      final ok = await client.importLibrary(decoded);
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Library imported. Reconnect cameras to apply sequences.'
                : 'Import failed - not connected to the bridge.',
          ),
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }
}

class _CameraSelector extends StatelessWidget {
  const _CameraSelector({required this.client});
  final WsClient client;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedId = client.selectedDeviceId;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final d in client.bridge.devices)
          ChoiceChip(
            selected: d.deviceId == selectedId,
            onSelected: (_) => client.selectDevice(d.deviceId),
            label: Text(d.displayName),
            selectedColor: theme.colorScheme.primary,
            labelStyle: TextStyle(
              color: d.deviceId == selectedId
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurface,
            ),
          ),
      ],
    );
  }
}

class _GridToggles extends StatelessWidget {
  const _GridToggles({required this.client});
  final WsClient client;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Center crosshair'),
          value: client.gridCrosshair,
          onChanged: client.setGridCrosshair,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Attitude indicator'),
          value: client.gridCenterLines,
          onChanged: client.setGridCenterLines,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Rule of thirds'),
          value: client.gridThirds,
          onChanged: client.setGridThirds,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Pan / Tilt readout'),
          value: client.gridReadout,
          onChanged: client.setGridReadout,
        ),
      ],
    );
  }
}

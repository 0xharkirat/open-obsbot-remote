import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:obsbot_protocol/obsbot_protocol.dart';

import 'langar_theme.dart';
import 'langar_widgets.dart';
import 'local_bridge_client.dart';

/// The OBS output URL, with the token masked.
///
/// `/preview/active.mjpg` always shows the camera that is on air, so one OBS
/// Media Source replaces scene switching. The URL carries a bearer token, so
/// the window shows it masked and copies the real one only on request.
String? obsUrl(String? token, {int mjpegPort = 8766}) => token == null
    ? null
    : 'http://localhost:$mjpegPort/preview/active.mjpg?t=$token';

/// The FFmpeg options README.md and the install guide give for the Media
/// Source, so a dropped stream reconnects.
const String obsFfmpegOptions =
    'reconnect=1 reconnect_streamed=1 reconnect_delay_max=2';

class CopyField extends StatefulWidget {
  const CopyField({
    super.key,
    required this.label,
    required this.shown,
    required this.copyText,
  });

  final String label;
  final String shown;
  final String? copyText;

  @override
  State<CopyField> createState() => _CopyFieldState();
}

class _CopyFieldState extends State<CopyField> {
  bool _copied = false;
  Timer? _revert;

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    final text = widget.copyText;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    _revert?.cancel();
    _revert = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(widget.label, style: Langar.meta),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: Container(
                height: 44,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Langar.surface,
                  borderRadius: BorderRadius.circular(Langar.radiusSmall),
                  border: Border.all(color: Langar.line),
                ),
                child: Text(
                  widget.shown,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Langar.body.copyWith(fontSize: 14),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: widget.copyText == null ? null : _copy,
              icon: Icon(_copied ? Icons.check : Icons.content_copy, size: 18),
              label: Text(_copied ? 'Copied' : 'Copy'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The OBS output URL as a copy field. Shown under the fix panel as proof
/// of where OBS reads from, and inside the OBS fix as its first step.
class ObsOutputField extends StatelessWidget {
  const ObsOutputField({super.key, required this.client});

  final LocalBridgeClient client;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (context, _) {
        final url = obsUrl(client.token);
        return CopyField(
          label: 'OBS Media Source input',
          shown: url == null
              ? 'Waiting for the bridge'
              : 'http://localhost:8766/preview/active.mjpg?t=••••••••',
          copyText: url,
        );
      },
    );
  }
}

/// One row per camera: name, model and state, then ON AIR or Put on air.
///
/// Full control (pan, tilt, zoom, presets) stays in the remote. This list
/// only shows the cameras and which one OBS shows.
class CameraList extends StatelessWidget {
  const CameraList({super.key, required this.client});

  final LocalBridgeClient client;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (context, _) {
        if (!client.connected) {
          return const _EmptyRow(text: 'Waiting for the bridge.');
        }
        final devices = client.state.devices;
        if (devices.isEmpty) {
          return const _EmptyRow(
            text: 'No camera found. Connect an OBSBOT camera with a USB cable.',
          );
        }
        final active = client.state.activeDeviceId;
        return Column(
          children: <Widget>[
            for (final d in devices) ...<Widget>[
              _CameraRow(device: d, onAir: d.deviceId == active, client: client),
              const SizedBox(height: Langar.step),
            ],
          ],
        );
      },
    );
  }
}

class _CameraRow extends StatelessWidget {
  const _CameraRow({
    required this.device,
    required this.onAir,
    required this.client,
  });

  final DeviceState device;
  final bool onAir;
  final LocalBridgeClient client;

  /// The camera's state in plain words. The name line already carries the
  /// model when the camera has no friendly name.
  String get _detail {
    if (!device.connected) return 'Not connected';
    return switch (device.runStatus) {
      'sleep' => 'Asleep',
      'privacy' => 'Privacy mode',
      _ => 'Ready',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.only(left: 16, right: 8),
      decoration: BoxDecoration(
        color: Langar.surface,
        borderRadius: BorderRadius.circular(Langar.radiusSmall),
        border: Border.all(color: Langar.line),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  device.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Langar.title.copyWith(
                    color: device.connected ? Langar.ink : Langar.inkSoft,
                  ),
                ),
                Text(_detail, style: Langar.meta),
              ],
            ),
          ),
          if (onAir)
            const OnAirPill()
          else if (device.connected)
            OutlinedButton(
              onPressed: () => client.setActive(device.deviceId),
              child: const Text('Put on air'),
            ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Rename camera',
            icon: const Icon(Icons.edit_outlined, size: 20),
            onPressed: () => _rename(context),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: device.friendlyName);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename camera'),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 60,
            style: Langar.body,
            decoration: const InputDecoration(
              hintText: 'For example: Darbar, Sangat, Ragis',
            ),
            onSubmitted: (_) => Navigator.of(c).pop(ctrl.text.trim()),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // An empty name clears the friendly name; null means cancelled.
    if (name == null) return;
    await client.rename(device.deviceId, name);
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Langar.surface,
        borderRadius: BorderRadius.circular(Langar.radiusSmall),
        border: Border.all(color: Langar.line),
      ),
      child: Text(text, style: Langar.body.copyWith(color: Langar.inkSoft)),
    );
  }
}

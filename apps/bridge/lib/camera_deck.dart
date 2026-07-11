import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show
        AlertDialog,
        FilledButton,
        InputDecoration,
        TextButton,
        TextField,
        showDialog;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:macos_ui/macos_ui.dart';
import 'package:obsbot_protocol/obsbot_protocol.dart';

import 'local_bridge_client.dart';

/// The copyable OBS Browser Source URL row.
///
/// `/preview/active.mjpg` follows whatever camera is ON AIR, so one OBS
/// Browser Source pointed here replaces scene switching entirely. The
/// URL carries a bearer token; we show it masked and put the real thing
/// on the clipboard only when the user asks - the same discipline as
/// the PIN row. Before v2 the token lived only in auth.json and setting
/// this up meant a terminal; that was a product gap, not a design
/// choice.
class ObsOutputRow extends StatefulWidget {
  const ObsOutputRow({super.key, required this.client, this.mjpegPort = 8766});

  final LocalBridgeClient client;
  final int mjpegPort;

  @override
  State<ObsOutputRow> createState() => _ObsOutputRowState();
}

class _ObsOutputRowState extends State<ObsOutputRow> {
  bool _copied = false;
  Timer? _revert;

  @override
  void dispose() {
    _revert?.cancel();
    super.dispose();
  }

  String? _url(String? token) => token == null
      ? null
      : 'http://localhost:${widget.mjpegPort}/preview/active.mjpg?t=$token';

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    setState(() => _copied = true);
    _revert?.cancel();
    _revert = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final isDark = MacosTheme.brightnessOf(context).isDark;
    return AnimatedBuilder(
      animation: widget.client,
      builder: (BuildContext ctx, _) {
        final url = _url(widget.client.token);
        final masked = url == null
            ? 'Waiting for the bridge...'
            : 'http://localhost:${widget.mjpegPort}/preview/active.mjpg?t=••••••••';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: <Widget>[
              const MacosIcon(CupertinoIcons.tv, size: 16),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      'OBS Browser Source URL',
                      style: theme.typography.body.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      masked,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.subheadline.copyWith(
                        fontFamily: 'Menlo',
                        fontSize: 11,
                        color: isDark
                            ? MacosColors.systemGrayColor
                            : const MacosColor(0xff6E6E73),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Add this as a Browser Source in OBS - it always '
                      'shows the ON AIR camera, so cuts from the phone '
                      'switch OBS with no scene change.',
                      style: theme.typography.subheadline.copyWith(
                        color: isDark
                            ? MacosColors.systemGrayColor
                            : const MacosColor(0xff6E6E73),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              PushButton(
                controlSize: ControlSize.regular,
                secondary: true,
                onPressed: url == null ? null : () => _copy(url),
                child: Text(_copied ? 'Copied' : 'Copy URL'),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Per-camera rows for the bridge window: one row per attached camera
/// with status dot, friendly name, ON AIR badge, a "Put on air" action, and
/// rename. Rendered inside the home screen's group card.
///
/// The deck is a monitor + coarse control. Fine control (PTZ, presets,
/// image) stays on the phone - do not grow a second control surface
/// here.
class CameraDeck extends StatelessWidget {
  const CameraDeck({super.key, required this.client});

  final LocalBridgeClient client;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        if (!client.connected) {
          return _InfoRow(
            dot: MacosColors.systemGrayColor,
            title: 'Bridge starting...',
            subtitle: 'Waiting for the camera service to come up.',
          );
        }
        final devices = client.state.devices;
        if (devices.isEmpty) {
          return _InfoRow(
            dot: MacosColors.systemGrayColor,
            title: 'No cameras detected',
            subtitle: 'Plug an OBSBOT camera into this Mac over USB.',
          );
        }
        final active = client.state.activeDeviceId;
        final rows = <Widget>[];
        for (var i = 0; i < devices.length; i++) {
          if (i > 0) rows.add(const _InsetDivider());
          rows.add(
            _CameraRow(
              device: devices[i],
              isLive: devices[i].deviceId == active,
              client: client,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

class _CameraRow extends StatelessWidget {
  const _CameraRow({
    required this.device,
    required this.isLive,
    required this.client,
  });

  final DeviceState device;
  final bool isLive;
  final LocalBridgeClient client;

  Color get _dot {
    if (!device.connected) return MacosColors.systemGrayColor;
    return switch (device.runStatus) {
      'run' => MacosColors.systemGreenColor,
      'sleep' => MacosColors.systemOrangeColor,
      'privacy' => MacosColors.systemRedColor,
      _ => MacosColors.systemGrayColor,
    };
  }

  String get _subtitle {
    final status = switch (device.runStatus) {
      'sleep' => 'Asleep',
      'privacy' => 'Privacy mode',
      'run' => 'Running',
      _ => 'Unknown state',
    };
    final sn = device.sn.isEmpty ? '' : '  -  ${device.sn}';
    return '$status$sn';
  }

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final isDark = MacosTheme.brightnessOf(context).isDark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: _dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        device.displayName,
                        overflow: TextOverflow.ellipsis,
                        style: theme.typography.body.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (isLive) ...<Widget>[
                      const SizedBox(width: 8),
                      const _LiveBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitle,
                  style: theme.typography.subheadline.copyWith(
                    color: isDark
                        ? MacosColors.systemGrayColor
                        : const MacosColor(0xff6E6E73),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!isLive && device.connected)
            PushButton(
              controlSize: ControlSize.regular,
              secondary: true,
              onPressed: () => client.setActive(device.deviceId),
              child: const Text('Put on air'),
            ),
          const SizedBox(width: 6),
          MacosIconButton(
            icon: const MacosIcon(CupertinoIcons.pencil, size: 16),
            semanticLabel: 'Rename camera',
            onPressed: () => _rename(context),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext ctx) async {
    final ctrl = TextEditingController(text: device.friendlyName);
    final name = await showDialog<String>(
      context: ctx,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Rename camera'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(
            hintText: 'e.g. Vocal, Stage wide, Audience',
          ),
          onSubmitted: (_) => Navigator.of(c).pop(ctrl.text.trim()),
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
    // Empty string clears the friendly name; null means cancelled.
    if (name == null) return;
    await client.rename(device.deviceId, name);
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B30),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'ON AIR',
        style: TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.dot,
    required this.title,
    required this.subtitle,
  });

  final Color dot;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final isDark = MacosTheme.brightnessOf(context).isDark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: theme.typography.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.typography.subheadline.copyWith(
                    color: isDark
                        ? MacosColors.systemGrayColor
                        : const MacosColor(0xff6E6E73),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InsetDivider extends StatelessWidget {
  const _InsetDivider();

  @override
  Widget build(BuildContext context) {
    final isDark = MacosTheme.brightnessOf(context).isDark;
    return Padding(
      padding: const EdgeInsets.only(left: 36),
      child: Container(
        height: 0.5,
        color: isDark ? const Color(0x1FFFFFFF) : const Color(0x14000000),
      ),
    );
  }
}

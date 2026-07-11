import 'package:flutter/material.dart';

import '../ws_client.dart';

/// Static AppBar title: app logo + "OBSBOT Remote". Replaces the
/// previous dynamic title that displayed the camera model + SN -
/// that info now lives in [AppBarOverflowMenu]'s status row, where
/// it doesn't compete with action icons for AppBar space.
class AppBarTitle extends StatelessWidget {
  const AppBarTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Logo asset (the rc app's launcher icon). 22 px is the
        // standard AppBar leading-icon size on phones.
        ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(5)),
          child: SizedBox(
            width: 22,
            height: 22,
            child: Image.asset(
              'assets/icon-1024.png',
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
        const SizedBox(width: 8),
        const Text('OBSBOT Remote'),
      ],
    );
  }
}

/// Camera picker (v2 multi-cam). Hidden entirely with 0-1 cameras so
/// the single-camera gurdwara setup sees a pixel-identical v1 AppBar.
///
/// Two separate verbs, deliberately:
///  - tapping a camera row SELECTS it - this phone's controls (PTZ,
///    presets, image, sequencer, preview) point at it. Local only.
///  - "Put ... on air" routes the SELECTED camera to OBS. Bridge-global.
/// The operator lines up a shot on the off-air camera, then cuts.
///
/// Vocabulary: the chip says ON AIR, not LIVE. Users read "live" as
/// "the camera is on", so with both cameras running the old LIVE badge
/// looked wrong on the one that lacked it. Each row also carries a
/// status dot (green running / amber asleep / grey gone) so on/off and
/// on-air are visibly different facts. Field report from the gurdwara.
class DevicePickerMenu extends StatelessWidget {
  const DevicePickerMenu({super.key, required this.client});

  final WsClient client;

  @override
  Widget build(BuildContext context) {
    final devices = client.devices;
    if (devices.length < 2) return const SizedBox.shrink();
    final selectedId = client.selectedDeviceId;
    final selected = client.state;
    final selectedIsLive = selectedId == client.activeDeviceId;

    return PopupMenuButton<String>(
      tooltip: 'Cameras',
      icon: Icon(
        Icons.cameraswitch,
        // Amber hint when controlling an off-air camera: reminds the
        // operator their tweaks are NOT what OBS is showing right now.
        color: selectedIsLive ? null : const Color(0xFFFFB300),
      ),
      itemBuilder: (BuildContext c) => <PopupMenuEntry<String>>[
        for (final d in devices)
          CheckedPopupMenuItem<String>(
            value: 'select:${d.deviceId}',
            checked: d.deviceId == selectedId,
            child: Row(
              children: <Widget>[
                _StatusDot(device: d),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(d.displayName, overflow: TextOverflow.ellipsis),
                ),
                if (d.deviceId == client.activeDeviceId) ...<Widget>[
                  const SizedBox(width: 8),
                  const _OnAirChip(),
                ],
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'live',
          enabled: !selectedIsLive,
          child: Row(
            children: <Widget>[
              const Icon(Icons.cast, size: 18),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  selectedIsLive
                      ? "'${selected.displayName}' is on air"
                      : "Put '${selected.displayName}' on air",
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
      onSelected: (String v) {
        if (v == 'live') {
          client.makeLive(client.selectedDeviceId);
        } else if (v.startsWith('select:')) {
          client.selectDevice(v.substring('select:'.length));
        }
      },
    );
  }
}

/// Green = running, amber = asleep (still attached, wakes on cut),
/// grey = not reachable. Mirrors the Mac window's camera deck dots.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.device});

  final DeviceState device;

  @override
  Widget build(BuildContext context) {
    final color = !device.connected
        ? const Color(0xFF8E8E93)
        : switch (device.runStatus) {
            'run' => const Color(0xFF34C759),
            'sleep' => const Color(0xFFFFB300),
            'privacy' => const Color(0xFFFF3B30),
            _ => const Color(0xFF8E8E93),
          };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _OnAirChip extends StatelessWidget {
  const _OnAirChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B30),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'ON AIR',
        style: TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Grid-overlay popup menu (mesh icon). Shared between simple + advanced
/// AppBars so the toggles read identically across both modes.
class GridOverlayMenu extends StatelessWidget {
  final WsClient client;
  const GridOverlayMenu({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Grid overlay',
      icon: const Icon(Icons.grid_on),
      itemBuilder: (BuildContext c) => <PopupMenuEntry<String>>[
        CheckedPopupMenuItem<String>(
          value: 'crosshair',
          checked: client.gridCrosshair,
          child: const Text('Center crosshair'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'center',
          checked: client.gridCenterLines,
          child: const Text('Attitude indicator (steer to align)'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'thirds',
          checked: client.gridThirds,
          child: const Text('Rule of thirds'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'readout',
          checked: client.gridReadout,
          child: const Text('Pan / Tilt readout'),
        ),
      ],
      onSelected: (v) {
        switch (v) {
          case 'crosshair':
            client.setGridCrosshair(!client.gridCrosshair);
          case 'center':
            client.setGridCenterLines(!client.gridCenterLines);
          case 'thirds':
            client.setGridThirds(!client.gridThirds);
          case 'readout':
            client.setGridReadout(!client.gridReadout);
        }
      },
    );
  }
}

/// 3-dot overflow menu used by both simple + advanced AppBars.
/// Header shows the connected camera ("Tiny 2 Lite - RMOW...") as a
/// disabled status row so it doesn't take AppBar space. Below the
/// divider sit destructive actions; Disconnect is the only one today.
class AppBarOverflowMenu extends StatelessWidget {
  final WsClient client;
  const AppBarOverflowMenu({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    final s = client.state;
    final hasCamera = s.connected && s.modelDisplay.isNotEmpty;
    final statusLine = hasCamera
        ? 'Camera connected - ${s.modelDisplay}'
        : (s.connected ? 'Camera connected' : 'No camera');
    final subStatus = hasCamera && s.sn.isNotEmpty ? s.sn : null;

    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      itemBuilder: (BuildContext c) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          enabled: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                statusLine,
                style: Theme.of(
                  c,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (subStatus != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subStatus,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Menlo',
                      color: Theme.of(c).colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'disconnect',
          child: Row(
            children: <Widget>[
              Icon(Icons.logout, size: 18),
              SizedBox(width: 12),
              Text('Disconnect'),
            ],
          ),
        ),
      ],
      onSelected: (v) {
        if (v == 'disconnect') client.close();
      },
    );
  }
}

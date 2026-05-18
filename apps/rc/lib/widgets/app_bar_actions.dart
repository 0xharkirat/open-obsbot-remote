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
                style: Theme.of(c).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
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
          child: Row(children: <Widget>[
            Icon(Icons.logout, size: 18),
            SizedBox(width: 12),
            Text('Disconnect'),
          ]),
        ),
      ],
      onSelected: (v) {
        if (v == 'disconnect') client.close();
      },
    );
  }
}

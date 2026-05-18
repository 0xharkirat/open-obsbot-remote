import 'package:flutter/material.dart';

import '../ws_client.dart';

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
/// Currently just one entry (Disconnect); kept as an overflow so the
/// top bar stays icon-only and adding future destructive / housekeeping
/// actions doesn't require an AppBar re-shuffle.
class AppBarOverflowMenu extends StatelessWidget {
  final WsClient client;
  const AppBarOverflowMenu({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      itemBuilder: (BuildContext c) => <PopupMenuEntry<String>>[
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

import 'package:flutter/material.dart';

import 'mix_sequencer_screen.dart';
import 'sequencer_screen.dart';
import 'ws_client.dart';

/// One home for both sequencers: the per-camera timeline and the cross-camera
/// MIX. With a single camera there is nothing to mix, so the toggle only
/// appears once a second camera is attached.
class SequencesHub extends StatefulWidget {
  const SequencesHub({super.key, required this.client});
  final WsClient client;

  @override
  State<SequencesHub> createState() => _SequencesHubState();
}

class _SequencesHubState extends State<SequencesHub> {
  bool _mix = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.client,
      builder: (BuildContext context, _) {
        final multi = widget.client.bridge.devices.length > 1;
        // A staged video source has no presets and no per-device
        // sequencer session; only the bridge-scoped MIX applies, so the
        // "This camera" editor (and the toggle to reach it) is hidden.
        final videoSel = widget.client.state.isVideoSource;
        final showMix = videoSel || (multi && _mix);
        return Scaffold(
          appBar: AppBar(
            title: Text(showMix ? 'Mix' : 'Sequence'),
            bottom: (multi && !videoSel)
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(52),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: SegmentedButton<bool>(
                        segments: const <ButtonSegment<bool>>[
                          ButtonSegment<bool>(
                            value: false,
                            label: Text('This camera'),
                            icon: Icon(Icons.videocam, size: 18),
                          ),
                          ButtonSegment<bool>(
                            value: true,
                            label: Text('Mix'),
                            icon: Icon(Icons.movie_filter_outlined, size: 18),
                          ),
                        ],
                        selected: <bool>{_mix},
                        onSelectionChanged: (s) =>
                            setState(() => _mix = s.first),
                      ),
                    ),
                  )
                : null,
          ),
          body: SafeArea(
            child: showMix
                ? MixEditor(client: widget.client)
                : SequencerEditor(client: widget.client),
          ),
        );
      },
    );
  }
}

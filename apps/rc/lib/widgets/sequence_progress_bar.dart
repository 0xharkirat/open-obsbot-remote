import 'dart:async';

import 'package:flutter/material.dart';

import '../ws_client.dart';

/// Compact "sequence is running" banner shown above each tab body when
/// `state.sequence.running == true`.
///
/// v1.5 W1 fix #1: surface the bridge's `sequence.phase` field. The
/// bridge sends `total_s = step.seconds` (stay budget only) and
/// `elapsed_s` is the time since the stay clock started. While the
/// MotionPlanner is driving the gimbal (phase = `moving`) the bridge
/// reports `elapsed_s = 0` against the stay budget, which made the bar
/// sit empty with no indication of move progress.
///
/// This widget renders one of two states:
///
///   - **Moving**: pill reads `Moving to P3 ...`, bar fills against a
///     local timer using the current step's `transition_ms` budget
///     pulled from `state.sequence.steps`. Tinted in the secondary
///     container colour so the operator can tell at a glance which
///     phase they're in.
///   - **Holding**: pill reads `P3 - 38 s left`, bar fills against
///     `elapsed_s / total_s`. Tinted in the primary container colour.
///
/// `onStop` is optional. Simple-mode shows a stop button inside the
/// bar; the tab-shell strip leaves the stop affordance to the More tab
/// to keep the banner thin.
class SequenceProgressBar extends StatefulWidget {
  final WsClient client;
  final VoidCallback? onStop;
  final EdgeInsets margin;
  final EdgeInsets padding;

  const SequenceProgressBar({
    super.key,
    required this.client,
    this.onStop,
    this.margin = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  });

  @override
  State<SequenceProgressBar> createState() => _SequenceProgressBarState();
}

class _SequenceProgressBarState extends State<SequenceProgressBar> {
  /// Wall-clock at which the current `phase == "moving"` window began.
  /// We can't trust the bridge's `elapsed_s` here because it only ticks
  /// during `holding`. So when phase flips to moving for a given step,
  /// stamp `now` and interpolate against `transition_ms` locally.
  DateTime? _moveStartedAt;

  /// Track the (stepIndex, phase) combo we last observed so the local
  /// move timer only resets on a real phase boundary, not on every
  /// state event.
  String _lastSig = '';

  /// Ticker so the move-phase bar redraws while we wait for the next
  /// state event. The bridge sends ~2 Hz state events while moving
  /// (only on phase flips), so without this the bar would only update
  /// twice per move.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClientChange);
    _sync();
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClientChange);
    _ticker?.cancel();
    super.dispose();
  }

  void _onClientChange() {
    _sync();
    if (mounted) setState(() {});
  }

  void _sync() {
    final s = widget.client.state.sequence;
    final sig = '${s.running}::${s.stepIndex}::${s.phase}';
    if (sig != _lastSig) {
      _lastSig = sig;
      if (s.running && s.phase == 'moving') {
        _moveStartedAt = DateTime.now();
        _ticker?.cancel();
        _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (mounted) setState(() {});
        });
      } else {
        _moveStartedAt = null;
        _ticker?.cancel();
        _ticker = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.client.state.sequence;
    if (!s.running) return const SizedBox.shrink();

    final moving = s.phase == 'moving';
    final presetLabel = _presetLabelForStep(s);
    final transitionMs = _transitionMsForStep(s);

    final double pct;
    final String label;
    final Color bg;
    if (moving && transitionMs > 0) {
      final started = _moveStartedAt;
      final elapsed = started == null
          ? Duration.zero
          : DateTime.now().difference(started);
      pct = (elapsed.inMilliseconds / transitionMs).clamp(0.0, 1.0);
      label = 'Moving to $presetLabel...';
      bg = theme.colorScheme.secondaryContainer;
    } else {
      pct = s.totalS == 0
          ? 0.0
          : (s.elapsedS / s.totalS).clamp(0.0, 1.0);
      final remaining = (s.totalS - s.elapsedS).clamp(0, 9999);
      label = '$presetLabel - ${remaining}s left';
      bg = theme.colorScheme.primaryContainer;
    }

    return Container(
      margin: widget.margin,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            moving ? Icons.swap_horiz : Icons.timer,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(label, style: theme.textTheme.labelSmall),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          ),
          if (widget.onStop != null) ...<Widget>[
            const SizedBox(width: 12),
            IconButton(
              tooltip: 'Stop',
              icon: const Icon(Icons.stop_circle),
              onPressed: widget.onStop,
            ),
          ],
        ],
      ),
    );
  }

  String _presetLabelForStep(SequenceState s) {
    final idx = s.stepIndex;
    if (idx < 0 || idx >= s.steps.length) return 'P?';
    final pid = s.steps[idx].presetId;
    final presets = widget.client.state.presets;
    for (final p in presets) {
      if (p.id == pid) {
        return p.name.isNotEmpty ? p.name : 'P${pid + 1}';
      }
    }
    return 'P${pid + 1}';
  }

  int _transitionMsForStep(SequenceState s) {
    final idx = s.stepIndex;
    if (idx < 0 || idx >= s.steps.length) return 0;
    return s.steps[idx].transition.inMilliseconds;
  }
}

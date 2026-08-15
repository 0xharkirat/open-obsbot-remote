import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ws_client.dart';

/// Recording controls.
///
/// Recording is host-side: the Tiny 2 Lite has no storage, so the bridge
/// writes the file. See `docs/RECORDING_PROTOCOL.md`.
///
/// Two decisions shape this panel, both from where it gets used - one hand,
/// in a hurry, during a service.
///
/// **Tap to start, hold to stop.** The risks are not symmetric. Starting by
/// accident costs a file you delete. Stopping by accident costs the rest of
/// the take, and nobody notices until afterwards. So the cheap mistake gets
/// the cheap gesture and the expensive one has to be meant. Hold is already
/// this app's idiom for a committing action (presets are "hold to save").
///
/// **Recording is the loudest thing on the screen.** Not a small red dot in
/// a corner. An operator glancing from across a room has to be able to tell
/// whether it is running, so the whole card turns red and the clock is the
/// biggest text in the app.
class RecPanel extends StatelessWidget {
  const RecPanel({super.key, required this.client});

  final WsClient client;

  @override
  Widget build(BuildContext context) {
    final rec = client.recording;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Sticky until the next start. A take that died and then cleared its
        // own message is a take nobody knew they lost.
        if (rec.failed) ...<Widget>[
          _FailureBanner(message: rec.error),
          const SizedBox(height: 10),
        ],
        if (rec.active)
          _RecordingCard(client: client, rec: rec)
        else
          _IdleCard(client: client, rec: rec),
        const SizedBox(height: 10),
        _DiskRow(freeBytes: rec.diskFreeBytes),
        const SizedBox(height: 6),
        Text(
          'Recorded on the bridge, not the camera.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- idle

class _IdleCard extends StatelessWidget {
  const _IdleCard({required this.client, required this.rec});

  final WsClient client;
  final RecordingState rec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = client.bridge.activeDevice ?? client.state;
    final hasTarget = target.deviceId.isNotEmpty;
    // Audio lives on the bridge-global recording block, not per device. The
    // recorder is bridge-global, so a per-camera flag would be reporting a
    // setting that does not exist.
    final micAvailable = rec.audioAvailable;
    final wantAudio = rec.audioEnabled;
    final willHaveSound = wantAudio && micAvailable;
    // The floor the bridge enforces. Showing a record button that is
    // guaranteed to be refused would be a worse experience than a
    // disabled one that says why.
    const floorBytes = 5 * 1024 * 1024 * 1024;
    final lowSpace = rec.diskFreeBytes > 0 && rec.diskFreeBytes < floorBytes;
    final canStart = hasTarget && !lowSpace;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: <Widget>[
          Semantics(
            button: true,
            enabled: canStart,
            label: 'Start recording',
            child: _RecordButton(
              enabled: canStart,
              onPressed: () {
                HapticFeedback.mediumImpact();
                client.startRecording(
                  deviceId: target.deviceId,
                  audio: wantAudio,
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          Text(
            hasTarget ? target.displayName : 'No camera on air',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            lowSpace
                ? 'Not enough free space to start'
                : willHaveSound
                ? 'Will record with sound'
                : micAvailable
                ? 'Will record silent - audio is off'
                : 'Will record silent - no microphone',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: lowSpace
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A big, obvious, unmissable circle. Tap starts.
class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final red = enabled
        ? const Color(0xFFFF3B30)
        : theme.colorScheme.surfaceContainerHighest;
    return InkWell(
      onTap: enabled ? onPressed : null,
      customBorder: const CircleBorder(),
      child: Container(
        width: 92,
        height: 92,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: enabled
                ? red.withValues(alpha: 0.5)
                : theme.colorScheme.outlineVariant,
            width: 3,
          ),
        ),
        child: Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: red, shape: BoxShape.circle),
            child: Icon(
              Icons.fiber_manual_record,
              size: 34,
              color: enabled
                  ? Colors.white
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- recording

class _RecordingCard extends StatelessWidget {
  const _RecordingCard({required this.client, required this.rec});

  final WsClient client;
  final RecordingState rec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const red = Color(0xFFFF3B30);
    final device = client.bridge.deviceById(rec.deviceId);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        // Tinted fill plus a heavy border: the card itself is the
        // indicator, readable without looking directly at it.
        color: red.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: red, width: 2),
      ),
      child: Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const _BlinkingDot(),
              const SizedBox(width: 8),
              Text(
                'RECORDING',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: red,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // The number the operator actually watches. Tabular figures so
          // the clock does not jitter as the digits change width.
          Text(
            rec.elapsedLabel,
            style: theme.textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              _Chip(
                icon: Icons.videocam,
                label: device?.displayName ?? rec.deviceId,
              ),
              _Chip(icon: Icons.save_outlined, label: _bytes(rec.bytes)),
              _Chip(
                icon: rec.audio ? Icons.mic : Icons.mic_off,
                label: rec.audio ? 'Sound' : 'Silent',
                warn: !rec.audio,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _HoldToStop(
            onStop: () {
              HapticFeedback.heavyImpact();
              client.stopRecording();
            },
          ),
        ],
      ),
    );
  }
}

/// Stop needs intent. A hold with visible progress cannot happen in a
/// pocket or from a brushed thumb, and the filling bar tells the operator
/// it is working rather than ignoring them.
class _HoldToStop extends StatefulWidget {
  const _HoldToStop({required this.onStop});

  final VoidCallback onStop;

  @override
  State<_HoldToStop> createState() => _HoldToStopState();
}

class _HoldToStopState extends State<_HoldToStop>
    with SingleTickerProviderStateMixin {
  static const _hold = Duration(milliseconds: 800);
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _hold,
  )..addStatusListener((AnimationStatus s) {
    if (s == AnimationStatus.completed) {
      widget.onStop();
      _c.reset();
    }
  });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: 'Hold to stop recording',
      // A screen-reader user cannot hold a button, so give them a plain
      // activation path to the same action.
      onTap: widget.onStop,
      child: Listener(
        onPointerDown: (_) {
          HapticFeedback.selectionClick();
          _c.forward();
        },
        onPointerUp: (_) => _c.reverse(),
        onPointerCancel: (_) => _c.reverse(),
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              AnimatedBuilder(
                animation: _c,
                builder: (_, _) => FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _c.value,
                  child: ColoredBox(
                    color: const Color(0xFFFF3B30).withValues(alpha: 0.85),
                  ),
                ),
              ),
              Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    const Icon(Icons.stop, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Hold to stop',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot();

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.25).animate(_c),
      child: Container(
        width: 12,
        height: 12,
        decoration: const BoxDecoration(
          color: Color(0xFFFF3B30),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- pieces

class _FailureBanner extends StatelessWidget {
  const _FailureBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.error_outline,
            color: theme.colorScheme.onErrorContainer,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'The last recording stopped unexpectedly',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
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

/// Free space is noise until it is the only thing that matters, so it
/// stays a quiet line until it is nearly gone and then turns loud.
class _DiskRow extends StatelessWidget {
  const _DiskRow({required this.freeBytes});

  final int freeBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (freeBytes <= 0) return const SizedBox.shrink();
    const floor = 5 * 1024 * 1024 * 1024;
    const warn = 20 * 1024 * 1024 * 1024;
    final critical = freeBytes < floor;
    final low = freeBytes < warn;
    final color = critical
        ? theme.colorScheme.error
        : low
        ? const Color(0xFFD9A64B)
        : theme.colorScheme.onSurfaceVariant;
    // At roughly 2.6 Mbps the H.264 path writes about 1.2 GB an hour, so
    // hours-remaining is a more useful number to an operator than gigabytes.
    final hours = freeBytes / (1.2 * 1024 * 1024 * 1024);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(
          critical ? Icons.storage : Icons.storage_outlined,
          size: 15,
          color: color,
        ),
        const SizedBox(width: 6),
        // Flexible because the longest form of this line ("900.0 GB free
        // (days of recording)") overflows a 360px phone, and a disk warning
        // that renders as a yellow-and-black overflow stripe is worse than
        // no disk warning at all.
        Flexible(
          child: Text(
            critical
                ? '${_bytes(freeBytes)} free - too low to record'
                : '${_bytes(freeBytes)} free  ${_approxHours(hours)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: critical ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, this.warn = false});

  final IconData icon;
  final String label;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = warn
        ? const Color(0xFFD9A64B)
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.7,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: fg),
          ),
        ],
      ),
    );
  }
}

String _bytes(int b) {
  if (b >= 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(0)} MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '$b B';
}

String _approxHours(double h) {
  if (h >= 48) return '(days of recording)';
  if (h >= 2) return '(about ${h.round()} hours)';
  if (h >= 1) return '(about an hour)';
  return '(under an hour)';
}

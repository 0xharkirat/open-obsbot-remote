import 'package:flutter/material.dart';

/// Section title used at the top of each settings group on the Image /
/// Drive / More pages in the v1.4 OBSBOT Center-inspired redesign.
///
/// Layout:
/// ```
/// LABEL ?     ↺       [Coarse]
/// ```
///
/// - `label` is rendered uppercase + brand-red so the eye picks out
///   group boundaries in a long scrolling list.
/// - `tooltip` (optional) renders a small `?` icon trailing the label;
///   tap = open a one-line help tooltip. Used for things like "What is
///   Anti-flicker?" without spending vertical space on body copy.
/// - `onRefresh` (optional) renders a small circular-arrow icon to the
///   right; tap fires the callback. Used by Image-page sections where
///   the source-of-truth is the camera (Exposure / WB).
/// - `trailingPill` (optional) renders a leading badge before the
///   refresh icon (e.g. "Coarse" / "Fine" on a future joystick-speed
///   section). Stays out of the way at narrow widths via `Flexible`.
///
/// All paddings are minimal (2 px outer) so the header sits tight against
/// the section body below it.
class SectionHeader extends StatelessWidget {
  final String label;
  final String? tooltip;
  final VoidCallback? onRefresh;
  final Widget? trailingPill;

  const SectionHeader({
    super.key,
    required this.label,
    this.tooltip,
    this.onRefresh,
    this.trailingPill,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                letterSpacing: 1.0,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (tooltip != null) ...<Widget>[
            const SizedBox(width: 4),
            Tooltip(
              message: tooltip!,
              triggerMode: TooltipTriggerMode.tap,
              waitDuration: const Duration(milliseconds: 200),
              showDuration: const Duration(seconds: 4),
              child: Icon(
                Icons.help_outline,
                size: 13,
                color: theme.colorScheme.outline,
                semanticLabel: 'Help: $tooltip',
              ),
            ),
          ],
          const Spacer(),
          if (trailingPill != null) ...<Widget>[
            trailingPill!,
            const SizedBox(width: 6),
          ],
          if (onRefresh != null)
            IconButton(
              tooltip: 'Refresh from camera',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              iconSize: 16,
              color: theme.colorScheme.outline,
              icon: const Icon(Icons.refresh),
              onPressed: onRefresh,
            ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'section_header.dart';

/// Expandable group used to organize the Image / Drive / More pages
/// in the v1.4 OBSBOT Center-inspired redesign.
///
/// Header layout:
///   `[LABEL] [?]  [↺]  ────────────  [chevron]`
///
/// Tapping anywhere on the header toggles the body. The expansion state
/// is persisted across launches via SharedPreferences under
/// `section_<id>_open` so a user who collapsed Color stays collapsed
/// next time. `id` must be unique across all sections in the app.
///
/// Defaults to `defaultOpen: true`. Pass `false` for sections that are
/// rarely used (e.g. Color sliders that most operators never touch).
///
/// Optional plumbing:
///   - `tooltip`   - inline `?` icon next to the header text.
///   - `onRefresh` - small `↺` icon to the right of the header.
///                   Bridge-state-driven sections use this (Exposure / WB).
///   - `trailingPill` - badge before the refresh icon (e.g. status).
///
/// The body is wrapped in an `AnimatedSize` + `ClipRect` so the open /
/// close transition feels native instead of a jarring instant swap.
class CollapsibleSection extends StatefulWidget {
  /// Persistence key fragment. Used in SharedPreferences as
  /// `section_<id>_open`. Must be unique across the app.
  final String id;

  /// Bold uppercase label rendered in the header.
  final String label;

  /// Body shown when expanded.
  final Widget child;

  /// Default expansion state on first launch (before any user toggle).
  /// Defaults to `true`.
  final bool defaultOpen;

  /// Optional one-line help text exposed via `?` icon next to the label.
  final String? tooltip;

  /// Optional refresh icon callback (renders `↺` to the right of label).
  final VoidCallback? onRefresh;

  /// Optional pill widget shown to the right of the label (e.g. "Coarse").
  final Widget? trailingPill;

  const CollapsibleSection({
    super.key,
    required this.id,
    required this.label,
    required this.child,
    this.defaultOpen = true,
    this.tooltip,
    this.onRefresh,
    this.trailingPill,
  });

  @override
  State<CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<CollapsibleSection> {
  /// Null until prefs have loaded, then locks to a bool.
  bool? _open;

  String get _prefsKey => 'section_${widget.id}_open';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getBool(_prefsKey);
    if (!mounted) return;
    setState(() => _open = saved ?? widget.defaultOpen);
  }

  Future<void> _toggle() async {
    final next = !(_open ?? widget.defaultOpen);
    setState(() => _open = next);
    final p = await SharedPreferences.getInstance();
    await p.setBool(_prefsKey, next);
  }

  @override
  Widget build(BuildContext context) {
    final open = _open ?? widget.defaultOpen;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Header tap target wraps the whole row so the user can hit
        // anywhere - not just the chevron - to expand/collapse.
        InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(6),
          child: Semantics(
            button: true,
            expanded: open,
            label: '${widget.label} section',
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SectionHeader(
                    label: widget.label,
                    tooltip: widget.tooltip,
                    onRefresh: widget.onRefresh,
                    trailingPill: widget.trailingPill,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: AnimatedRotation(
                    turns: open ? 0.0 : -0.25, // down = open; left = closed
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.expand_more,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Body: clip + animated size so the open/close transition reflows
        // surrounding widgets smoothly.
        ClipRect(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: open
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: widget.child,
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

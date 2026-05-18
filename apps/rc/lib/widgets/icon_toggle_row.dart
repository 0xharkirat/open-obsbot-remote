import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

/// A horizontal row that pairs a leading icon + title (+ optional
/// subtitle) with a trailing FSwitch. Used in the v1.4 redesign for
/// settings rows on the Image / More pages.
///
/// Layout:
/// ```
/// [icon]  Title           ─────  [○ ⚪]
///         optional copy
/// ```
///
/// Reads better than a row of bare toggle buttons when the user has to
/// scan a long settings list. The subtitle keeps each option's purpose
/// readable without leaving the surface.
///
/// `onChanged: null` greys the switch (unsupported state).
class IconToggleRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const IconToggleRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: title,
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          // Min 48 px keeps the row at touch-target spec even when the
          // subtitle is absent.
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: <Widget>[
                Icon(
                  icon,
                  size: 20,
                  color:
                      enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: enabled
                              ? cs.onSurface
                              : cs.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                      if (subtitle != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.outline,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // FSwitch from forui keeps a single visual vocabulary
                // across the redesigned pages. IgnorePointer + the outer
                // InkWell tap lets us drive it from anywhere on the row.
                IgnorePointer(
                  child: FSwitch(
                    value: value,
                    onChange: enabled ? (v) => onChanged!(v) : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

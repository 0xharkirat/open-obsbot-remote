import 'package:flutter/material.dart';

/// Label + slider + numeric readout (+ optional inline reset icon).
///
/// Used on the Image / Color sections of the v1.4 redesign so all
/// scalar settings look identical: a fixed-width label on the left,
/// the slider stretches, a fixed-width readout follows, and a small
/// reset icon (greyed when the value is already at default) finishes
/// the row.
///
/// Pass `formatValue` to control how the trailing readout renders
/// (e.g. `'${v.round()}K'` for WB temperature, `'${v.toStringAsFixed(1)}'`
/// for EV bias). Default = `v.round().toString()`.
class LabeledSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  /// If supplied, an inline reset icon is rendered at the trailing edge.
  /// Greyed out when `value == resetTo`.
  final double? resetTo;
  final VoidCallback? onReset;

  /// How to render the trailing readout. Defaults to `'${value.round()}'`.
  final String Function(double v)? formatValue;

  /// Width of the leading label column. Default 80 px keeps four-letter
  /// labels readable (Sharpness, Contrast) without eating the slider.
  final double labelWidth;

  /// Width of the trailing readout column. Default 36 px fits a 3-digit
  /// integer; widen to e.g. 52 for `+0.0 EV` or `6500K`.
  final double readoutWidth;

  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.resetTo,
    this.onReset,
    this.formatValue,
    this.labelWidth = 80,
    this.readoutWidth = 36,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clamped = value.clamp(min, max);
    final readout =
        formatValue?.call(clamped) ?? clamped.round().toString();
    final isDefault = resetTo != null && value == resetTo;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: labelWidth,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Slider(
              min: min,
              max: max,
              divisions: divisions,
              value: clamped,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: readoutWidth,
            child: Text(
              readout,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (resetTo != null && onReset != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              iconSize: 14,
              tooltip: 'Reset to ${resetTo!.round()}',
              color: isDefault
                  ? theme.colorScheme.outline
                  : theme.colorScheme.primary,
              icon: const Icon(Icons.restart_alt),
              onPressed: isDefault ? null : onReset,
            ),
        ],
      ),
    );
  }
}

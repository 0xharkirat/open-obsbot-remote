
import 'package:flutter/material.dart';

import 'ws_client.dart';

/// Per-camera image settings for the selected camera: auto-track, view,
/// tone toggles, exposure, anti-flicker, white balance, color sliders.
///
/// Extracted from the v2 Image tab and converted to pure Material - the
/// toggles were forui `FButton.raw`, whose zinc theme fought Material
/// once already (the white-pill saga). One design system now.
///
/// These are set-and-forget: they live behind the gear in the v3
/// studio, not on the every-minute surface.
class ImageControls extends StatelessWidget {
  const ImageControls({super.key, required this.client});

  final WsClient client;

  static const int _defaultColor = 50;
  static const int _defaultFov = 86;
  static const String _defaultExposureMode = 'auto';
  static const double _defaultEvBias = 0.0;
  static const String _defaultAntiFlicker = 'off';
  static const int _defaultWbKelvin = 4700;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final s = client.state;
        final theme = Theme.of(ctx);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                ),
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Refresh from camera'),
                onPressed: () {
                  client.imageRefresh();
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(
                      content: Text('Re-read live state from camera'),
                      duration: Duration(milliseconds: 900),
                    ),
                  );
                },
              ),
            ),
            _section(theme, 'Auto-track'),
            _aiSegmented(ctx, s),
            const SizedBox(height: 16),
            _sectionWithReset(
              theme,
              'View',
              onReset: () => client.fov(_defaultFov),
            ),
            _fovSegmented(ctx, s),
            const SizedBox(height: 16),
            _section(theme, 'Tone'),
            Row(
              children: <Widget>[
                Expanded(
                  child: _toggle(ctx, 'HDR', s.hdr, () => client.hdr(!s.hdr)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _toggle(
                    ctx,
                    'Face exposure',
                    s.faceAe,
                    () => client.faceAe(!s.faceAe),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: _toggle(
                    ctx,
                    'Face focus',
                    s.faceFocus,
                    () => client.faceFocus(!s.faceFocus),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _toggle(
                    ctx,
                    'Flip',
                    s.flipH,
                    () => client.flipH(!s.flipH),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _sectionWithReset(
              theme,
              'Exposure',
              onReset: () {
                client.setExposureMode(_defaultExposureMode);
                client.setEvBias(_defaultEvBias);
              },
            ),
            _exposureSegmented(ctx, s),
            if (s.exposureMode == 'auto') _evBiasSlider(ctx, s),
            const SizedBox(height: 12),
            _sectionWithReset(
              theme,
              'Anti-flicker',
              onReset: () => client.setAntiFlicker(_defaultAntiFlicker),
            ),
            _flickerSegmented(ctx, s),
            const SizedBox(height: 16),
            _sectionWithReset(
              theme,
              'White balance',
              onReset: () {
                client.setWbAuto(true);
                client.setWbTemp(_defaultWbKelvin);
              },
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: _toggle(
                    ctx,
                    'Auto WB',
                    s.wbAuto,
                    () => client.setWbAuto(!s.wbAuto),
                  ),
                ),
              ],
            ),
            if (!s.wbAuto) _wbTempSlider(ctx, s),
            const SizedBox(height: 16),
            _sectionWithReset(
              theme,
              'Color',
              onReset: () => client.colorSet(
                brightness: _defaultColor,
                contrast: _defaultColor,
                saturation: _defaultColor,
                sharpness: _defaultColor,
              ),
            ),
            _colorSlider(
              ctx,
              'Brightness',
              s.brightness,
              (v) => client.colorSet(brightness: v),
              resetTo: _defaultColor,
              onReset: () => client.colorSet(brightness: _defaultColor),
            ),
            _colorSlider(
              ctx,
              'Contrast',
              s.contrast,
              (v) => client.colorSet(contrast: v),
              resetTo: _defaultColor,
              onReset: () => client.colorSet(contrast: _defaultColor),
            ),
            _colorSlider(
              ctx,
              'Saturation',
              s.saturation,
              (v) => client.colorSet(saturation: v),
              resetTo: _defaultColor,
              onReset: () => client.colorSet(saturation: _defaultColor),
            ),
            _colorSlider(
              ctx,
              'Sharpness',
              s.sharpness,
              (v) => client.colorSet(sharpness: v),
              resetTo: _defaultColor,
              onReset: () => client.colorSet(sharpness: _defaultColor),
            ),
          ],
        );
      },
    );
  }

  Widget _section(ThemeData theme, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
    child: Text(
      label.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.primary,
        letterSpacing: 1.0,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _sectionWithReset(
    ThemeData theme,
    String label, {
    required VoidCallback onReset,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        TextButton.icon(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            foregroundColor: theme.colorScheme.outline,
          ),
          icon: const Icon(Icons.restart_alt, size: 14),
          label: const Text('Reset', style: TextStyle(fontSize: 11)),
          onPressed: onReset,
        ),
      ],
    ),
  );

  ButtonStyle _segStyle(BuildContext ctx) {
    final cs = Theme.of(ctx).colorScheme;
    return SegmentedButton.styleFrom(
      backgroundColor: cs.surfaceContainer,
      foregroundColor: cs.onSurface,
      selectedBackgroundColor: cs.primary,
      selectedForegroundColor: cs.onPrimary,
      side: BorderSide(color: cs.outlineVariant),
    );
  }

  Widget _aiSegmented(BuildContext ctx, DeviceState s) =>
      SegmentedButton<String>(
        style: _segStyle(ctx),
        segments: const <ButtonSegment<String>>[
          ButtonSegment<String>(value: 'none', label: Text('Off')),
          ButtonSegment<String>(
            value: 'human',
            label: Text('Person'),
            icon: Icon(Icons.person),
          ),
          ButtonSegment<String>(
            value: 'group',
            label: Text('Group'),
            icon: Icon(Icons.groups),
          ),
        ],
        selected: <String>{s.aiMode},
        onSelectionChanged: (Set<String> sel) =>
            client.aiSetMode(sel.first, 'normal'),
      );

  Widget _fovSegmented(BuildContext ctx, DeviceState s) => SegmentedButton<int>(
    style: _segStyle(ctx),
    segments: const <ButtonSegment<int>>[
      ButtonSegment<int>(value: 86, label: Text('Wide')),
      ButtonSegment<int>(value: 78, label: Text('Normal')),
      ButtonSegment<int>(value: 65, label: Text('Narrow')),
    ],
    selected: <int>{s.fov},
    onSelectionChanged: (Set<int> sel) => client.fov(sel.first),
  );

  Widget _exposureSegmented(BuildContext ctx, DeviceState s) =>
      SegmentedButton<String>(
        style: _segStyle(ctx),
        segments: const <ButtonSegment<String>>[
          ButtonSegment<String>(value: 'auto', label: Text('Auto')),
          ButtonSegment<String>(value: 'manual', label: Text('Manual')),
        ],
        selected: <String>{s.exposureMode},
        onSelectionChanged: (Set<String> sel) =>
            client.setExposureMode(sel.first),
      );

  Widget _flickerSegmented(BuildContext ctx, DeviceState s) =>
      SegmentedButton<String>(
        style: _segStyle(ctx),
        segments: const <ButtonSegment<String>>[
          ButtonSegment<String>(value: 'off', label: Text('Off')),
          ButtonSegment<String>(value: '50', label: Text('50 Hz')),
          ButtonSegment<String>(value: '60', label: Text('60 Hz')),
        ],
        selected: <String>{s.antiFlicker},
        onSelectionChanged: (Set<String> sel) =>
            client.setAntiFlicker(sel.first),
      );

  Widget _evBiasSlider(BuildContext ctx, DeviceState s) {
    final theme = Theme.of(ctx);
    final txt = '${s.evBias >= 0 ? '+' : ''}${s.evBias.toStringAsFixed(1)} EV';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text('EV bias', style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Slider(
              min: -2.0,
              max: 2.0,
              divisions: 24,
              value: s.evBias.clamp(-2.0, 2.0),
              label: txt,
              onChanged: client.setEvBias,
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              txt,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wbTempSlider(BuildContext ctx, DeviceState s) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text('Temperature', style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Slider(
              min: 2800,
              max: 6500,
              divisions: 37,
              value: s.wbKelvin.toDouble().clamp(2800.0, 6500.0),
              label: '${s.wbKelvin}K',
              onChanged: (double v) => client.setWbTemp(v.round()),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              '${s.wbKelvin}K',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _colorSlider(
    BuildContext ctx,
    String label,
    int value,
    void Function(int) onChanged, {
    required int resetTo,
    required VoidCallback onReset,
  }) {
    final theme = Theme.of(ctx);
    final isDefault = value == resetTo;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Slider(
              min: 0,
              max: 100,
              divisions: 100,
              value: value.toDouble().clamp(0, 100),
              onChanged: (double v) => onChanged(v.round()),
            ),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            iconSize: 14,
            tooltip: 'Reset to $resetTo',
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

  /// 2-per-row image toggle. Material FilledButton (on = brand red) /
  /// OutlinedButton (off) - the segmented buttons above already prove
  /// this (cs.primary / cs.onPrimary) reads correctly in both themes.
  Widget _toggle(BuildContext c, String label, bool on, VoidCallback t) {
    final cs = Theme.of(c).colorScheme;
    final child = Text(
      label,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    return SizedBox(
      height: 48,
      child: on
          ? FilledButton(
              onPressed: t,
              style: FilledButton.styleFrom(
                backgroundColor: cs.primary,
                foregroundColor: cs.onPrimary,
              ),
              child: child,
            )
          : OutlinedButton(
              onPressed: t,
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.onSurface,
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: child,
            ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ws_client.dart';

/// v1.4 W4  -  preset bookmark options bottom sheet.
///
/// Replaces the silent long-press-overwrite UX. Long-pressing a SAVED
/// preset opens this sheet with four explicit actions:
///   - Update with current pose (overwrite in place)
///   - Recall instantly (no move) - bypass `client.moveDuration` so the
///     user can jump to the preset even when their default is 30 s.
///   - Rename - opens the same text-input dialog used for first-time save.
///   - Delete - destructive, calls `client.presetDelete`.
///
/// Empty-slot long-press is handled by the calling site (one-step save
/// or name prompt as appropriate). This helper is only invoked when
/// `entry != null`.
///
/// Snackbar copy is owned by the caller's `BuildContext` (we capture a
/// ScaffoldMessenger before the sheet closes so the message persists
/// after the sheet route pops).
Future<void> showPresetOptions(
  BuildContext context,
  WsClient client,
  int presetId,
  PresetEntry entry, {
  required Future<String?> Function() onRename,
}) async {
  // Capture before showing the sheet so we don't depend on a still-
  // mounted context after the route pops.
  final messenger = ScaffoldMessenger.of(context);
  final label = entry.name.isNotEmpty ? entry.name : 'P${presetId + 1}';

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'Preset $label',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.bookmark),
              title: const Text('Update with current pose'),
              subtitle: const Text('Overwrite this slot at the camera\'s '
                  'current angle and zoom'),
              onTap: () {
                HapticFeedback.heavyImpact();
                client.presetSave(presetId, entry.name);
                Navigator.of(ctx).pop();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('Updated $label with current pose'),
                    duration: const Duration(milliseconds: 1200),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.flash_on),
              title: const Text('Recall instantly (no move)'),
              subtitle:
                  const Text('Jump straight to this preset, ignore the '
                      'move duration'),
              onTap: () {
                HapticFeedback.lightImpact();
                client.presetRecall(presetId, duration: Duration.zero);
                Navigator.of(ctx).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.of(ctx).pop();
                final name = await onRename();
                if (name == null) return;
                // Save with the new name; bridge upserts by id so the pose
                // is preserved (same call path as overwrite).
                client.presetSave(presetId, name);
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('Renamed to '
                        '${name.isNotEmpty ? name : 'P${presetId + 1}'}'),
                    duration: const Duration(milliseconds: 1200),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: theme.colorScheme.error),
              title: Text('Delete',
                  style: TextStyle(color: theme.colorScheme.error)),
              onTap: () {
                HapticFeedback.mediumImpact();
                client.presetDelete(presetId);
                Navigator.of(ctx).pop();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('Deleted $label'),
                    duration: const Duration(milliseconds: 1200),
                  ),
                );
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      );
    },
  );
}

/// Default rename dialog - matches the existing `_promptName` flow in
/// `simple_mode_screen.dart`. Exposed so both surfaces can share it; the
/// sheet receives it as `onRename` callback so the caller controls the
/// initial value (current preset name vs P{id+1} placeholder).
Future<String?> showPresetRenameDialog(
  BuildContext context, {
  required String initial,
}) async {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (BuildContext c) => AlertDialog(
      title: const Text('Rename preset'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLength: 60,
        decoration: const InputDecoration(
          hintText: 'e.g. Vocalist, GGS, Audience',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(c).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

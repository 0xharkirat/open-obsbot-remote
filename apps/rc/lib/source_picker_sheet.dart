import 'package:flutter/material.dart';

import 'ws_client.dart';

/// Bottom sheet for the camera bus's "+" chip: lists every camera the
/// bridge Mac can see (`source.list`) and adds the tapped one as a
/// generic video source (`source.add`).
///
/// OBSBOT hardware and already-bound cameras are shown but disabled with
/// a one-line reason, so the operator learns why they are not addable
/// instead of wondering where their camera went.
///
/// [load] / [add] are injected (rather than taking a WsClient) so widget
/// tests drive the sheet with stub closures - same seam style as the
/// repository layers.
class SourcePickerSheet extends StatefulWidget {
  const SourcePickerSheet({super.key, required this.load, required this.add});

  /// Fetches the source list. Null = not connected or an error ack.
  final Future<List<AvailableSource>?> Function() load;

  /// Adds the tapped source. False when the bridge refused or the
  /// connection is gone.
  final Future<bool> Function(AvailableSource source) add;

  /// The live wiring: opens the sheet against [client].
  static Future<void> show(BuildContext context, WsClient client) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) =>
            SourcePickerSheet(load: client.listSources, add: client.addSource),
      );

  @override
  State<SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<SourcePickerSheet> {
  late final Future<List<AvailableSource>?> _sources = widget.load();
  bool _adding = false;

  Future<void> _add(AvailableSource s) async {
    if (_adding) return;
    setState(() => _adding = true);
    // Capture before the await: after pop() this State's context is gone.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    final ok = await widget.add(s);
    if (!mounted) return;
    navigator.pop();
    if (!ok) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not add "${s.name}"')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Add camera',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              'Cameras the bridge Mac can see.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: FutureBuilder<List<AvailableSource>?>(
                future: _sources,
                builder: (BuildContext ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final list = snap.data;
                  if (list == null) {
                    return _message(
                      ctx,
                      'Could not load cameras. Check the bridge connection '
                      'and try again.',
                    );
                  }
                  if (list.isEmpty) {
                    return _message(ctx, 'No cameras found on the bridge Mac.');
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: <Widget>[for (final s in list) _row(ctx, s)],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _message(BuildContext ctx, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Text(
      text,
      style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _row(BuildContext ctx, AvailableSource s) {
    final reason = s.obsbot
        ? 'OBSBOT camera - connects on its own'
        : (s.inUse ? 'Already added' : null);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(s.obsbot ? Icons.videocam : Icons.videocam_outlined),
      // Source names can be long ("Camo Studio Virtual Camera") - one
      // line + ellipsis keeps 320px widths safe.
      title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: reason == null
          ? null
          : Text(reason, maxLines: 1, overflow: TextOverflow.ellipsis),
      enabled: s.addable && !_adding,
      onTap: s.addable ? () => _add(s) : null,
    );
  }
}

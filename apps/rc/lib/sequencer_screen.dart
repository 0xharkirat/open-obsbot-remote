import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'widgets/sequence_progress_bar.dart';
import 'ws_client.dart';

/// Route wrapper around [SequencerEditor]. Used by Simple Mode and by the
/// v1.2 Sequence tab's "Open as full screen" path. The Sequence tab in
/// `tab_shell.dart` embeds [SequencerEditor] directly without a Scaffold.
class SequencerScreen extends StatelessWidget {
  final WsClient client;
  const SequencerScreen({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: client,
      builder: (BuildContext ctx, _) {
        final loaded = client.state.sequence.loaded;
        return Scaffold(
          appBar: AppBar(title: Text(loaded.isEmpty ? 'Sequence' : loaded)),
          body: SafeArea(child: SequencerEditor(client: client)),
        );
      },
    );
  }
}

/// Edit a sequence of preset+duration steps and start/stop it.
/// Sequence runs on the bridge so it survives phone disconnect.
///
/// This widget owns the full editor surface: library bar, running bar,
/// reorderable step list, loop-mode selector, Add/Start/Stop/Apply row,
/// and the save-as flow. It is embedded by the v1.2 Sequence tab inside
/// `tab_shell.dart`, and by the [SequencerScreen] route wrapper for
/// Simple Mode.
class SequencerEditor extends StatefulWidget {
  final WsClient client;
  /// When `true`, show an inline top bar with the library dropdown +
  /// save-as button. Defaults to `true`. Route callers can pass `false`
  /// if they already provide an AppBar with those actions.
  final bool showTopBar;
  const SequencerEditor({
    super.key,
    required this.client,
    this.showTopBar = true,
  });

  @override
  State<SequencerEditor> createState() => _SequencerEditorState();
}

class _SequencerEditorState extends State<SequencerEditor> {
  final List<_EditStep> _steps = <_EditStep>[];
  LoopMode _mode = LoopMode.forward;
  String _lastHydratedFrom = '__none__';   // signature of state we last hydrated

  /// Signature of the named library entry the editor is anchored to.
  /// Lets us tell whether the local `_steps + _mode` diverges from the
  /// SAVED entry (not from the bridge's scratch, which gets overwritten
  /// by Apply/Start). Updated only when:
  ///   1. user picks a different sequence from the library dropdown, OR
  ///   2. user successfully Updates / Saves-as via the bottom buttons.
  /// `_baselineLoaded` mirrors `state.sequence.loaded` at anchor time so
  /// we can detect dropdown changes vs. scratch echoes.
  String _baselineSig = '__none__';
  String _baselineLoaded = '';

  /// True while a recently added step is still inside its highlight
  /// + debounce window. Disables the Add step button to prevent
  /// double-fires (v1.5 W1 fix #4).
  bool _addStepBusy = false;

  /// The most-recently-added step. Used by the scroll-into-view +
  /// highlight pulse logic in [_stepCard].
  _EditStep? _justAdded;

  /// Signature for one local step list + mode. Same encoding as
  /// [_lastHydratedFrom] minus the loaded-name prefix so we can compare
  /// content irrespective of which entry it came from.
  String _sigOf(List<_EditStep> steps, LoopMode mode) {
    return '${loopModeToWire(mode)}::${steps.length}::'
        '${steps.map((e) => "${e.presetId}/${e.seconds}/${e.transition.inMilliseconds}").join(",")}';
  }

  String _currentSig() => _sigOf(_steps, _mode);

  /// True iff a saved entry is loaded AND local edits differ from it.
  bool get _dirty =>
      _baselineLoaded.isNotEmpty && _currentSig() != _baselineSig;

  @override
  void initState() {
    super.initState();
    _hydrateFromState();
    widget.client.addListener(_onClientChange);
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClientChange);
    for (final s in _steps) {
      s.secondsCtrl.dispose();
    }
    super.dispose();
  }

  void _onClientChange() {
    // If the loaded sequence name changed (user picked a different one
    // from the library) OR the state's steps differ from ours, re-hydrate.
    final s = widget.client.state.sequence;
    final sig = '${s.loaded}::${s.mode}::${s.steps.length}::'
        '${s.steps.map((e) => "${e.presetId}/${e.seconds}/${e.transition.inMilliseconds}").join(",")}';
    if (sig != _lastHydratedFrom) {
      _hydrateFromState();
    }
  }

  void _hydrateFromState() {
    final s = widget.client.state;
    final seq = s.sequence;
    // Dispose old controllers before replacing.
    for (final st in _steps) {
      st.secondsCtrl.dispose();
    }
    _steps.clear();
    if (seq.steps.isNotEmpty) {
      // Bridge already has a scratch / loaded sequence  -  show it.
      for (final src in seq.steps) {
        _steps.add(_EditStep(
          presetId: src.presetId,
          seconds: src.seconds,
          transition: src.transition,
        ));
      }
      _mode = loopModeFromWire(seq.mode);
    } else {
      // Brand new  -  seed with one default step.
      final firstId = s.presets.isNotEmpty ? s.presets.first.id : 0;
      _steps.add(_EditStep(presetId: firstId, seconds: 60));
      _mode = LoopMode.forward;
    }
    _lastHydratedFrom = '${seq.loaded}::${seq.mode}::${seq.steps.length}::'
        '${seq.steps.map((e) => "${e.presetId}/${e.seconds}/${e.transition.inMilliseconds}").join(",")}';
    // Re-anchor the dirty baseline ONLY when the loaded entry actually
    // changed (user picked a different name from the dropdown, or first
    // hydration after mount). A scratch-echo from Apply/Start keeps the
    // same `seq.loaded`, so the baseline stays pinned to the original
    // library entry and the dirty flag survives the round-trip.
    if (seq.loaded != _baselineLoaded) {
      _baselineLoaded = seq.loaded;
      _baselineSig = _currentSig();
    }
    if (mounted) setState(() {});
  }

  /// v1.5 W1 fix #4: silent appends used to confuse users into double-
  /// tapping (two cards added). Now:
  ///   - debounce for 300 ms so the second tap is a no-op
  ///   - track the new step so [_stepCard] can pulse a highlight border
  ///   - schedule a `Scrollable.ensureVisible` on the new card's key
  ///     after the next frame so the user actually sees it land at
  ///     the bottom of the list.
  void _addStep() {
    if (_addStepBusy) return;
    final fresh = _EditStep(
      presetId: _steps.isEmpty ? 0 : _steps.last.presetId,
      seconds: 60,
    );
    setState(() {
      _steps.add(fresh);
      _justAdded = fresh;
      _addStepBusy = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = fresh.cardKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: 0.9,
        );
      }
    });
    // 300 ms guard against accidental double-fires.
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _addStepBusy = false);
    });
    // Clear the highlight after the pulse animation completes.
    Future<void>.delayed(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      if (_justAdded == fresh) {
        setState(() => _justAdded = null);
      }
    });
  }

  /// Push current in-memory steps to the bridge as the active scratch.
  /// This is the editing scratch, NOT the named library. Used both by
  /// the "Apply" button (while running) and by [_start] right before
  /// telling the bridge to begin.
  void _apply() {
    final list = _steps
        .map(
          (e) => SequenceStep(
            presetId: e.presetId,
            seconds: e.seconds,
            transition: e.transition,
          ),
        )
        .toList();
    widget.client.sequenceSet(list, mode: _mode);
  }

  /// Start the sequence from the current in-memory steps. v1.5 W1 fix
  /// #3: the old "Save & start" implicitly wrote to the named library
  /// too - users were accidentally persisting throwaway scratches.
  /// Now Start only pushes to the bridge scratch; library saves go
  /// through the explicit Bookmark button.
  void _start() {
    _apply();
    widget.client.sequenceStart();
  }

  void _stop() => widget.client.sequenceStop();

  /// Silent overwrite of the currently loaded library entry. No dialog -
  /// the operator already named it when they first saved, the button
  /// label spells out the target ("Update 'Vocalist'"), so a second
  /// confirmation step is friction. Snackbar gives feedback.
  void _updateSaved(BuildContext ctx) {
    final name = widget.client.state.sequence.loaded;
    if (name.isEmpty) return;
    final list = _steps
        .map(
          (e) => SequenceStep(
            presetId: e.presetId,
            seconds: e.seconds,
            transition: e.transition,
          ),
        )
        .toList();
    widget.client.sequenceSaveAs(name, list, mode: _mode);
    setState(() {
      _baselineSig = _currentSig();
      _baselineLoaded = name;
    });
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text("Updated '$name'"),
        duration: const Duration(milliseconds: 1100),
      ),
    );
  }

  /// Save-as-new flow. Used for both "first save of a scratch" and
  /// "duplicate the loaded entry under a new name". Pre-fills with
  /// `<loaded> (copy)` when called from a loaded entry so the user
  /// doesn't accidentally type the same name and overwrite (that's
  /// what [_updateSaved] is for).
  Future<void> _saveAs(BuildContext ctx) async {
    final loaded = widget.client.state.sequence.loaded;
    final suggestion = loaded.isEmpty ? '' : '$loaded (copy)';
    final ctrl = TextEditingController(text: suggestion);
    ctrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: suggestion.length,
    );
    final name = await showDialog<String>(
      context: ctx,
      builder: (BuildContext c) => AlertDialog(
        title: Text(loaded.isEmpty ? 'Save sequence' : 'Save as new'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(
            hintText: 'e.g. Morning service, Vocalist rehearsal',
          ),
          onSubmitted: (_) => Navigator.of(c).pop(ctrl.text.trim()),
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
    if (name == null || name.isEmpty) return;
    final list = _steps
        .map(
          (e) => SequenceStep(
            presetId: e.presetId,
            seconds: e.seconds,
            transition: e.transition,
          ),
        )
        .toList();
    widget.client.sequenceSaveAs(name, list, mode: _mode);
    // Optimistically anchor baseline so the dirty flag flips off
    // immediately. _hydrateFromState will re-anchor when the bridge
    // echoes the new loaded name.
    setState(() {
      _baselineSig = _currentSig();
      _baselineLoaded = name;
    });
  }

  /// Trailing persistence icons in the bottom action row. Three cases:
  ///   * scratch (never saved): single Save (bookmark_add) -> dialog
  ///   * loaded + clean       : single Save as new (bookmark_add) -> dialog
  ///   * loaded + dirty       : Update (filled save) + Save as new
  /// The Update button only appears when there's something to update;
  /// hiding it in the clean state avoids a confusing greyed-out icon.
  List<Widget> _persistenceActions(BuildContext ctx) {
    if (_steps.isEmpty) {
      return <Widget>[
        IconButton.outlined(
          tooltip: 'Save sequence',
          icon: const Icon(Icons.bookmark_add_outlined),
          onPressed: null,
        ),
      ];
    }
    final loaded = _baselineLoaded;
    if (loaded.isEmpty) {
      return <Widget>[
        IconButton.outlined(
          tooltip: 'Save sequence...',
          icon: const Icon(Icons.bookmark_add_outlined),
          onPressed: () => _saveAs(ctx),
        ),
      ];
    }
    return <Widget>[
      if (_dirty) ...<Widget>[
        IconButton.filled(
          tooltip: "Update '$loaded'",
          icon: const Icon(Icons.save),
          onPressed: () => _updateSaved(ctx),
        ),
        const SizedBox(width: 8),
      ],
      IconButton.outlined(
        tooltip: 'Save as new copy...',
        icon: const Icon(Icons.bookmark_add_outlined),
        onPressed: () => _saveAs(ctx),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.client,
      builder: (BuildContext context, _) {
        final s = widget.client.state;
        final running = s.sequence.running;
        return Column(
          children: <Widget>[
            if (widget.showTopBar) _libraryBar(context, s),
            if (running)
              SequenceProgressBar(
                client: widget.client,
              ),
            Expanded(
              child: _steps.isEmpty
                  ? const Center(
                      child: Text('Add steps to build a sequence'),
                    )
                  : ReorderableListView.builder(
                      itemCount: _steps.length,
                      onReorder: (oldI, newI) {
                        setState(() {
                          if (newI > oldI) newI -= 1;
                          final item = _steps.removeAt(oldI);
                          _steps.insert(newI, item);
                        });
                      },
                      itemBuilder: (BuildContext c, int i) {
                        // Stable key based on step identity, not index.
                        return _stepCard(
                          c,
                          i,
                          s.presets,
                          key: ValueKey<_EditStep>(_steps[i]),
                        );
                      },
                    ),
            ),
            _modeSelector(context),
            if (running)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(
                  'Edits while running take effect at the next step boundary.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Add step'),
                        // Disabled briefly after a tap so a quick
                        // double-tap can't append two cards before the
                        // user sees the first one land.
                        onPressed: _addStepBusy ? null : _addStep,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Start / Stop is the primary action. Start no
                    // longer implicitly saves to the named library -
                    // library writes go through Bookmark below.
                    Expanded(
                      child: FilledButton.icon(
                        icon: Icon(running ? Icons.stop : Icons.play_arrow),
                        label: Text(running ? 'Stop' : 'Start'),
                        onPressed: running
                            ? _stop
                            : (_steps.isEmpty ? null : _start),
                      ),
                    ),
                    if (running) ...<Widget>[
                      const SizedBox(width: 8),
                      // Apply pushes the edited scratch to the bridge
                      // mid-run. The bridge picks up edits at the next
                      // step boundary (see CLAUDE.md note 40).
                      IconButton.outlined(
                        tooltip: 'Apply edits to running sequence',
                        icon: const Icon(Icons.refresh),
                        onPressed: _apply,
                      ),
                    ],
                    const SizedBox(width: 8),
                    // Persistence row. Two modes:
                    //   (a) loaded entry + dirty edits -> Update (filled,
                    //       silent overwrite) + Save as new (icon).
                    //   (b) scratch (never saved) OR loaded-not-dirty ->
                    //       single Save / Save as icon. Update is hidden
                    //       when there's nothing to update; the disabled
                    //       state would just confuse.
                    ..._persistenceActions(context),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _libraryBar(BuildContext ctx, CameraState s) {
    final theme = Theme.of(ctx);
    final lib = s.sequence.available;
    if (lib.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.bookmark_outline,
              size: 16,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No saved sequences yet  -  tap the bookmark to save this one.',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
      );
    }
    // v1.5 W1 fix #2: pre-select the currently loaded sequence in the
    // dropdown when one is set. DropdownButton throws if `value` is not
    // present in `items`, so guard with an explicit membership check
    // (covers the brief window after delete where `loaded` may still
    // point at a vanished entry).
    final loadedName = s.sequence.loaded;
    final loadedInLib = loadedName.isNotEmpty && lib.contains(loadedName);
    final selectedValue = loadedInLib ? loadedName : null;
    final showRunningChip = s.sequence.running && loadedInLib;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.bookmark, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              underline: const SizedBox.shrink(),
              value: selectedValue,
              hint: const Text('Load saved sequence…'),
              items: <DropdownMenuItem<String>>[
                for (final n in lib)
                  DropdownMenuItem<String>(value: n, child: Text(n)),
              ],
              onChanged: (n) {
                if (n != null) widget.client.sequenceLoad(n);
              },
            ),
          ),
          if (showRunningChip) ...<Widget>[
            const SizedBox(width: 6),
            _RunningChip(),
          ],
          if (s.sequence.loaded.isNotEmpty)
            IconButton(
              tooltip: 'Delete saved sequence',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: ctx,
                  builder: (BuildContext c) => AlertDialog(
                    title: Text('Delete "${s.sequence.loaded}"?'),
                    content: const Text(
                      'This removes the saved sequence from the bridge. The current edit stays.',
                    ),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(c).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(c).pop(true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (ok == true) widget.client.sequenceDelete(s.sequence.loaded);
              },
            ),
        ],
      ),
    );
  }

  /// On state events that include the loaded-sequence name + steps, sync
  /// the editor view. Called when user picks from the library dropdown.
  /// We compare what's loaded on bridge vs our local _steps; if different,
  /// rebuild from snapshot's presets/steps. The bridge persists the active
  /// scratch in sequence.json, but the LIST of steps comes via state.
  /// Currently the state event ships sequence.{step_index,total_s,...} but
  /// not the steps list per se  -  so we tolerate "load triggered" by
  /// listening for loaded_sequence change and pulling the current snapshot.

  /// v1.5 W1 fix #4: replaced the 3-radio ListTile column with a single
  /// segmented row. The verbose `(P1 -> P2 -> P3 -> P1 ...)` subtitles
  /// were dropped - the step list above already shows the actual chain
  /// so the parentheticals were redundant.
  Widget _modeSelector(BuildContext ctx) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              'End:',
              style: theme.textTheme.labelMedium,
            ),
          ),
          Expanded(
            child: SegmentedButton<LoopMode>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                textStyle: const TextStyle(fontSize: 12),
              ),
              segments: const <ButtonSegment<LoopMode>>[
                ButtonSegment<LoopMode>(
                  value: LoopMode.once,
                  label: Text('Once'),
                ),
                ButtonSegment<LoopMode>(
                  value: LoopMode.forward,
                  label: Text('Loop'),
                ),
                ButtonSegment<LoopMode>(
                  value: LoopMode.pingPong,
                  label: Text('Ping-pong'),
                ),
              ],
              selected: <LoopMode>{_mode},
              onSelectionChanged: (Set<LoopMode> sel) {
                if (sel.isEmpty) return;
                setState(() => _mode = sel.first);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// One step row in the sequencer editor.
  ///
  /// v1.4 fix B3: timing is split into two labelled fields so the
  /// operator can read move-time and stay-time independently. Pre-v1.4
  /// they shared one collapsed line and users misread "stay 40 s +
  /// move 30 s" as 40 s of wall-clock instead of 70 s. The trailing
  /// `≈ N s total` label gives the operator the wall-clock sum for
  /// the step (move + stay).
  ///
  /// v1.5 W1 fix #4: vertical paddings tightened so two steps fit on
  /// a typical phone viewport. Freshly-added step gets a brief tinted
  /// border via `_justAdded == step` so the user sees the append land.
  Widget _stepCard(
    BuildContext ctx,
    int idx,
    List<PresetEntry> presets, {
    required Key key,
  }) {
    final step = _steps[idx];
    final theme = Theme.of(ctx);
    final cs = theme.colorScheme;
    final presetLabel = _presetLabel(step.presetId, presets);
    final highlighted = _justAdded == step;
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: AnimatedContainer(
        key: step.cardKey,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: highlighted
              ? cs.primaryContainer.withValues(alpha: 0.4)
              : cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: highlighted ? cs.primary : cs.outlineVariant,
            width: highlighted ? 1.5 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Header: drag handle, "Step N: <preset label>", delete.
              Row(
                children: <Widget>[
                  ReorderableDragStartListener(
                    index: idx,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.drag_handle, color: cs.outline),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'Step ${idx + 1}: $presetLabel',
                      style: theme.textTheme.labelLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Delete step',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () {
                      setState(() {
                        _steps[idx].secondsCtrl.dispose();
                        _steps.removeAt(idx);
                      });
                    },
                  ),
                  const SizedBox(width: 4),
                ],
              ),
              // Preset picker: lets the operator change which preset this
              // step targets. Kept separate from the header text so the
              // header always reflects the resolved label.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: DropdownButton<int>(
                  isExpanded: true,
                  isDense: true,
                  value: step.presetId,
                  underline: const SizedBox.shrink(),
                  items: <DropdownMenuItem<int>>[
                    for (int i = 0; i < 6; i++)
                      DropdownMenuItem<int>(
                        value: i,
                        child: Text(_presetLabel(i, presets)),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => step.presetId = v);
                  },
                ),
              ),
              const SizedBox(height: 2),
              // Move row: "Move to P_X over [ duration ]"
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.timeline, size: 14, color: cs.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Move to $presetLabel over',
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    DropdownButton<int>(
                      value:
                          _snapTransitionMs(step.transition.inMilliseconds),
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      items: <DropdownMenuItem<int>>[
                        for (final p in kMoveDurationPresets)
                          DropdownMenuItem<int>(
                            value: p.duration.inMilliseconds,
                            child: Text(p.label.toLowerCase()),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => step.transition =
                              Duration(milliseconds: v));
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // Stay row: "Stay for [ N ] seconds" + trailing total.
              // Trailing total goes after "seconds" with an Expanded
              // gap and ellipsis so the row collapses gracefully at
              // 320 px without overflowing.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.timer_outlined, size: 14, color: cs.outline),
                    const SizedBox(width: 6),
                    Text('Stay for', style: theme.textTheme.bodySmall),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 56,
                      child: TextField(
                        // KEY: stable controller per step, so cursor
                        // doesn't get wiped on every parent rebuild
                        // (CLAUDE.md note #15).
                        controller: step.secondsCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 6,
                          ),
                        ),
                        onChanged: (v) {
                          final n = int.tryParse(v);
                          // Min 3 s (matches bridge contract); accept any
                          // larger value. If the user clears the field or
                          // types something < 3, the in-memory `seconds`
                          // stays at its last valid value, so the trailing
                          // total still reflects what'll be sent.
                          if (n != null && n >= 3 && n <= 36000) {
                            setState(() => step.seconds = n);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text('seconds', style: theme.textTheme.bodySmall),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          _formatStepTotal(step),
                          textAlign: TextAlign.right,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.outline,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
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

  /// Format the wall-clock total for a step as an approximate label,
  /// e.g. `≈ 70 s total` or `≈ 250 s total`. Always rendered in
  /// seconds so the operator can mentally cross-check against the two
  /// input fields (Move duration in seconds + Stay seconds). Move
  /// duration is rounded to the nearest second.
  String _formatStepTotal(_EditStep step) {
    final moveS = (step.transition.inMilliseconds / 1000).round();
    final totalS = moveS + step.seconds;
    return '≈ $totalS s total';
  }

  String _presetLabel(int id, List<PresetEntry> presets) {
    final match = presets.where((p) => p.id == id);
    if (match.isEmpty) return 'P${id + 1} (empty)';
    final name = match.first.name;
    return name.isEmpty ? 'P${id + 1}' : name;
  }

  /// The Move-duration dropdown is bound to `kMoveDurationPresets`. Saved
  /// or legacy-migrated values (e.g. 2000 ms from v1.1 default, 22000 ms
  /// from `legacy_speed_to_ms("cinema")`) may not match any preset.
  /// Snap to the closest preset so the dropdown stays valid; the bridge
  /// accepts any ms count.
  int _snapTransitionMs(int ms) {
    int best = kMoveDurationPresets.first.duration.inMilliseconds;
    int bestDiff = (best - ms).abs();
    for (final p in kMoveDurationPresets) {
      final d = (p.duration.inMilliseconds - ms).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = p.duration.inMilliseconds;
      }
    }
    return best;
  }
}

class _EditStep {
  int presetId;
  int seconds;
  Duration transition;
  late TextEditingController secondsCtrl;
  /// Per-step GlobalKey so [_addStep] can call
  /// `Scrollable.ensureVisible` on the freshly appended card.
  final GlobalKey cardKey = GlobalKey();
  _EditStep({
    required this.presetId,
    required this.seconds,
    this.transition = const Duration(milliseconds: 1000),
  }) {
    secondsCtrl = TextEditingController(text: '$seconds');
  }
}

/// Small "Running" badge rendered to the right of the library dropdown
/// when the loaded sequence is currently executing. Keeps the dropdown
/// itself uncluttered while making the running state scannable.
class _RunningChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.play_arrow, size: 12, color: cs.onPrimary),
          const SizedBox(width: 2),
          Text(
            'Running',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: cs.onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

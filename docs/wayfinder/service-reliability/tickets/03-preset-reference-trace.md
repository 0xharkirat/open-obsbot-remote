# Trace what happens to a sequence when a preset moves

`wayfinder:research` - AFK - status: **open, on the frontier**

Blocks: [Decide preset binding semantics](04-preset-binding-semantics.md)

## Question

When a preset slot is re-saved to a new position on the camera, what does an existing mix sequence actually do, in the engine and in the editor? Where exactly does the operator's report of stale presets come from?

## What is already known

The operator reports: save presets on camera 1, build a mix sequence, then re-save those same presets to different positions. The sequence still appears to point at the old ones.

Two facts established while charting:

- A cue serialises **only the slot number**: `cue_to_json` in `apps/bridge_cpp/src/device_manager.cpp` writes `preset_id`, `hold_s`, `enabled`, `fade_ms`, `move_ms`, and a camera serial only when pinned. No pose is stored.
- The engine recalls **by slot**: the mix loop calls `cmd_preset_recall(pc.preset_id, ...)`, which drives the camera to whatever that slot currently holds.

So the running engine should already follow the new position, which contradicts the report. The gap is somewhere else, and that is what this ticket finds.

## Where to look

- The sequencer editor in `apps/rc/lib/` - how a cue renders its preset. If it shows a name, a thumbnail, or coordinates captured at authoring time, the staleness is in the display and the engine is fine.
- The solver's pan-cost snapshot in `mix_replan` - it reads preset poses to score which edge to sacrifice. Confirm it re-reads on replan rather than caching from an earlier state.
- The saved-library path: `mix_sequences.json` and `library.export`. Confirm nothing captures poses at save time.
- The preset list on the client: whether it refreshes when a preset is overwritten, or holds values from the session's first read.

## Expected shape of the answer

Name the specific layer where old data survives, with the file and function. Then say which of these the operator is seeing:

1. A display-only staleness, engine correct.
2. A real engine or solver staleness.
3. Neither: the engine follows the slot correctly, and the operator expected the sequence to hold the **original framing** rather than follow the slot. That makes the report a design disagreement rather than a defect, and hands a sharp question to the ticket this blocks.

## Answer

_Unresolved._

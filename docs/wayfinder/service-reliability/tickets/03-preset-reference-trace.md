# Trace what happens to a sequence when a preset moves

`wayfinder:research` - AFK - status: **CLOSED 2026-07-24**

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

**Resolved 2026-07-24. There is no staleness anywhere. The reported symptom has a different cause: a cue pointing at an empty preset slot silently does nothing, and every layer of the product hides that from the operator.**

### What was measured

A controlled experiment against the live Tiny 2 Lite (`RMOWLHHC233LOQ`), driving the real bridge over WebSocket:

1. Parked the camera at yaw 34.8, saved it to slot 0 (P1).
2. Authored a 2-cue mix on P1 and saved it to the library as `TRACE-TEST`.
3. Moved the camera to yaw -29.9 and re-saved slot 0 there. State confirmed P1 now reports the new pose.
4. Reloaded the saved sequence. The cues on the wire were still `preset_id: 0` and nothing else. The solved plan carried the slot only.
5. Parked at neutral, then recalled P1 through the sequence.

Result: the camera landed **0.2 degrees from the new pose and 65.4 degrees from the old one**. The saved sequence followed the slot to its current position. The engine is not stale, and `mix_sequences.json` stores no pose to be stale with.

The UI half was traced independently. `_CueEdit` holds a bare `int presetId`; every label is looked up on each build from `client.bridge.devices[].presets`, which each state event replaces wholesale. No preset name or pose is captured at authoring time anywhere in the Flutter code. Pose data does reach the client on `PresetEntry`, but nothing in the mix path ever reads it.

So the answer to the ticket's question is option 3: **neither a display bug nor an engine bug**. Which sent the investigation looking for what the operator actually saw.

### The real defect: empty slots recall successfully and do nothing

The connected camera holds presets in slots **0, 2, 3** only. Recalling the empty slot 1:

```
ack: {"ok":true,"type":"ack"}
camera before yaw=-29.9   after yaw=-29.9   moved=false
```

The bridge returns **success** and the camera does not move. The mix solver planned that cue without complaint, and its only warning was about the camera count.

Now match that against the operator's own library. Every saved sequence predates 2.1 and is pinned to explicit serials:

| Sequence | Slots on `...3LOQ` | Slots on `...3QIN` |
| --- | --- | --- |
| Full House | **P2 (slot 1)**, P3 | P4, P5 |
| Full Tour | P1, **P2 (slot 1)**, P3 | P4, P5 |
| GGS Sewa | **P2 (slot 1)** | P1 |
| Stage + Ladies | **P2 (slot 1)** | P5 |

All 4 depend on P2 of the main camera, and **P2 is empty on that camera**. Running any of them leaves the camera sitting on its previous shot while the bridge reports success. To an operator watching the room, a camera that stays put when the sequence says it should have moved reads exactly as "it is still pointing at the old preset."

### Where the product hides it

- **Bridge:** recall of an empty slot returns `ok: true`. No error, no warning, no log line the operator would ever see.
- **Solver:** `mix_replan` never checks that a cue's slot exists on the camera it assigned. No warning is emitted.
- **Editor card** (`apps/rc/lib/mix_sequencer_screen.dart:396-399`): when a cue's slot is missing on the resolved camera, the Shot dropdown coerces its *displayed* value to `-1` and reads **"Hold current shot"**, while `toCue()` still emits the original slot. The card states one thing and the engine does another.
- **Run bar** (`mix_sequencer_screen.dart:880-885`): renders a bare `P2` for a slot that does not exist. The per-camera sequencer already solves this exact case at `sequencer_screen.dart:864-869` by rendering `P2 (empty)`. The mix editor has no equivalent.

### Consequences for the map

- The premise behind [Decide preset binding semantics](04-preset-binding-semantics.md) has changed. Slot-versus-pose is still a genuine question, but it is no longer the cause of anything the operator reported, so it must not be decided as a bug fix. That ticket has been rewritten around the sharper question this uncovered: what the system should do when a cue's referent is missing.
- The four saved sequences are pre-2.1 and fully pinned, so they run verbatim and never re-derive cameras. Whether they should be migrated is a decision, not a defect, and is now noted in the fog.

### Caveat on coverage

Only one OBSBOT camera was attached during this work; the library references two. Single-camera behaviour is established. The two-camera path, where the solver assigns cameras and a cue can land on a camera whose slot is empty while another camera's is not, is untested and belongs with the venue verification.

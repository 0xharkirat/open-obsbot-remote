# Decide what a cue does when its preset is missing or moved

`wayfinder:grilling` - HITL - status: **CLOSED 2026-07-24**

Unblocked by: [Trace what happens to a sequence when a preset moves](03-preset-reference-trace.md)

_Rewritten 2026-07-24. The original framing assumed stale preset data caused the operator's report. The trace disproved that and uncovered a different defect, so the question has been re-pointed at what was actually found._

## Question

A cue names a preset slot. What should happen when that slot is empty, and what should the operator see when a preset a sequence depends on has changed underneath it?

## What the trace established

- Nothing goes stale. The engine, the saved library, and the Flutter UI all reference a slot and read it live. A re-saved preset is followed correctly.
- Recalling an **empty** slot returns `ok: true` and moves nothing. The camera holds its previous shot while every layer reports success.
- All 4 of the operator's saved sequences depend on P2 of the main camera, and P2 is empty there. That silent no-op is the most likely explanation for what they experienced as "still pointing at old presets".

So the real question is not how a cue stores its target, but what the system owes the operator when that target is not there.

## What has to be decided

**1. Runtime behaviour on an empty slot.** Options, none obviously right:

- Hold the current shot and carry on, which is what happens today, only announced rather than silent.
- Skip the cue entirely and move to the next.
- Refuse to start the sequence at all, forcing the problem to be fixed before a service rather than during one.

The live context argues against anything that stops a running show, and equally against anything that stays quiet.

**2. Authoring-time visibility.** The editor should say a cue's slot is empty before the sequence ever runs. The per-camera sequencer already renders `P2 (empty)` at `sequencer_screen.dart:864-869`; the mix editor renders a bare `P2`. Adopting the existing treatment is the obvious move unless there is reason to do better.

**3. The card that lies.** At `mix_sequencer_screen.dart:396-399` a cue whose slot is missing *displays* "Hold current shot" while still emitting the original slot to the bridge. The display contradicts the behaviour. This is wrong under any decision above; what replaces it depends on decision 1.

**4. Whether the bridge should still ack success.** `preset.recall` on an empty slot returning `ok: true` is a lie at the protocol level, and every layer above inherits it. Changing it to an error is more honest but is a wire-contract change affecting existing clients.

**5. Slot versus pose, now genuinely optional.** With the reported symptom explained, freezing a cue to a pose is no longer needed to fix anything. It remains a real design choice about whether a saved sequence is a record of shots or a set of live references, and it costs the portability that slot binding buys. Worth deciding deliberately, or explicitly deferring, rather than being smuggled in as a fix.

## Answer

**Resolved 2026-07-24. A missing preset never stops the show and never stays quiet. The system warns at every point where the operator could still act, and degrades predictably when they cannot.**

The governing principle, which decided all five points: **be strict where it is free, permissive where it is expensive.** Before a sequence runs, warning costs nothing, so warn hard. Once it is running in front of a congregation, stopping costs everything, so hold and keep going.

### 1. Runtime, mid-sequence: hold the current shot and carry on, loudly

A cue whose slot is empty leaves the camera on its previous shot and the sequence continues to the next cue. This is what the code already does; what changes is that it stops being silent. The running cue is marked broken in the run bar, and the event is logged.

Rejected: skipping the cue, because the solver's crossfade pairing assumed that cue existed and removing it can cascade into same-camera transitions that cannot dissolve. Rejected: halting the sequence, because losing automation mid-diwan with no override is a worse failure than one wrong shot.

### 2. Pre-flight, at Run: warn clearly, never block

`mix.start` succeeds and returns the warnings with it. The UI shows a pre-flight banner naming the broken cue and offering to fix it, and Run stays enabled.

The reasoning is scheduling, not software: a service begins at a fixed moment and Rehras does not wait for a preset. A hard block would mean one empty slot leaves the operator with no automation at exactly the moment they have least time to fix it. They keep the choice, and the runtime behaviour above makes taking it safe.

### 3. Protocol: `preset.recall` on an empty slot returns an error

`{"ok": false, "err": "empty_preset"}` replaces today's `ok: true`. Separately, `mix_replan` checks every cue's slot against the camera's real preset list and publishes warnings into the mix state block.

Both halves are needed and they do different jobs. The error makes a **direct** recall honest, so tapping an empty P2 on the preset grid says so. The solver warnings are what power the pre-flight banner, because they are computed without moving anything. Only our own clients consume this ack, and one that ignores `err` behaves exactly as today, so the compatibility cost is a `PROTOCOL.md` entry.

### 4. The editor card must stop contradicting the engine

`mix_sequencer_screen.dart:396-399` currently coerces a missing slot's *displayed* value to `-1`, so the card reads "Hold current shot" while `toCue()` still emits the original slot. That is fixed by the decisions above rather than decided separately: the card must show the cue's real slot, marked broken. Follow the treatment the per-camera sequencer already uses at `sequencer_screen.dart:864-869` (`P2 (empty)`), and put the fix action on the row itself.

Never silently rewrite the operator's authored value to make a display consistent. Show what they wrote and say what is wrong with it.

### 5. Slot versus pose binding: deliberately deferred, not decided

With the reported symptom explained by the empty slot, freezing a cue to a pose fixes nothing that is currently broken, and it would cost the portability that slot binding buys (a sequence with no serials and no coordinates travels between rigs). It stays a live design question about whether a saved sequence is a record of shots or a set of live references, and it is explicitly parked rather than smuggled in as part of a bug fix.

### What this leaves to build

1. Bridge: `empty_preset` error on recall; solver validation of cue slots against the camera's preset list; warnings in mix state.
2. Remote: pre-flight banner on Run; broken-cue marking in the editor and run bar; remove the display coercion.
3. Docs: the new error and the warning semantics in `PROTOCOL.md`.

The UI treatment for points 2 draws on the three-tier escalation pattern recorded in [the Mobbin research](../../ui-ux-research/mobbin-findings.md): count the problem in the header, border the offending card, name the exact missing preset in the detail, and never disable the primary action.

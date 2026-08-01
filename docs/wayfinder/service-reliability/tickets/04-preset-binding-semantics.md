# Decide what a cue does when its preset is missing or moved

`wayfinder:grilling` - HITL - status: **open, on the frontier**

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

_Unresolved._

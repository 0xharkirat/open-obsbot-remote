# Decide preset binding semantics for cues

`wayfinder:grilling` - HITL - status: **open, blocked**

Blocked by: [Trace what happens to a sequence when a preset moves](03-preset-reference-trace.md)

## Question

Should a cue bind to a preset **slot**, so it follows the camera as the operator re-frames that preset, or to a **pose**, frozen at the moment the sequence was authored?

## Why it is a real question

Today a cue stores a slot number and nothing else, so it follows the camera. That is defensible: re-frame P1 for a differently arranged hall and every sequence that uses P1 quietly adapts.

It is also the opposite of what the operator seems to expect. Their report reads as a saved sequence being a **record of shots**, where re-pointing P1 for some other purpose should not silently rewrite a sequence built weeks earlier for a service.

Both readings are coherent, they cannot both be the default, and the choice decides:

- Whether saved sequences stay portable between rigs. Slot binding is exactly what made them portable, since no serial numbers or coordinates travel with the file.
- What the editor must show, and what it must warn about when a preset a cue depends on has moved.
- Whether a pose-bound cue needs a way to re-capture from the current camera position.

## Options to weigh

1. **Slot binding, made visible.** Keep today's behaviour, and make the editor honest about it: show that a cue follows the live preset, and surface when that preset has moved since authoring.
2. **Pose binding.** Cues capture coordinates at authoring time, with an explicit re-capture action. Costs portability and adds a stale-pose problem of its own when a camera is physically moved.
3. **Per-cue choice.** Both, selectable. Most capable, most machinery, and a new concept the operator has to hold in their head.

The answer should also settle what the editor shows when the two diverge, since that is where the surprise actually happened.

## Answer

_Unresolved._

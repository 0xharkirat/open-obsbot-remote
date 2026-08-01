# Gather frame-drop evidence on the mini

`wayfinder:task` - HITL - status: **open, on the frontier**

Blocks: [Decide the frame-drop mitigation](02-frame-drop-mitigation.md)

## Question

Where do the dropped frames originate: the camera and its USB path, the mini's load, or our capture path?

Nothing can be decided about mitigation until this is answered, and it cannot be answered from the dev machine.

## Why this is a task, not a decision

The same camera on the dev MacBook streams perfectly: 25 fps, 0 ms jitter, zero gaps over 250 frames, 10.8% bridge CPU. The operator reports drops on the mini, and reports them **also when OBS reads the camera directly with the bridge out of the loop**. Two independent observations put the fault in the mini's environment rather than in our code or the camera itself, but "the environment" is three different suspects and they need separating before anything is designed.

## Checklist for the operator, on the mini

No installs required. Each item names what its result would prove.

- [ ] **OBSBOT Center preview**, camera connected, nothing else running. Drops visible here put the fault upstream of everything we build: camera, cable, port, or firmware. A clean preview here clears the camera.
- [ ] **OBS > View > Stats** during a real service. Record "Frames missed due to rendering lag" and "Skipped frames due to encoding lag". Nonzero and climbing means the mini's CPU is the bottleneck, and the camera is fine.
- [ ] **Idle versus load.** Watch the preview with OBS idle, then while OBS is streaming or recording. Drops only under load confirm resource starvation. Drops in both point at USB or hardware.
- [ ] **Mini model and specs.** Apple Silicon or Intel, which chip, how much RAM.
- [ ] **USB topology.** Camera straight into the mini, or through a hub? Anything else bandwidth-heavy on the same bus: a capture card, an external SSD being recorded to?
- [ ] **Thermals.** Is the mini enclosed in a cabinet or rack during services?

## Answer

_Unresolved._

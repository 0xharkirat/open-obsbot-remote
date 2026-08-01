# Decide the frame-drop mitigation

`wayfinder:grilling` - HITL - status: **open, blocked**

Blocked by: [Gather frame-drop evidence on the mini](01-mini-frame-drop-evidence.md)

## Question

Given what the evidence says, what changes: our code, the venue's setup, or the documented expectations?

## Shape of the decision

The answer branches on the evidence, and the branches want different things:

- **If drops appear only under streaming load** the mini is resource-starved, and the lever is ours. Candidates: capture at a lower resolution or frame rate when the host cannot keep up, expose that as an operator setting, or pick it automatically. Each trades picture quality for stability, and how much to trade is a judgment call the operator has to make, not the code.
- **If drops appear with OBS idle** the fault is USB, cable, port, or hub, and the answer is a setup change rather than a code change. The decision then is what we do about it in software: detect and warn, or document a required topology.
- **If drops appear in OBSBOT Center too** the camera or its firmware is the source, and the decision is what we can do about a fault upstream of us.

A real option in every branch is **change nothing in code and write down the requirement**. Adaptive capture is machinery, and machinery that fires on the wrong signal makes the picture worse for no reason.

## Answer

_Unresolved._

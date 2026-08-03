# Decide the Live screen layout

`wayfinder:grilling` - HITL - status: **open, on the frontier**

## Question

How do a preview, the camera bus, the presets, the framing controls, and TAKE share one phone screen, when today half of them are hidden behind a toggle?

## What is there now

The Live screen stacks a top strip, a large preview of the staged camera with the on-air camera in a small picture-in-picture, a horizontal bus of camera chips, then **either** the 6 preset tiles **or** the framing panel (joystick, zoom rocker, speed control) depending on a Frame toggle, and finally an action bar holding that toggle, the crossfade controls, and TAKE.

The toggle exists because a phone cannot fit both. That was a reasonable compromise; it is also the thing the operator has to think about at the wrong moment.

## What has to be decided

- **Whether the toggle survives at all.** The [Mobbin research](../../ui-ux-research/mobbin-findings.md) records a bottom-sheet pattern where a video shrinks but is never covered while controls sit below it, which would let presets and framing coexist without a mode switch. Whether that is better than the toggle here, on a phone held one-handed, is the decision.
- **What is always visible versus what is a drag away.** The preview and TAKE are non-negotiable. Everything else is arguable, and the answer should be driven by what an operator touches during a service rather than by what fits.
- **How much of the screen the preview deserves.** It is how the operator judges framing, and installability reclaims roughly the height of an address bar, which has to be spent somewhere.
- **Whether the picture-in-picture is the right way to show what is on air**, or whether program deserves more than a thumbnail given that it is the thing the congregation sees.
- **The control cluster's shape.** Crossfade toggle, crossfade length, glide speed, and PTZ speed are currently a toggle, a popup menu, a chip row, and a segmented control: four interaction models for four settings of the same kind. The research suggests collapsing them into uniform rows of segmented pills.
- **What happens in landscape**, which an operator may well hold when framing, and which the current design does not consider.

## Constraints that should decide ties

The operator's eyes are on the room. A control that must be looked at to be found is worse than one that is bigger and dumber. Nothing about a wrong tap here is undoable, because the frame has already reached the congregation.

## Answer

_Unresolved._

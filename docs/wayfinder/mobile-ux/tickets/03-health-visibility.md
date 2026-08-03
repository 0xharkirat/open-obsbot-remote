# Decide how the operator knows the system is healthy

`wayfinder:grilling` - HITL - status: **open, on the frontier**

## Question

At a glance, without tapping anything, how does the operator know the bridge is connected, the cameras are alive, the preview is moving, and what OBS is actually receiving?

## Why this matters more than it looks

The [Mobbin research](../../ui-ux-research/mobbin-findings.md) named this the single highest-value finding of the first pass: **a silently frozen preview is the failure most likely to put a wall on air**, and nothing in the interface today would reveal it. A frozen MJPEG frame looks exactly like a still shot of a quiet hall.

The reliability map has since fixed several causes of exactly that, and the fixes are invisible by design. This ticket is about the other half: making the operator able to tell.

There is a second case with the same shape. The phone can lose its WebSocket while the UI continues to look completely normal, so the operator taps, nothing happens, and they tap again. Research recorded the answer other apps use: desaturate the whole control surface and blank the readouts the instant the connection is unconfirmed, rather than optimistically showing the last known values.

## What has to be decided

- **What is shown continuously, and where.** Live apps use a persistent status strip rather than a screen the operator has to visit. What belongs in it: bridge reachable, each camera present, frames arriving, whether a sequence is running.
- **How it reads.** The research is clear that a qualitative verdict beats numbers here: `Preview: Live / Stale / Stopped` rather than a frame rate. Colour plus a glyph, so it survives a glance and colour blindness.
- **What happens when control is lost.** Whether to desaturate and disable, and how quickly, balancing a brief Wi-Fi hiccup against a genuinely dead socket.
- **Whether the phone should say anything about OBS.** The bridge knows whether anything is pulling `active.mjpg`. The operator currently learns that OBS stopped receiving only by looking at OBS.
- **How loud a failure gets to be.** Haptics and sound are available. A camera dying on air is worth interrupting for; a brief reconnect is not.

## Answer

_Unresolved._

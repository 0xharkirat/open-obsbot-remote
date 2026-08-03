# Decide the pairing and first-run journey

`wayfinder:grilling` - HITL - status: **open, on the frontier**

## Question

What happens between a volunteer picking up a phone and having working control of the cameras, the first time and every time after?

## What exists now

The bridge shows a 6-digit PIN and a QR code for 60 seconds after Reveal is pressed. The QR carries a connection link with the PIN in the URL fragment, so scanning it opens the web remote already paired. There is also Copy link, and a manual path where the operator types an address and a PIN.

That covers the happy path competently. The journey around it is undesigned:

- The QR is on the bridge's screen. Someone has to be at the Mac, and someone else has to have a phone, at the same moment.
- After a successful pair the app lands on the Live screen with no orientation at all.
- A returning operator a month later has a stored token, but nothing tells them whether it is still good until they try.
- Every failure looks the same. A wrong PIN, the wrong Wi-Fi, a bridge that is not running, and a camera that has not enumerated are four different problems with four different fixes.

## What has to be decided

- **Which path is primary**, and how the others are ranked visually. Scanning is fastest when two people and two screens are available; typing is the fallback that always works.
- **Whether the app can find the bridge itself.** Other local-network products discover devices rather than asking for an address. Whether that is worth building here, and what it would show when it finds nothing.
- **How failures are told apart.** Each of the four cases above needs its own message and its own next step, in the operator's language rather than the protocol's.
- **What the first successful run should teach.** The operator has a paired phone and no idea what TAKE does. Whether anything is taught at all, and if so how it stays out of the way of someone who already knows.
- **Whether the install prompt belongs in this journey**, and where. It cannot be first, because the operator wants to work; it cannot be never, because a bookmarked tab is the thing being replaced. Depends on [the install journey](05-install-journey.md).
- **The returning case, which is the common one.** Opening the app should confirm it still works before the operator needs it to, rather than at the moment they reach for a control.

## Constraint

This may be done once a month, by someone who is not technical, possibly on a borrowed phone, in a hall, shortly before a service starts. Nothing here can assume an account, an internet connection, or a second attempt.

## Answer

_Unresolved._

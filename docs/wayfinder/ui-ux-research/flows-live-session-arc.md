# Flow research: the arc of a live session

Gathered 2026-08-02 for the [Mobile Operator Experience map](../mobile-ux/map.md). Nine multi-step flows examined from their images, plus a set of device-offline screens. Every claim links its source.

The question: not what one screen looks like, but what the journey is from arriving at the venue to the service being over.

## The standout: a rehearsal is a first-class step

Whatnot tracks **"Rehearse going live"** as a tracked, unlockable item in its pre-show checklist ([rehearsal flow](https://mobbin.com/flows/755fb39e-e5e8-4644-9a8d-cab36f103e9a), [checklist](https://mobbin.com/screens/353c0e91-ee2f-4a75-9d3f-58e13619cde9)), and elsewhere in the same app it makes the no-consequence promise in one sentence: **"Practice Swiping. You won't be charged this time."** ([source](https://mobbin.com/screens/a9900d88-895e-4dab-8075-51100bbda25c)).

This matters here more than it does for Whatnot. A gurdwara rotates sevadars, so somebody is operating for the first time most weeks, and there is no way to learn what a TAKE feels like except to do one. A rehearsal state where PTZ, presets, and TAKE all work but nothing reaches `active.mjpg` would be the single highest-value addition to the arc.

## Going live, and coming back

| Pattern | Source | Why it fits |
| --- | --- | --- |
| **The commit control MOVES when the session goes live.** `Go LIVE` sits bottom-centre; at the transition it vanishes and `Stop` appears top-left, in the slot the close button used to hold. The two are never on screen together. | [X, completing a live stream](https://mobbin.com/flows/cd56d1ad-4054-4ced-84a0-6295520fbe82) | An operator whose eyes are on the hall reaches by memory. A guarantee that a position always means one thing, and changed position when the mode changed, beats any confirmation dialog. |
| Two verbs with different blast radii get different distances: "leave" is one circular tap on the panel, "end" costs a menu, a red row isolated at the bottom, then a Cancel/End alert. | [Telegram, ending a live stream](https://mobbin.com/flows/f71d32a7-18f1-4ec4-a642-53492ab09f15) | Putting the phone down, backing out, or losing the socket must never be confusable with ending the service. |
| A readiness checklist where one row is obviously not green, including physical checks the app cannot perform: "Check your tech - Make sure your phone is fully charged or plugged in." | [Whatnot, scheduling a show](https://mobbin.com/flows/1a0ea71f-2cb0-4d1d-ad04-cc8df90f91a9) | Right register for ten minutes before diwan. But Whatnot GATES on it with padlocks, and we must not: the service starts at its time whether or not the second camera enumerated. |
| The operator commits from inside the finished cockpit - the pre-show room already shows the feed and chat, with one pinned `Start Show` button - rather than from a setup screen they then leave. | [Whatnot, preview and go live](https://mobbin.com/flows/984a6d2a-7c59-40da-9ea6-82e1d923d21b) | No context switch at the riskiest moment. |
| An announcement pinned as a single collapsed line with a chevron, persisting without consuming the screen. | [Azar, starting a live stream](https://mobbin.com/flows/13c15111-f2ce-441a-99e9-b41d05351464) | A model for persistent status that does not cost layout. |
| Capabilities that are currently off render with a **slash through the icon**, readable at a glance. | [Yubo, live controls](https://mobbin.com/flows/4163f7ce-a8e2-4c11-b762-204638564736) | Applies directly to a camera that is asleep or unreachable. |

## When something breaks mid-session

The best prompt found, and the reason it works:

> **"Get back to your Space?"** ... "You were just disconnected from the Space you were hosting. Do you want to reconnect?" ... **"This Space will automatically end in 46 seconds."**
> Primary: `Reconnect to Space`. Below it in red: `End Space`.
> [X Spaces, reconnecting](https://mobbin.com/flows/d6fa260b-3f2b-46e2-848b-c4f03e1af99a)

Three things it does: names the consequence, puts a **running deadline** on the decision, and offers two named outcomes rather than OK/Cancel. Contrast [DAZN's error explainer](https://mobbin.com/flows/6e1d2018-4095-496a-b239-aa81699087f6), which educates with troubleshooting bullets and a LEARN MORE button but never says what happens if you ignore it.

**Attribute failure per device, never as a takeover.** [Starlink](https://mobbin.com/screens/a79e31e4-17b1-4ae9-a9c7-1bc3239b3f83) changes its hero to "Disconnected", states "The Starlink app can't reach your Starlink", and then gives **every dependent row its own reason**: "Statistics: Starlink unreachable", "Network: Router unreachable". Our failures are per-camera, so C2 losing USB while C1 is live must be one card going grey, not a full screen.

**Faults persist, they do not toast.** [LARQ](https://mobbin.com/screens/6b859147-a151-4dd4-b92e-9e8e5fd0ae81) keeps "OFFLINE" on the device card **and** a red banner pinned to the bottom until resolved. Our operator will be mid-seva when a fault fires and will never see a 3-second snackbar.

Worth noting: every other device-offline pattern surveyed is a **full-screen takeover** - [Hue "No Bridge found"](https://mobbin.com/screens/33c875bb-1b3c-4e08-8457-64e04e1ba387), [Eight Sleep](https://mobbin.com/screens/bb976239-e92e-4ab6-bc78-d1e5a7e57607), [Alexa](https://mobbin.com/screens/a50fe432-f4cf-447a-8669-46546338f126), [Fitbit](https://mobbin.com/screens/5becafee-af2f-4621-87fc-e3863b2d36d4), [Tonal](https://mobbin.com/screens/ea593c8a-c8d0-4f0e-b103-f59537038a8c). Fine when nothing is live. Fatal mid-service, because it hides the preview and TAKE behind troubleshooting text.

## Configuring a transition

[Spotify's transition editor](https://mobbin.com/flows/fea67c7b-984c-4fb3-955e-3a201e3f5d0d) puts a chip **on the join between two tracks**, inline in the list, showing the current setting ("Auto", "Custom", "No transition"). Behind it: named presets `Auto / Fade / Rise / Blend / Custom` with the parameters visible. When a mix is impossible it says so with the remedy attached.

Our cut-versus-crossfade choice belongs on the C1 to C2 relationship in the sequence list, not in a global settings page. And the first-take case (no outgoing frame to dissolve from) should name its fallback the way Spotify names why two tracks cannot be mixed.

## Rejected, with reasons

These serve a solo streamer performing TO a camera. Our operator directs cameras AT other people, which inverts several of them.

- **The 3-2-1 countdown** ([Instagram](https://mobbin.com/flows/d884a5eb-2d76-4919-8830-3e930501f13e)). A beat for a performer to compose their face. Our operator gains nothing, cannot use it, and its only escape is "Cancel" with no "go now".
- **Engagement coaching in the live view** (Whatnot's "Grow your audience", Azar's "If you read the chat, the users will stay longer!", Yubo's "We're telling your friends to join"). All of it pulls the eyes to the phone, which is the exact failure being designed against. There is no audience to farm.
- **Vanity end-of-session summaries** (Azar's Stars Earned, HP tier, New Followers). The operator's definition of success is that nobody noticed them; grading seva on viewer counts is meaningless and mildly disrespectful. Keep the SHAPE of Azar's Live History - date, time range, duration, expandable - and drop every audience metric.
- **Theater Mode as shipped** (X's "Hide everything except video"). Built so a performer can admire their output. The inversion is what we want: hide the video chrome, keep the controls reachable.
- **Mandatory taxonomy before going live** ([Yubo's forced "Tag this live"](https://mobbin.com/flows/4366d393-c7af-49bc-bcbc-affcb6908406)). Any required step between the operator and going live is a hazard on a clock.
- **Per-session editorial setup** (Azar's cover image, title, greeting, announcement). Constant across every service here; asking weekly guarantees it gets skipped and then goes stale.
- **Destructive options adjacent to routine ones** (Instagram's "Discard video" one row above "Share"). The end of a session is when the operator is least attentive.

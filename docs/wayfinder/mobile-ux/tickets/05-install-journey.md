# Decide the install journey, per platform

`wayfinder:grilling` - HITL - status: **retired 2026-08-02, out of scope**

Unblocked by [ticket 01](01-installable-without-cache-poisoning.md), which rewrote its premise, and then retired the same day by the operator's call: installability is not being pursued at all.
**A browser tab is the target, not a fallback**, and the flow that replaces this ticket is [Chart the end-to-end mobile browser flow](06-mobile-browser-flow.md).

Two things below survived the retirement and moved rather than died.
The tab-hardening items (`overscroll-behavior`, safe areas) became browser-layer hazards B1 and B2 in ticket 06, where they belong, since they were never install work.
The "how does an operator get back to the app next week" problem became **Stage 0** of ticket 06, and its answer is a stable mDNS name rather than an icon.

The rest is kept unedited below as a record of what was being weighed, in case HTTPS ever becomes viable and this reopens.

---

## Question

How does the app get onto a phone's home screen, who is asked, when, and what happens to everyone who cannot or never does?

## What ticket 01 settled, so this ticket does not relitigate it

- **Service workers are impossible on this origin.** Not risky, impossible. Everything in the old ticket about caching strategy and the icon-font incident is moot.
- **Android cannot install.** Add to Home Screen produces a Chrome bookmark that launches with full browser UI. Every HTTPS workaround was examined and rejected.
- **iOS very likely can**, chrome-free, with no manifest strictly required on Safari 26 and a manifest or `apple-mobile-web-app-capable` on earlier versions.
- **The mechanism is decided:** manifest plus Apple meta tags, `--pwa-strategy=none` retained.

So this is no longer one journey. It is two, and the interesting design problem moved from "how do we prompt" to **"how do we tell two platforms apart without making the Android operator feel handed the lesser thing"**.

## What has to be decided

### The iOS journey

- **When the teaching moment happens.** Not first load - the operator came to work. Probably after a first completed session, when the app has earned the ask. Ticket 04 owns first run, so these two must agree on who owns the first five minutes.
- **How to teach a gesture that cannot be triggered.** Add to Home Screen is buried in the share sheet and no API can open it. This is instructional design, and it is the hardest part of the ticket. [The pairing research](../../ui-ux-research/flows-pairing-first-run.md) found the shape that works: show a picture of the physical thing, name the exact control, gate on an observable fact rather than a spinner.
- **The re-pairing consequence, which is the thing most likely to be read as a bug.** An installed iOS web app gets a storage jar separate from Safari, so the saved token does not carry over and the PIN must be entered once more. Decide whether to warn before installing, explain at the moment it happens, or make the bridge briefly re-reveal the PIN because it knows an install just occurred. Silence is not an option; a volunteer who installs and is thrown back to a PIN screen will conclude the install broke it.
- **Whether the bridge helps.** It is already showing a QR to a person holding a phone. That is the ideal moment to say "add this to your home screen" on the Mac's screen rather than the phone's, and it sidesteps the teaching problem entirely for anyone pairing fresh.

### The Android journey

- **Whether to offer anything at all.** A bookmark that opens in Chrome is not nothing - the icon is real and the URL stops having to be typed, which is worth something in a hall. But calling it "Install" would be a lie. Decide between offering it honestly under a different verb, offering the APK, or staying silent.
- **Whether to surface the APK, and from where.** It could be served from the bridge's own web root, so the download works with the venue's internet down. That makes the bridge a software distributor, which has consequences for signing, versioning against the running bridge, and what happens when the two disagree.
- **How not to make it feel second class.** [Wispr Flow's framing](https://mobbin.com/sites/sections/ddc48c4a-43de-4cdc-89f0-791148ca1b3e) is the model: posture rather than capability, never implying one client is lesser.

### Both

- **Whether the design assumes standalone and degrades in a tab, or targets the tab and improves in standalone.** Given Android is permanently a tab, **the tab is the baseline** and standalone is the enhancement. This looks close to decided already; confirm it and write it down.
- **What the tab gets regardless.** `overscroll-behavior: none` and `viewport-fit=cover` are not install work, they are the hardening that makes the tab tolerable, and they fix live hazards today - pull-to-refresh currently drops the WebSocket mid-shot. Decide whether these ship ahead of this ticket rather than waiting on it.
- **How an installed or bookmarked copy notices a new build.** The version now shows in the footer, which makes a stale build visible but does nothing about it. With no service worker there is no update mechanism at all beyond a reload, so the answer is probably: the app compares its version to one the bridge reports over the socket it already holds, and offers a reload. Cheap, and it works identically on both platforms.
- **What happens to people who never install.** A shared or borrowed phone must not be nagged. Decide the suppression rule and where the dismissal is remembered, noting that on a borrowed phone it will not be remembered for long.

## Answer

_Unresolved._

# Flow research: authoring something reusable, and recovering when it breaks

Gathered 2026-08-02 for the [Mobile Operator Experience map](../mobile-ux/map.md). Eleven flows examined from their images. Two halves: building a sequence for a service never run before, and discovering mid-service that a camera has gone.

## Half A: authoring

### Templates, not a blank canvas

Hue's automations empty state does not open a builder. It opens **six worked examples** with `Custom` demoted to seventh: *Wake up with light*, *Go to sleep*, *Coming home*, *Leaving home*, *Mimic presence*, *Timer* ([flow](https://mobbin.com/flows/277236d6-4e99-48a0-9dc9-f90bf476ede8)). Each card is a photograph of the outcome and a one-line description, so the user picks **by result, not by mechanism**.

Its empty-state copy teaches with two fully specified examples rather than abstractions: "turn on the bedroom at full brightness in the morning or shut off the entire house at bedtime, for example."

Ours would be: *Two-camera alternate*, *Wide on kirtan, close on the reader*, *Slow drift on one camera*, *Hourly wide reset*, then *Custom*. Templates are shipped JSON, fully local. This is the highest-leverage change for someone building a sequence for an unfamiliar service.

Tonal has the best empty-state copy found anywhere ([flow](https://mobbin.com/flows/d2cdceb2-e6d1-4e36-8db5-bcaf13afa3dd)):

> **Create your own!** / Choose your moves. / Add reps, sets, and more. / Name it. Save it. **Play it on repeat.**

Four sentences describing the whole lifecycle including the payoff.

### The affordance our sequencer most obviously lacks

SmartThings puts a floating pill in the editor: **"▶ Test routine actions"**, with a small orange caveat directly above it ([editor](https://mobbin.com/screens/c0f003eb-4269-476c-a861-89628929caa1)):

> "Time delay isn't included in the test."

Six words that make a fast dry run honest instead of misleading. Without them a user tests a routine with a 10-second delay, sees it fire instantly, and concludes the delay is broken.

An operator building a 20-minute sequence cannot wait 20 minutes to check it. Firing every cue back to back so they can watch the cameras actually reach each pose is a small engine change, since `motion_wait_idle` already exists. Worth adding what SmartThings lacks: a per-step result afterwards, because our steps can genuinely fail (`device_busy`, camera gone).

### Other authoring patterns worth taking

| Pattern | Source | Why it fits |
| --- | --- | --- |
| The example lives **inside the field**: "Time - *Example: every day at 8:00 AM*". Unconfigured optional fields read "Not set". Per-step timing is framed as "Delay this action" rather than a separate concept | [SmartThings](https://mobbin.com/flows/c1deb96c-32e4-41e5-8c75-1ca1cc446e2a) | One line each, removes a class of confusion. Ours: "Hold - *Example: 40 seconds on P2 before cutting*". |
| A **live cost strip** in the header filling in as you author: Planned Volume / Est. Duration / Est. Calories, starting at "–" | [MyFitnessPal](https://mobbin.com/flows/5377d1a7-029d-4312-b547-26e89d4d94ad), compact version in [Weverse](https://mobbin.com/flows/15012a3b-c839-4015-9541-db50c8f79468) ("5 tracks · 13:33") | "N cues · total runtime · cameras used", updating every edit. An operator writing for a service of unknown length should never do arithmetic. |
| Run lives **on the library card**, and the row shows run state in place: turns blue, subtitle becomes "Starting…", trailing icon becomes a check | [Hevy](https://mobbin.com/flows/49e3ad2c-6e8a-4f75-8a1a-96010829280f), [Google Home](https://mobbin.com/screens/0666c2cc-6f26-4c8d-8481-61e6157dd8de) | Start, watch, and stop from one screen with no navigation. Ours: "4 cues · 12:30" becoming "Cue 2 of 4 · C1 to C2". |
| Row subtitle as a structural fingerprint: **"1 starter • 3 actions"** | [Google Home](https://mobbin.com/flows/f433d37c-999b-42da-a865-d8ba96e09aae) | Makes a half-built sequence obvious in the list without opening it. |
| **Duplicate** in the detail's action bar (Favorites / Duplicate / Edit / Delete) | [SmartThings](https://mobbin.com/flows/54b77ebf-16fb-4999-af49-8a7104c31ab5) | Next week's service is almost always last week's sequence with two changes. |
| Naming comes **first**, defended with helper text rather than post-hoc validation: "Each of your personal and household Routines needs a unique name" | [Google Home](https://mobbin.com/flows/f433d37c-999b-42da-a865-d8ba96e09aae) | Explains the constraint before it can become an error. |
| An **Enabled toggle at the top of the routine itself** | [Alexa](https://mobbin.com/screens/b273759d-36bb-4e29-bd69-ead724a67588) | Disable without deleting. |
| A dry run that shows **scope rather than behaviour**: renders the rule in plain language, then "2 TRANSACTIONS MATCHED" with the affected rows listed | [Origin](https://mobbin.com/screens/982f8467-e86b-4f48-9b7b-0ce3e3792048) | A second flavour of preview, cheaper than executing. |
| Saved card carries created date plus duration: "Created 2/10/2026 • 17 mins" | [Tonal](https://mobbin.com/flows/d2cdceb2-e6d1-4e36-8db5-bcaf13afa3dd) | How you find last month's sequence again. |

### The running screen

Runna answers "what now, what next, how far in" through four redundant channels at once ([flow](https://mobbin.com/flows/38f02bdd-0587-4849-bee2-d2f52ca5750b)): a big elapsed timer, a segmented bar with one segment per block, a "Set 1 of 3" counter, and the active row outlined in orange. Rest is an explicit visible row rather than a gap, so our holds should be rows too. Pause/Stop stay pinned.

It surfaces the next block's requirement while the current one runs ("Equipment required: Barbell") - for us, "Next: C1 preset P4".

What it lacks and we need: **jump-to-cue**. A service runs long or short, and the operator must be able to slide the sequence rather than restart it.

### Treat the first run as its own event

Whatnot locks "Preview show and go live" behind a padlock until **"Rehearse going live"** is ticked ([flow](https://mobbin.com/flows/984a6d2a-7c59-40da-9ea6-82e1d923d21b)). A sequence that has never been run should say so on its card, and starting one mid-service should state what it is about to do first: "This will take C2 on air and move C1. Start?"

## Half B: when something is broken

### The absolute rule

**Degrade in place. Never take over the screen during a service.**

- [Google Home](https://mobbin.com/screens/9338c84f-8c3f-4256-bfb2-c7c31515df08) desaturates only the broken tile, inline beside healthy ones. The layout does not reflow.
- [IKEA](https://mobbin.com/screens/132b44ee-ed16-462d-87ec-e65ae08690f2) ambers the card **and** the app bar; the control stays visible but inert, so you can see what you would normally do.
- [LARQ](https://mobbin.com/flows/8becc79a-e731-4115-9317-1a0e3ab87144) uses three redundant signals and zero modals.
- [Sonos](https://mobbin.com/flows/a5202be7-d44d-46b7-a1ba-6e1ebe3bfa5b) keeps the real screen as skeletons under a slim tappable bar rather than an error page.
- [DAZN](https://mobbin.com/flows/6e1d2018-4095-496a-b239-aa81699087f6) overlays help on a **still-playing** player.

If C1 drops mid-service its card greys and its controls go inert, a slim banner appears, and nothing else moves. TAKE, the on-air camera, and the running sequence stay exactly where the thumb expects them.

### State, timestamp, one action

The minimal correct offline state, from [ChatGPT/Codex](https://mobbin.com/screens/635cf9e7-fad6-4e72-b13d-20c138e4af00): a red dot beside the name, then the device icon, **"Offline • Last seen 18 minutes ago"**, and one blue "Reconnect". Nothing else.

The elapsed time is what tells our operator whether this is a USB glitch from ten seconds ago or a camera that died before the service began, and therefore whether to wait or walk over. We know the serial, the last frame time, and the last libdev callback, so we can be more specific than any app here: *"Tiny 2 Lite (SN …4C2) - Offline • Last frame 2 min ago"*.

### We can diagnose better than any of these apps

Hatch converts signal strength into a physical instruction: **"Getting warmer… Looks like your Hatch is a bit out of reach. Try getting closer"** ([flow](https://mobbin.com/flows/f29a788d-c1da-41d7-ba9c-a4d2696a2869)). It names the cause in terms the user can act on within five seconds, and it distinguishes *found but weak* from *not found*.

[Tonal](https://mobbin.com/flows/8e80fc8c-1abf-4033-98d1-0b5a25cb212f) is the counter-example: four unranked possible causes stacked in a paragraph, one of which is a billing state, with the rest offloaded to a web link. It reports; it does not diagnose.

We know whether the bridge is alive, whether AVFoundation has the camera, whether the TCC grant exists, whether libdev enumerated the device, and whether something else holds the control endpoint. **That last one deserves its own named diagnosis**, because it is our most common real cause and no generic message will ever lead to it:

> "PTZ commands are being refused. OBSBOT Center is usually the cause - quit it and the camera comes back."

### Symptom triage, for what we genuinely cannot tell apart

[LARQ](https://mobbin.com/flows/7a03c47a-773d-4b5a-95d7-3895c9be7b01) asks one question whose answers are things the user can **see**, with a "TROUBLE PAIRING?" button available *during* the wait rather than after a timeout:

> "what did you see when you **pressed the lambda button** three times?"
> NO BLINKING LIGHT → / SAW DIFFERENT COLOR LIGHT → / LIGHT IS BLINKING →

Every branch terminates in an executable retry, in-app, offline. Ours: *"What do you see on the camera itself? - No lights at all / Light on but it won't move / Moving but no picture"*.

Include [IKEA's catch-all row](https://mobbin.com/flows/3da11b05-d72c-423f-8325-36b0e68fabd4), **"Nothing seems to be working"**, so an unlisted symptom does not strand anyone. IKEA also ranks its two doors correctly: the cheap one (`Try again`) is primary, the expensive one (`I need help`) secondary, and neither dead-ends.

### Every branch ends in a button

[Eight Sleep](https://mobbin.com/flows/2b4d9100-a4a6-46b6-81a4-f3e3ea5528a4) writes its help topics as **first-person symptoms** ("My Pod is offline") and ends the article in the action itself: step 2 of the written procedure is literally the **"Reconnect Pod ›"** button underneath it. Its opening line normalises the failure in six words: "Network disconnections can happen, however getting your Pod back up and running is easy."

Ours must end in "Retry camera", "Restart bridge", or "Reset and retry" - already built for the TCC path in the Bridge UI, and it should exist identically on the phone. An operator at the back of a hall cannot go and drive the Mac.

### Verify with a named result

"SINGTEL-2KW5 added as a trusted network for your system" beats "Connected!" because the operator can check it is the *right* thing ([Sonos](https://mobbin.com/flows/a5202be7-d44d-46b7-a1ba-6e1ebe3bfa5b)). Ours: *"C1 (Tiny 2 Lite, SN …4C2) reconnected. Preview live, PTZ responding."* Only claim the parts actually re-tested.

### Partial permission, and the fear behind it

[Preply](https://mobbin.com/flows/2f0a2068-c929-428a-b0f9-9a4d26b17482) shows two permissions as separate buttons where the satisfied one becomes an inert "✓ Camera enabled" in the same slot, so what is outstanding is visible at a glance. Its two best lines:

> "Let your tutor hear and see you during lessons." (justified by what the *other person* gets)
> "You can turn off your mic and video any time." (pre-empts the fear that grants are permanent)

Ours: *"The bridge only uses the camera while it's running. Quitting releases it."* [Eight Sleep](https://mobbin.com/flows/73097a1b-7b34-4f24-b029-afb796d99390) adds listing a permission beside its precondition - for us the grant and whether the camera is physically plugged in.

### Keep telemetry alive when the picture is dead

[GoPro](https://mobbin.com/flows/e7e260ce-8ba8-4049-bc68-5a9d5a940f8f) keeps record time, wifi, and battery above a pure black preview. [Twitch](https://mobbin.com/flows/d02fe78c-2259-4ecd-ac4c-a1db038bb6d2) shows "OFFLINE / -- / 0 / 0" using **"--" for unknown rather than a fake zero**. A black MJPEG pane tells our operator nothing; link state, last frame age, serial, and current pose beside it make "no picture" and "no camera" visibly different problems.

## Must not be copied

- **Help links to the web.** DAZN's "go to https://www.dazn.com/streaming" is help that needs the internet, delivered when the internet is the suspected fault. Also Tonal's "Get more information here", IKEA's "Go to Help & support", Eight Sleep's "Learn more ›". Our venue's internet has already failed us once, so every word of troubleshooting copy, including symptom trees, must be inside the app bundle and readable with the router unplugged.
- **Support-team escape hatches.** LARQ's "REPORT A PROBLEM", GoPro's "Get Support". There is no support team. That slot should be "Copy diagnostics" (log tail, versions, serials, last error), with any GitHub link clearly marked as needing internet and never presented as the fix.
- **Account or membership gating in a failure path.** Tonal lists "only available with an active membership" as a possible cause of "not found".
- **Remote assets in empty states.** Hue's and Hatch's illustrations must be bundled. Gotcha #48 applies: anything under `assets/` is served `no-cache` and must survive a poisoned client cache.

# Mobbin research: live-operator and sequence-editor patterns

Gathered 2026-07-24 for the UI/UX effort (not yet charted). Two agents examined 85+ screens on Mobbin and reported from the images, not metadata. Every claim below links the screen it came from.

Product being designed for: a Flutter remote (mobile web, Android, iOS) driving PTZ cameras during live gurdwara services. One operator, phone in hand, **eyes on the room rather than the screen**, and mistakes go out live to a congregation.

## Live-operator surface

The single highest-value finding: **a silently frozen preview is the failure mode most likely to put a wall on air**, and nothing in the current UI would reveal it. Live apps solve this with a qualitative verdict, never engineering numbers.

| Pattern | Source | Why it fits |
| --- | --- | --- |
| Two-line always-on telemetry strip above the viewfinder: armed state, time left, mode, codec | [Kino](https://mobbin.com/screens/22f2bf51-506e-40bf-b714-f78f826c6748) | The operator looks away for 30 seconds at a time. Recovering context must cost zero taps. |
| Qualitative health verdict in red with a glyph (`Video Quality: Poor`), not bitrate graphs | [Behance](https://mobbin.com/screens/6c180805-a502-4205-9242-b3a12f62242c), [Twitch's Too Low / Just Right / Too High](https://mobbin.com/screens/1a865272-b057-476a-8d4c-6a7482820fa9) | Two-channel signal (colour plus glyph) survives a glance. Maps to a `Preview: Live / Stale / Stopped` row. |
| Live thumbnails on cue and scene slots instead of names | [Vimeo scene filmstrip](https://mobbin.com/screens/6caeef01-524d-4452-b645-36f30e9a6967) | "P4" means nothing at speed; a frame of the darbar from that angle means everything. |
| The camera selector as a **diagram of the physical space**, active camera filled | [Tesla](https://mobbin.com/screens/7b38ed5b-d445-4346-86ff-11a41dc3a1c1), [Rivian](https://mobbin.com/screens/328d00a7-8a1d-47e6-af86-2783a87a8c88) | The operator's mental model is spatial (back of hall, side of darbar), not a row of serial numbers. Tesla additionally draws each camera's field of view. |
| Full desaturation plus placeholder readouts (`- -°`) the moment the connection is unconfirmed | [MyDyson connecting](https://mobbin.com/screens/4b8af8cf-12b8-45a1-a2be-40f6e33cd0f6) vs [connected](https://mobbin.com/screens/ee22fae5-7118-4873-8519-c585e8c277a2) | Controls that look tappable but do nothing make the operator press TAKE twice. Never optimistically render last-known values. |
| Persistent in-frame value readout, rendered huge during adjustment then receding | [(Not Boring) Camera](https://mobbin.com/screens/4587dc77-443b-4426-aa06-8133112c8c52) | Readable in peripheral vision while the eyes are on the room. |
| Named transition presets as chips, with their parameters visible above them | [Spotify transition editor](https://mobbin.com/screens/49fb0195-8195-473c-a8fe-e508167b5012) | `Cut` / `Slow dissolve` / `Reverent` picked once before a service beats editing a millisecond field mid-kirtan. |
| NOW / NEXT pair with a solid-then-dashed progress bar | [Runna](https://mobbin.com/screens/2bcd311f-ae9f-4365-8f9a-7ca43544e6ee), [Ladder](https://mobbin.com/screens/d1169c75-4219-4bf1-aa2c-f5eb8fc0187a) | Knowing a cue fires in 8 seconds is what lets the operator decide to let it run rather than fight it. |
| Grade severity by fill, not by dialogs: red filled to commit, red outlined for consequential-but-instant | [Circle](https://mobbin.com/screens/8906f6c5-f640-423b-a5bb-1c813f20cea9), [Riverside](https://mobbin.com/screens/53c40604-49a5-4f49-906d-6fbbc61a09da) | Neither app gates Record or End stream behind a modal, and both are genuinely live. |

## Sequence editor

| Pattern | Source | Why it fits |
| --- | --- | --- |
| **Read-only detail whose bottom bar offers Duplicate** - abolishes Save As entirely | [SmartThings routine detail](https://mobbin.com/screens/9a26ccbd-db7f-48be-bc1c-cac67f4dc265) | Solves "no way to create a new sequence while one is loaded" with one unambiguous tap instead of a three-way save menu. |
| Two-mode editor, `Cancel / Title / Save`, no ambient autosave | [SmartThings edit](https://mobbin.com/screens/c0f003eb-4269-476c-a861-89628929caa1), [Waking Up](https://mobbin.com/screens/5f74befd-72a9-408f-985f-cedbc55649b2) | Mode *is* the unsaved indicator, so no dirty badge is needed, and no in-progress edit reaches the bridge. |
| **Draft version separate from the active version** (`Activate` / `Discard Draft`) | [Twenty](https://mobbin.com/screens/f8e97121-3fef-408d-9681-67e14fd82f35), [Attio](https://mobbin.com/screens/f15eac18-f7be-4fc5-863d-04d626d3320e) | The most valuable structural idea found. Edits to a loaded sequence must never mutate what the bridge is about to run. |
| Library row carries a generated summary: "1 starter, 3 actions" | [Google Home](https://mobbin.com/screens/92fa88c8-8b44-476f-bba3-e193b53197b8), [Bevel](https://mobbin.com/screens/eac60eff-fe63-4dda-a9dc-9da8bfdf7243), [adidas segmented interval bar](https://mobbin.com/screens/95d6f8ea-3fcf-441e-9750-5f75fc340944) | "6 cues, 4m 20s" is the most useful thing to read before tapping. The adidas bar maps onto a strip showing which camera each cue uses. |
| Three-tier error escalation, nothing blocked | [Copy.ai](https://mobbin.com/screens/8072e644-8dbb-417e-b496-86a1bba65e6a), [Apollo](https://mobbin.com/screens/60706708-72c8-4771-becd-ef2ee7047893), [Cherrypick](https://mobbin.com/screens/9c60adb4-71cd-4c77-887a-bdc1df5a3ba8) | Header counts the problem, the offending card gets a border, the detail names the exact missing field. Apollo replaces the card's summary with the warning; Cherrypick puts the fix button on the broken row. Directly applicable to an empty preset. |
| "Not set" as literal grey text in the value position; empty slots drawn as empty slots | [SmartThings action detail](https://mobbin.com/screens/e828da73-c086-493a-9188-9dae5b2ec9b9), [Binance shortcut tray](https://mobbin.com/screens/d91ee917-0dac-4d29-9659-11dcfe9758e4) | An unset field rendered blank reads as a rendering bug and gets scrolled past. A P1-P6 grid should draw the empty ones. |
| **Dry run from inside the editor**, with an honest caveat about what it omits | [SmartThings "Test routine actions"](https://mobbin.com/screens/c0f003eb-4269-476c-a861-89628929caa1) | Highest-value single element found. Preview cue moves on the off-air camera, without saving and without going on air. |
| Running view = the same list with one card promoted by border plus badge | [Runna](https://mobbin.com/screens/9a13a212-beaf-44e9-a7b0-871e8f99515b) | Do not build a separate player screen. The operator needs the upcoming cue visible so they can pre-empt a bad one. |
| Conflict gate that names the consequence in the button label | [Ladder resume gate](https://mobbin.com/screens/f04b2089-9297-4e4b-b006-5d5ca0547f52), [n8n](https://mobbin.com/screens/9515438b-8c33-42e0-9896-09ac4889ac02) | n8n puts the destructive option as the low-emphasis text button and the safe one as the filled primary. Copy that weighting. |

## Explicitly rejected

Patterns common in these apps that would be **wrong** here, with the reason:

- **Confirmation dialogs or slide-to-confirm on TAKE.** A cut has a *timing*. A modal makes the cut land late, which is a worse on-air error than the cut itself. A slide needs 400-700 ms of contact and cannot be done without looking. Note that neither Riverside nor Circle gates a genuinely live action behind a dialog.
- **Undo toasts after a commit.** Once a frame reaches the congregation nothing is undoable, and offering Undo falsely implies the mistake was contained. A one-tap "cut back to the previous camera" is legitimate; framing it as undo is not.
- **Autosave while editing.** Fine for inert artifacts. Here a mistyped hold time would reach a live sequence.
- **Destructive action as the visually dominant button.** [GoPro Quik](https://mobbin.com/screens/beed654c-76cd-4e1d-b533-038a3c4667d3) makes red filled "Cancel changes" dominant over an outlined "Back to edit". Under time pressure the operator taps the biggest button.
- **Blocking the primary action on invalid state** mid-service. Refusing to run a 5-cue sequence because cue 4 is unset is the wrong failure at the wrong moment. (Gating at *start*, before going live, is a different question and is being decided in the reliability map.)
- **Drag-to-reorder as the only mechanism.** [SiriusXM](https://mobbin.com/screens/cfb1e560-c6ae-4883-b6b9-47eff0ade897) needed a banner explaining it, which proves it is not discoverable. Provide Move up / Move down in an overflow too.
- **Swipe-to-delete on cue rows.** None of the sequence editors examined use it, and that is not an accident.
- **Chat, viewer counts, reactions.** Every live app spends 30-40% of screen on them. Our operator is not the broadcaster and is not being addressed. That space belongs to preset thumbnails and the NOW / NEXT strip.
- **Settings accordions on the operating screen.** Fine at 1440 px on a desk, a mis-tap trap on a phone held one-handed in a dim hall. Configuration belongs on a screen entered before the service.

## Skeuomorphism, carefully

[(Not Boring) Camera](https://mobbin.com/screens/57d1236e-1067-4cc8-9012-b8fee4594df5) is delightful and the wrong lesson to over-learn. Its dials need sustained rotational gestures with visual feedback. Steal the readout and the bind indicator; keep the existing hold-to-zoom rocker, because a rocker can be found by thumb position alone.

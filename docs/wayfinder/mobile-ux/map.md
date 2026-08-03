# Map: Mobile Operator Experience

`wayfinder:map` - charted 2026-08-02

## Destination

A decided interaction design for the phone surface: the mobile web app, designed and shipped as a genuinely installable app rather than a page in a browser.

Done means nothing is left to decide before someone builds it. Layouts, journeys, states, and copy are settled; the building is a later cycle. This map decides, it does not build.

## Notes

- **Scope is the phone, first.** The Android and iOS builds run the same Flutter code, so decisions made here carry to them. The macOS desk layout and the bridge window are out (see Out of scope).
- **The operator.** One volunteer, phone in hand, in a gurdwara hall for 90 minutes to 3 hours, eyes mostly on the room rather than the screen. They may be doing seva at the same time, may be using the app once a month, and may not be technical. A wrong tap is visible to the whole congregation and to the stream.
- **The environment.** LAN only, no accounts, no cloud, and frequently no internet at all. Anything that assumes a backend, a login, an SMS, or a support team does not exist here.
- **Skills:** `grilling` and `domain-modeling` for decision tickets, `superpowers:brainstorming` where a ticket needs options generated before it can be decided.
- **Research already gathered:** [Mobbin findings](../ui-ux-research/mobbin-findings.md) holds two static-screen passes. Four flow-research passes were commissioned while charting - pairing and first run, the live-session arc, authoring plus failure recovery, and cross-device plus settings - and land in the same directory.
- **Standing constraints:** never push without being asked; the user reviews the running UI before any release; no em dashes.
- **Tracker:** local markdown. Migrates to GitHub issues on request.

## Tickets

The frontier is every open ticket with nothing blocking it.

| Ticket | Type | Status |
| --- | --- | --- |
| [What installable costs, and whether a service worker can be safe here](tickets/01-installable-without-cache-poisoning.md) | research, AFK | frontier |
| [Decide the Live screen layout](tickets/02-live-screen-layout.md) | grilling, HITL | frontier |
| [Decide how the operator knows the system is healthy](tickets/03-health-visibility.md) | grilling, HITL | frontier |
| [Decide the pairing and first-run journey](tickets/04-pairing-first-run.md) | grilling, HITL | frontier |
| [Decide the install journey](tickets/05-install-journey.md) | grilling, HITL | blocked by ticket 01 |

## Decisions so far

<!-- one line per closed ticket -->

- **Scope and destination, settled while charting.** The phone surface first, designed as a genuinely installable app rather than a browser page. Installability was chosen for concrete reasons: no address bar eating vertical space on the Live screen, no pull-to-refresh or accidental tab close during a service, a home screen icon a volunteer can find, and better survival of backgrounding than a tab gets.

## Not yet specified

In scope, not yet sharp enough to ticket.

- **The sequencer on a phone.** The reliability map already decided the authoring MODEL (a draft separate from what runs, Save distinct from Apply, list into read-only detail into edit mode). How that renders on a phone is undecided and depends on the Live screen decisions landing first.
- **Settings architecture.** Connection, grid overlays, control style, speeds, library import and export, and pairing now sit in one flat screen that is getting long. Whether the answer is grouping, search, or moving things onto the surfaces they affect is not yet clear. The cross-device research pass may sharpen it.
- **A second operator on a second phone.** Two people can already connect and both drive the same camera, with no presence indication and no arbitration. Whether that is a real venue scenario or a theoretical one needs answering before it can be designed.
- **The visual language.** Colour, type, spacing, and a component vocabulary. Deliberately last: it should follow the layout and journey decisions rather than lead them.
- **Accessibility in the hall.** A dim room, an operator who may be older, and a screen held at arm's length. Contrast and target sizes need a deliberate pass rather than an assumption.
- **How these decisions carry to the native builds.** The Android and iOS apps run the same code, so most of this transfers for free, but the install journey and any browser-specific affordance do not.

## Out of scope

Never graduates from this map; returns only as a separate effort.

- **The bridge window.** An admin surface with a different user at a different moment. Its convergence with the remote is GitHub #76.
- **The macOS desk layout.** Already built and serving a different job (preview and program side by side on a wide screen). Revisit once the phone decisions are made, as a separate effort.
- **OBS configuration.** Documented in `docs/INSTALL.md`; not part of this product's interface.
- **Anything in the [Service Reliability map](../service-reliability/map.md).** That map makes what exists trustworthy; this one decides what the operator sees. Its last open ticket is the frame-drop evidence.

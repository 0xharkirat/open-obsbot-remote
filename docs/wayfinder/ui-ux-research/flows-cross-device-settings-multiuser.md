# Flow research: across surfaces, settings architecture, and more than one operator

Gathered 2026-08-02 for the [Mobile Operator Experience map](../mobile-ux/map.md). Roughly 30 flows and web sections examined from their images.

The useful headline: **almost none of this needs an account, a server, or the internet.** Presence, rosters, driver state, connect notifications, session expiry, settings search, and per-camera scoping are all state our bridge already owns or can own. A LAN server is still a server.

## Across surfaces

| Pattern | Source | Why it fits |
| --- | --- | --- |
| The connection is **permanent chrome, not a destination**: "Connected / Living Room TV" as a strip that expands into the full control sheet. One component at three sizes: strip, mini-bar, sheet. | [Google TV remote](https://mobbin.com/flows/8c1e112d-387d-4026-b3a9-81cdd74a0b88) | Our "which bridge, which camera selected, which on air" is exactly this. Lets the Live screen stop reserving separate space for identity. |
| **Two stacked planes.** The control plane is pinned on top and never changes; the context plane slides underneath and does. The remote gets its own tab, equal billing with content. | [Roku remote](https://mobbin.com/flows/e41d66fd-733f-4025-996b-72b5c43086eb) | This retires the Frame toggle AND the old joystick-eats-scroll problem structurally: pin PTZ, let presets, sequences and cameras occupy a draggable lower plane. |
| The desktop earns its width with a **source rail**, not bigger buttons. And the riskiest distinction in the product carries an always-visible badge plus one sentence: grey `BACKSTAGE` versus red `LIVE`, with "You are backstage. You are not live. The audience will not see or hear you until you begin streaming." | [Circle, going live](https://mobbin.com/flows/40cf4d4f-9bed-4194-a453-b07ef2067931) | Our preview-versus-on-air is implied by the TAKE button rather than shown on the frame. The badge belongs on the preview itself. |
| Local-network troubleshooting lives **in the empty state of the device picker**, with a button into system settings. And "Others can start or join a Jam on this speaker" is a property of the *target device*, not a global privacy setting. | [Spotify Connect](https://mobbin.com/flows/90a9facc-5cff-49eb-9f79-335bf704a149) | Our "phone cannot find the bridge" guidance currently lives in docs. It belongs where discovery fails. The join toggle is almost verbatim "Allow other phones to control this bridge". |
| The current output is displayed **permanently at low visual weight, named after the actual machine**: "iPhone → System Capture". | [Apple Podcasts](https://mobbin.com/flows/6b097a42-c390-46e6-a39b-d25ba5a1f9c2), [Deezer](https://mobbin.com/flows/22509b6e-a5c8-4438-81bb-58979d8fab70) | A one-line "Mac-mini → active.mjpg" readout is how an operator moving from phone to desk confirms they are on the same bridge. |
| **Command palette** grouped by category, advertised as a visible control ("Open Command Menu ⌘K") so the shortcut is not folklore. | [Vercel](https://mobbin.com/flows/d69bfc89-9340-4478-b035-387a87b188a9), [Grok](https://mobbin.com/flows/2f95196a-a22f-44e3-9b07-186d73d389f8) | The clearest thing the Mac and desktop-width web can add that is not just a bigger phone. Our protocol action list is already the registry. |

Marketing copy worth borrowing for the README: [Wispr Flow](https://mobbin.com/sites/sections/ddc48c4a-43de-4cdc-89f0-791148ca1b3e) frames it as posture rather than capability, "On-the-go or at your desk", and never implies the phone is the lesser client.

## Settings architecture

**The cheapest high-impact change in the whole report:** [Outlook's settings search](https://mobbin.com/flows/cd333b5f-f006-48a0-9707-9c1dcd72518d) prints the full path under every hit - "Days of Email to Sync - *Accounts > samlee@outlook.com > Sync Settings*". Search is not an alternative to hierarchy, it is a **tutor** for it, so the second lookup is navigation. A static descriptor list filtered client-side, no index, no server. It answers the "grid overlay toggle I used last month" problem outright.

| Pattern | Source | Why it fits |
| --- | --- | --- |
| Cut the settings tree **by ownership**, with a section header naming the appliance: "ON THIS BRIDGE" | [Philips Hue](https://mobbin.com/flows/549e3b7f-6bf4-4ede-86a4-48853eafb4d9) | Ours splits into "On this phone" (grid, control style, haptics) and "On this bridge" (cameras, presets, sequences, pairing). Invisible today, and it matters the moment the operator picks up the Mac: phone settings do not follow them, bridge settings do. |
| **Scope declared by the section header**, with the global default one tap below: "GOOGLE.COM SETTINGS" then "Default Site Settings >". Small enumerations resolve in a popover rather than a push. | [Arc Search](https://mobbin.com/flows/22550c9f-1319-4af4-9697-b74cae2d5fda) | Solves our per-camera versus global split: "C2 SETTINGS" then "Default camera settings >". Kills a confusion we would otherwise create. |
| One **Advanced** room absorbs everything that would inflate the front page, terminating in a distinct last group: Open device settings / Send logs / Reset cache in red. Version string at the foot, tap to copy. | [Slack](https://mobbin.com/flows/ee8ee6b1-d3a5-4fe7-98ab-5d5a0895a9a9) | Ours: speed tuning, control curves, ports. Last group: open System Settings > Camera, copy log path, restart subprocess, reset pairing. |
| **"Diagnostics - Check if everything is online"** as a normal settings row, and a subtitle on every row saying what is behind the chevron | [Craft](https://mobbin.com/flows/126208d3-2ecc-443b-943f-f1064b4873b0) | Bridge reachable, camera permission, MJPEG streaming, clients paired. The first thing anyone wants at nine on a Sunday. |
| **Value in the row** at top level, so the list is a status display as well as a menu: "Voice → Voice Activity". Mutually exclusive choices are **radios with prose**, never a stack of toggles to reason about combinatorially. | [Discord](https://mobbin.com/flows/8f371af0-ae13-4789-9b1b-bea5a38a30d5) | "Control style - Joystick", "Grid - Thirds". Our control style is a radio group with descriptions. |
| A **live preview in the same viewport as the control**, updating as you choose | [MacroFactor](https://mobbin.com/flows/11cb140d-780b-42a1-af7d-5143017e533a) | Grid overlay, PTZ curve and zoom easing cannot be evaluated from a label. A grid over a still frame, a plotted curve, an animated speed. |
| A dependent setting stays **visible and greyed** rather than disappearing, so the dependency is legible | [Shop](https://mobbin.com/flows/5786fd75-8476-4e15-9e34-057168459662) | |
| Group by **surface** rather than by feature (Apple Watch / Live Activity / Widgets in one card) | [Tide Guide](https://mobbin.com/flows/b42656f5-a323-46e0-97f4-1bf4fe7e8c74) | Directly analogous to phone-only versus bridge-only. |

The counter-example worth naming: [Grab](https://mobbin.com/flows/4f55e064-b994-4a1c-a655-2e17cee39883) uses internal product names as section headers, scannable only if you already know the org chart. Do not name our sections after our subsystems.

## More than one operator

The map's fog asks whether a second operator is a real scenario. If it is, these are the patterns.

| Pattern | Source | Why it fits |
| --- | --- | --- |
| **A persistent pill that announces control and releases it from the same place**: green, padlocked, "You're controlling Jane Doe (visitor)" with a "Release them" button. There is no state where someone is driving and the UI is quiet about it. | [Mural](https://mobbin.com/flows/42972ff6-1b6d-43fe-a7bf-f9f21948f29c) | When the desk Mac takes a camera, the phone shows who holds it, and the holder gets Release in the same banner. A state field and a widget. |
| Transfer is a deliberate roster action ("Make Host"); reclaiming is **always available but preceded by a plain statement of what it breaks**: "Reclaiming host may disrupt breakout rooms, polls, and screen share." | [Zoom](https://mobbin.com/flows/ea183ebb-e092-489e-8339-5ef9727c6f22) | Ours becomes truthful: "Reclaiming control will stop the running sequence on C1." The permanent reclaim button matters for the phone-to-desk handover. |
| A new client joining is **an event worth interrupting for, with the remedy inside the notification**: a toast reading "Login Successful / Telegram Web" carrying an inline red "Terminate". Plus auto-expiry: "If Inactive For: 6 months". | [Telegram](https://mobbin.com/flows/2d976440-7dae-4acf-86dd-6cf2b403254b) | Answers "a second phone connects mid-service" in two seconds without anyone going looking. The expiry also stops `auth.json` growing forever. |
| In any client list, **the one you are holding is marked and defended**: "Current device" with a warning triangle, unticked, plus "Last used: 1 minutes ago" on the others | [Evernote](https://mobbin.com/flows/5486260f-99f8-4a02-ac1c-32e36274e217) | Prevents the worst self-inflicted failure: revoking the phone you are about to pick up. |
| **Presence disclosed at the threshold**, before the newcomer can do anything: "Jane Smith is in this live" on the lobby screen | [Circle](https://mobbin.com/flows/123342ab-9898-4601-9c37-8693aee39ace) | The second volunteer lands on "2 cameras. Hark's iPhone is controlling C2. C1 is on air." That one screen prevents most double-driving with no locking at all. |
| A request that **costs nothing and expires by itself**, with an override: raise-hand, auto-lowered with "Keep it raised" | [Google Meet](https://mobbin.com/flows/aa750e67-e17a-46d8-a90d-e1e9d19159f4) | The polite sibling of seizing control, which suits volunteers who will not want to seize anything mid-service. |
| Policy chosen once as a **named mode with a picture and a sentence**, not assembled from scattered toggles | [Expensify](https://mobbin.com/flows/044f73fe-33eb-43d8-a721-b6f61c99f5dd) | Three cards: "Anyone can drive" (today's behaviour), "One driver at a time", "Locked to this device". Set once by whoever owns the setup. |

All of the above want a **human-readable device name** ("Hark's iPhone", "Desk Mac"), which is one field captured at pairing. Not an account.

## Needs an account or the internet, so do not port

- Expensify's invitations, pending-member states and billing; Slack's authentication tabs and access logs; HBO Max's password-change advice. **Our PIN and QR are the correct LAN-native substitute for a joining link**, and they work with the venue's internet down.
- Spotify's device list is partly account-synced. Take the "Don't see your device?" local-network card and the join toggle; leave the discovery mechanism.
- Circle's recording chip and audience count are cloud-side. Our on-air badge is decided inside our own bridge and is therefore more trustworthy than theirs.

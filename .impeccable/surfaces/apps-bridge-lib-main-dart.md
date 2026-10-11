---
version: 1
slug: "apps-bridge-lib-main-dart"
primary_target: "apps/bridge/lib/main.dart"
related_targets: ["apps/bridge/lib/camera_deck.dart"]
---

# Bridge window

Scope: the Open OBSBOT Bridge desktop window (macOS and Windows), `apps/bridge/lib`. Mode: Operate.

Audience and job: the volunteer who sets up the bridge PC before a gurdwara service, and glances at it during the service. Jobs: setup with pairing, and health monitoring. The window answers "is everything OK for the service?" first; details appear only when something needs the user. A simple camera list with on-air state and Put on air; no camera previews. Must not feel like a gamer or tech tool; no wall of settings.

Content and proof: real values only (the LAN address, the OBS output URL, camera names, paired-phone count).

## Direction contract

THESIS: The service is a row of set places, as in a langar hall before the sangat sits. The window shows which places are served and the one that still needs you. It refuses the category default: a grey settings list of status dots and toggles.

OWN-WORLD: Limewash white ground; a durrie-maroon runner band (#7A1F2B) owns the header, with one plain jute edge; thali plates are the status marks: green (#2E7D4F) for connected and in progress, turmeric (#E0A526) reserved for "needs you". USER-PINNED 2026-10-11: no woven or checker pattern anywhere; whatever is connected or in progress is green. Atkinson Hyperlegible at large sizes. Raises: every status carries its proof (from Monochrome Product Site); a state is a shape, not only a colour: filled green plate with a tick = served, open green ring = in progress, solid turmeric plate with an exclamation mark = needs you (from Dance Notation Score); the place that needs you grows and carries its fix while the rest quiets (from Streaming Title Wall); places never move or reflow, only their content changes (from Split-Flap Concourse).

STORY: The volunteer opens the window, reads one sentence (Ready for the service / 1 thing needs you), sees four set places, fixes the one marked, and closes the window to the tray.

FIRST VIEWPORT: Top: the maroon runner band with the product name small and the one-sentence answer large. Under it, one row of four equal places, Bridge, Cameras, OBS, Phones, each a thali plate plus name plus real value; a place that needs the user grows in emphasis (turmeric border, solid turmeric plate with an exclamation mark) without moving. Below, two columns: Cameras (rows with name, model, ON AIR pill or a Put on air button) and the fix panel for whatever needs the user (default: Pair a phone, with the address and Show PIN and QR code); the OBS output URL with Copy under it. Settings sit behind one quiet icon in the band.

FORM: Langar Hall, position 4 of the ordered grounded list; seed key c1d6de05.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

Signature interaction: when a place changes state, its thali fills or empties in place (a short radial fill, 240 ms), and the answer sentence cross-fades; nothing reflows.

Unresolved: Windows vs macOS window chrome details; the settings sheet layout; a dark variant for evening programmes.

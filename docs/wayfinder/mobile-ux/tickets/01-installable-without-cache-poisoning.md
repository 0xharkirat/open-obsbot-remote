# What installable costs, and whether a service worker can be safe here

`wayfinder:research` - AFK - status: **open, on the frontier**

Blocks: [Decide the install journey](05-install-journey.md)

## Question

What does this app actually need in order to be installed to a phone's home screen and launch without browser chrome, on both iOS and Android? And can that be done without reopening the caching bug that made every icon disappear?

## Why this is not a free decision

The destination assumes installability. The repository history says the obvious route to it is dangerous.

Established facts, checked while charting:

- The build passes `--pwa-strategy=none`, so **no service worker is generated**.
- **No `manifest.json` is shipped at all** in the served web bundle.
- Gotcha #48 records why: Flutter web filenames are not content-hashed, a stale cache left the tree-shaken icon font missing codepoints, and **every icon rendered blank**. Three separate patches failed to close it, including a self-unregistering service-worker stub. The fix was to serve everything `no-cache` except `canvaskit/`. A poisoned client could not be rescued from the server and needed its site data cleared by hand.

Chrome has historically required a service worker with a fetch handler before it will offer an install prompt. That is precisely the machinery that caused the outage above. iOS is believed to differ, allowing Add to Home Screen from a manifest alone, but that is exactly the sort of platform claim that must be checked rather than assumed.

## What to find out

1. **Installability requirements, current and per platform.** What does Chrome on Android require today for `beforeinstallprompt` to fire? Is a service worker still mandatory, and if so must it have a fetch handler that serves offline? What does iOS Safari require for Add to Home Screen, and does it need a service worker at all? Cite current documentation, not blog posts from several years ago.
2. **Whether a service worker can be safe here.** If one is required: what caching strategy avoids the failure in gotcha #48? Look at network-first and stale-while-revalidate, versioned cache names keyed to a build id, `skipWaiting` with `clients.claim`, and whether a service worker can be written that caches nothing at all and exists only to satisfy installability. Name the failure mode of each.
3. **The recovery path.** If a client does end up with a stale cache, what can the SERVER do about it? Gotcha #48 says nothing could be done and phones needed a manual clear. Is that still true with a service worker in play, and can an update be forced from the bridge side?
4. **What standalone mode actually changes.** With `display: standalone`, what happens to the address bar, safe areas, the status bar, pull-to-refresh, the back gesture, and the behaviour of the app when backgrounded and returned to? Quantify the vertical space gained if possible.
5. **The offline dimension.** This app is served by a LAN bridge and often has no internet. Does an installed PWA still work when the bridge is reachable but the internet is not? Does a service worker help or hinder when the ORIGIN itself (the bridge) is temporarily gone?
6. **iOS specifics worth knowing.** Add to Home Screen is buried in the share sheet, so the app must teach it. Are there constraints on an installed iOS PWA that would hurt here: storage eviction, background behaviour, whether the saved pairing token survives, and any limits on a `http://` origin rather than `https://` (this bridge serves plain HTTP on a LAN).

Point 6's last item deserves particular attention. Much PWA capability is gated on a secure context, and this bridge is deliberately plain HTTP with no TLS. `localhost` is treated as secure by browsers, but a phone reaching `http://192.168.x.x:8765` is not localhost. **If installability or service workers require HTTPS, that may block the entire destination**, and the answer changes what this map can promise.

## Expected shape of the answer

A direct yes or no on whether installable is achievable on this LAN-only plain-HTTP origin, per platform, with citations. If yes, the minimum machinery required and its risk. If no, say so plainly, because the destination then needs redrawing rather than working around.

## Answer

_Unresolved._

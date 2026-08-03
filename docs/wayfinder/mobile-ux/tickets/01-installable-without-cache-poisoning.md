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

**Resolved 2026-08-02. The answer splits by platform, and it redraws the destination.**

### Service workers are dead on this origin, both platforms, unambiguously

`http://192.168.1.50:8765` is **not a secure context**. The [W3C Secure Contexts](https://www.w3.org/TR/secure-contexts/) "potentially trustworthy origin" algorithm is a closed list: `https`/`wss`, `127.0.0.0/8`, `::1`, `localhost` and `.localhost`, `file`, vendor schemes, or an explicitly configured origin. **Private IP ranges are not in it, and neither is `.local`.** The proposal to add RFC1918 ranges, [webappsec-secure-contexts #60](https://github.com/w3c/webappsec-secure-contexts/issues/60), has been open and unassigned with no linked PR **since April 2018**.

So: no service worker, no Cache API, no Background Sync, no Web Push. `--pwa-strategy=none` was and remains correct. Worth noting **the caching incident is not why it is correct** - the secure-context rule is, and it would apply even if gotcha #48 had never happened.

### Android: NO

HTTPS is a stated, current requirement for installability. MDN, verbatim: *"For a PWA to be installable it must be served using the `https` protocol, or from a local development environment using `localhost` or `127.0.0.1`"* ([Making PWAs installable](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Making_PWAs_installable)); [web.dev's criteria](https://web.dev/articles/install-criteria) lead with "Be served over HTTPS".

Chrome will not mint a WebAPK. Add to Home Screen degrades to a **plain bookmark that launches in Chrome with full browser UI**. The icon is real; the chrome-free launch is not.

Note the trap in the good news: Chrome **did** drop the service-worker requirement for install (108 mobile, 112 desktop, [source](https://developer.chrome.com/blog/update-install-criteria)). That is irrelevant here, because HTTPS was never the requirement that got lifted.

### iOS: YES, very likely, pending one cheap test

This inverts the usual expectation - **iOS is the permissive platform**. As of Safari 26, WebKit states *"there are now zero requirements for 'installability' in Safari"*: no manifest, no meta tag, no service worker, and every site added to the Home Screen opens as a web app by default ([Safari 26.0 features](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/), [WWDC25](https://webkit.org/blog/16993/news-from-wwdc25-web-technology-coming-this-fall-in-safari-26-beta/)). On iOS 25 and earlier, either a manifest with `display: standalone` or `apple-mobile-web-app-capable` works, and **neither is secure-context gated**.

**The one gap:** no Apple document affirmatively states that a plain-HTTP origin qualifies. The documentation says nothing is required and never mentions HTTPS, which is strong, but it is an argument from silence. **Settle it with a five-minute manual test**: serve the current build, add to Home Screen from an iPhone, confirm it launches with no address bar. That single test converts the plan from likely to certain.

### Two consequences to design around on iOS

1. **The installed app gets a storage jar separate from Safari** ([WebKit bug 181849](https://bugs.webkit.org/show_bug.cgi?id=181849)). The pairing token saved in Safari **will not carry over**, so the operator re-enters the PIN once after installing. Design the copy for that rather than letting it read as a failure.
2. **ITP's 7-day storage cap explicitly exempts home-screen web apps** ([WebKit](https://webkit.org/blog/10218/full-third-party-cookie-blocking-and-more/)), and standalone apps get the full 60% origin quota instead of 15%. So once paired, the token persists in normal use. Treat it as re-acquirable, not permanent.

### Rejected escape routes, with reasons

- **Self-signed certificate.** Chrome refuses service-worker registration on cert-error origins, and a click-through interstitial does not make an origin trusted. Making it real means installing a CA on every phone: on iOS a configuration profile **plus** a separate toggle under Certificate Trust Settings ([Apple](https://support.apple.com/en-us/102390)); on Android a user CA store entry that triggers a persistent "network may be monitored" warning. A scary multi-step ritual per volunteer phone. Do not ship.
- **A publicly trusted cert for the LAN IP.** Impossible. Let's Encrypt now issues IP certificates but only via `http-01`/`tls-alpn-01`, which need the CA to reach the address from the public internet; RFC1918 cannot be validated, and the ~6-day lifetime would need constant internet anyway.
- **The Plex pattern** (real domain, public cert, DNS resolving to a private IP) fails twice on our constraints: renewal needs periodic internet, and **DNS resolution needs internet at use time**, which is exactly what the venue lacks.
- **`.local` mDNS.** Does not help - not in the trustworthy list, and no CA will issue for it. It would improve discoverability (`obsbot.local:8765` instead of a DHCP-assigned IP), which is a real but separate benefit worth considering on its own merits.
- **Chrome enterprise policy** `OverrideSecurityRestrictionsOnInsecureOrigin` (Android, Chrome 69+) is the only genuine Android escape hatch, deliverable by MDM. It requires every operator phone to be enrolled and a static IP. Unrealistic for "a volunteer shows up with their phone", and the docs only promise secure-context restrictions are lifted, not that installability follows.

### What to do instead

**Ship a manifest plus the Apple meta tags, and keep `--pwa-strategy=none`.** It is inert on Android today, it delivers a genuinely chrome-free iOS app, and it upgrades for free if HTTPS ever becomes viable.

**Two CSS fixes are worth applying immediately, independent of any install work**, because they fix real hazards in the tab that exists today:

- `html { overscroll-behavior: none; }` kills pull-to-refresh, which currently **drops the WebSocket mid-shot** ([MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/overscroll-behavior)).
- `viewport-fit=cover` plus `env(safe-area-inset-*)` for notch and home-indicator clearance. This matters more than usual because the joystick and TAKE sit near screen edges.

For a chrome-free Android launcher icon, **the native APK already built in `apps/rc` is the shortest path**, sideloadable from the bridge's own web root. A Trusted Web Activity would not work, since TWA also requires HTTPS.

### A latent risk found in passing, unrelated to installability

Chrome's [Local Network Access](https://developer.chrome.com/blog/local-network-access) work (Chrome 142) adds a permission gate for local-network requests, and **restricts the ability to request that permission to secure contexts**. Today the page at `:8765` fetching MJPEG from `:8766` is local-to-local and out of scope. Chrome states an intention to *"extend these protections to cover all cross-origin requests going to destinations on the local network."* If that lands, the existing preview would need a permission an insecure context cannot request.

**This is a threat to the shipped product, not just to this map.** It belongs in the reliability map's fog, and it is the strongest argument yet for eventually finding a path to HTTPS.

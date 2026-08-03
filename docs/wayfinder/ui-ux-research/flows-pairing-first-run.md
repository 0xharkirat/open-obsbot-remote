# Flow research: pairing, first run, and reconnection

Gathered 2026-08-02 for the [Mobile Operator Experience map](../mobile-ux/map.md). Nine multi-step flows plus 16 zoomed screens, examined from images. Every claim links its source.

Framed against the real user: a volunteer, possibly non-technical, possibly on a borrowed phone, doing this once a month, in a hall, sometimes with the venue's internet down.

## The single highest-leverage screen we do not have

Hue never opens a scanner cold. One screen earlier it shows **a picture of the physical thing the code is printed on**, explains what scanning buys, and ends with one button, `Ready to scan` ([ownership-card primer](https://mobbin.com/screens/7ecd51b4-082e-4005-a505-3386320ed0ac)). Roku does the same for permissions ([flow](https://mobbin.com/flows/1d3f175c-1289-4aa7-85c7-60869e6b7c52)).

Our equivalent: the volunteer opens the remote, sees a viewfinder, and has no idea that a Mac somewhere needs to be showing a PIN. A screen with a small render of the Bridge's PIN panel and the caption "On the Mac running the bridge, click **Reveal**" removes the entire class of confusion.

Hue goes further and **gates on an observable physical fact** rather than a spinner: "Has the camera turned on and the LED begun pulsing blue?" with `No` / `Yes`. Ours would be "Is the Bridge window showing a 6-digit PIN right now?" - `No` routes to instructions, `Yes` opens the scanner. A silent wrong assumption becomes impossible.

## We can diagnose failures and currently do not

Today a wrong PIN, a phone on mobile data, a phone on a guest network, a quit bridge, and a macOS firewall block all look the same. **At the protocol level they are distinguishable**: a rejected `pair` is not a refused TCP connection, which is not a timeout.

The models to copy:

- [Fitbit's "No devices available"](https://mobbin.com/flows/6283ce10-f407-4690-8526-889549b93aeb) splits one symptom into **two headed causes, each with its own action link**: "Make sure Local Network Access is on → Settings" and "Check your Wi-Fi network → Learn more".
- [Shangri-La](https://mobbin.com/flows/3252e7af-942b-4c20-9597-708defe3c95c) is the only example that cleanly separates *your code is fine, your network is wrong*, and it does it by **naming the network**: "Please connect to Hotel WiFi and try again."
- [Sonos names the SSID in its success message](https://mobbin.com/flows/a5202be7-d44d-46b7-a1ba-6e1ebe3bfa5b): "SINGTEL-2KW5 added as a trusted network for your system."
- [Roku's empty state](https://mobbin.com/screens/0100e296-f39e-4808-86e1-cb970be8d9e7) keeps the spinner turning beside the header while a card inside the list says "Make sure your Roku device is on the same network as your mobile phone" - reads as "still looking", not "gave up".

## Patterns worth taking

| Pattern | Source | Why it fits |
| --- | --- | --- |
| Manual entry stays permanently visible under the scanner, **and survives a camera denial** - the denied screen keeps the manual pill instead of dead-ending | [PlayStation camera-denied](https://mobbin.com/screens/b27fac9f-381a-46f3-b761-47922ba43290), [Alexa](https://mobbin.com/flows/5dc6e5b3-7f1e-463a-8aa6-669f1ee007fd), [WhatsApp](https://mobbin.com/flows/77629de3-8144-4b73-a220-4a9e6039faca) | Non-optional for us: a borrowed phone will deny the camera, and on mobile web it may be unavailable entirely. |
| Teach where the code lives **in the space above the keyboard** on the manual screen, as permanent numbered steps | [YouTube "How to get a TV code"](https://mobbin.com/flows/eddbf94d-3a86-4fb0-80c2-d8f7124b465c), better than [Tubi's hidden sheet](https://mobbin.com/flows/964eb5fe-7b19-435b-9548-942177b6e5ae) | The person typing an IP by hand is the least likely to know where to look. Zero taps to discover. |
| Discovery first: a found device shown with model and identifier, `Connect device` on the card | [Roku](https://mobbin.com/screens/078311ac-cb2b-4d3c-9863-0a43aef1d089) | If we add mDNS, "there is one bridge on this Wi-Fi, tap it" becomes the fastest correct action. Removes the address, not the PIN, so it composes with existing auth. |
| Success names both the device and the network, then lands straight on the working screen. Any naming step is skippable with an explicit "Later" | [Sonos](https://mobbin.com/flows/a5202be7-d44d-46b7-a1ba-6e1ebe3bfa5b), [Roku](https://mobbin.com/flows/1d3f175c-1289-4aa7-85c7-60869e6b7c52), [Hatch "I'll Do This Later"](https://mobbin.com/flows/f29a788d-c1da-41d7-ba9c-a4d2696a2869) | A volunteer 5 minutes before a service does not want a tour. |
| Degrade **in place** with a repair verb: keep the screen's shape as skeletons, pin a banner reading a statement plus an action - "Unable to connect to Sonos. **Let's fix it**" | [Sonos reconnect](https://mobbin.com/flows/a5202be7-d44d-46b7-a1ba-6e1ebe3bfa5b) | "Unable to connect" alone is a dead end. The banner must be the entry point to the repair. |
| State staleness as **elapsed time**, not a boolean: "hasn't connected in a while", with the fault persisting rather than toasting | [LARQ](https://mobbin.com/flows/8becc79a-e731-4115-9317-1a0e3ab87144) | Maps onto gotcha #39: the MJPEG stream can wedge silently. "Last frame 40s ago" is what makes that visible to the operator rather than only to the log. |
| Convert a signal number into a physical instruction: "**Getting warmer…** Looks like your Hatch is a bit out of reach. Try getting closer" | [Hatch](https://mobbin.com/flows/f29a788d-c1da-41d7-ba9c-a4d2696a2869) | Distinguishes *found but weak* from *not found*, which most apps miss. |
| The reconnect action lives **inside** the help article, as a navigable row | [Eight Sleep "My Pod is offline"](https://mobbin.com/flows/2b4d9100-a4a6-46b6-81a4-f3e3ea5528a4) | Documentation with the fix button embedded, rather than instructions you must then act on elsewhere. |

## Worth prototyping later: an out-of-band channel

[Sonos transfers the pairing credential by playing a chime the phone's microphone decodes](https://mobbin.com/screens/6b32ced7-4636-4fd1-8258-32a1603c02dd), with a printed passcode as the disclosed fallback. Its permission explainer answers the question the user is actually asking, in an amber box: "**What if I don't allow microphone access?** During setup, you'll need to locate and manually enter the setup passcode."

This needs no internet, no shared LAN, and no camera, which covers the borrowed-phone-with-denied-camera case and the wrong-Wi-Fi case at once. It is the only pattern found that is *more* offline-capable than what we already have.

## Cloud dependencies, and what replaces them here

| Pattern seen | Dependency | Local replacement |
| --- | --- | --- |
| [Sonos](https://mobbin.com/flows/ffc9a516-a73f-4379-8251-a2b83eb46eaa) gates all setup behind ToS plus **Create Sonos account** in a web view | Hard. Blocks setup entirely offline | No account. The bridge's PIN is the identity. |
| [WhatsApp](https://mobbin.com/flows/77629de3-8144-4b73-a220-4a9e6039faca) code tied to a phone number | SMS | PIN generated locally, shown on the Mac. The warning "Never enter a code if you didn't request it" still applies verbatim. |
| [YouTube](https://mobbin.com/flows/eddbf94d-3a86-4fb0-80c2-d8f7124b465c) / [Tubi](https://mobbin.com/flows/964eb5fe-7b19-435b-9548-942177b6e5ae) activation codes | Vendor server validates | Identical UI, validation moves to `pair` on the bridge. Teaching copy transfers unchanged. |
| [Alexa](https://mobbin.com/flows/ae937a1f-5150-4d20-82be-f9aa49fbbfd9) "Save your password to Amazon", Sidewalk consent | Credential upload | Nothing leaves the LAN, and the pair screen should say so: "Nothing is sent to the internet. The PIN only travels between this phone and the Mac on your Wi-Fi." A gurdwara handing a controller to volunteers will ask. |
| [Telegram's active-sessions registry with per-session **Terminate**](https://mobbin.com/flows/75beb711-228d-4f8e-8605-c9d9ea100f4e) | Cloud session store | Maps one-to-one onto `auth.json`. The Bridge already shows "N paired"; making that an enumerable list with per-device revoke means a volunteer's borrowed phone can be unpaired after a service without resetting the PIN for everyone. |
| [Fitbit](https://mobbin.com/flows/6283ce10-f407-4690-8526-889549b93aeb) / [Roku](https://mobbin.com/screens/170f42d7-10a4-4cda-af37-cf3791ca58df) local-network permission priming | None, already local | Adopt as-is for the iOS build. This is the one iOS permission that fails **silently and permanently**, and both apps prove the fix is one explanatory screen fired before the OS alert. |

# Security Policy

Open OBSBOT Remote is a LAN-only camera-control tool. The bridge listens on all interfaces so phones on the same network can connect, but camera commands require pairing with a 6-digit PIN and then a saved bearer token.

## Threat Model

In scope:

- A device on the same local network tries to pair or control the camera.
- A paired device is lost or should no longer have access.
- A token leaks from a paired browser/app.

Out of scope:

- Public internet exposure. Do not port-forward ports `8765` or `8766`.
- A compromised user account on the bridge host.
- Other local apps that already have camera or USB access.

## Current Protections

- Camera commands require a valid token.
- Pairing requires the bridge PIN shown locally in the bridge app.
- MJPEG preview requires `?t=<token>`.
- Pairing can be reset from the bridge app, which revokes issued tokens.

## Known Gaps

- No TLS. Traffic is plain `ws://` and `http://` on the local network.
- No PIN attempt rate limit yet.
- Tokens are bearer tokens. Anyone who obtains one can use it until pairing is reset.
- The bridge is intended for trusted LANs, not shared/public networks.

## Reporting A Vulnerability

Do not open a public issue with exploit details.

Use the repository's private vulnerability reporting channel if enabled. If that is not available, contact the maintainer privately and include:

- A short impact summary.
- Reproduction steps.
- Whether a paired token or only LAN access is required.
- Relevant bridge log lines with secrets removed.

## Hardening Checklist

- Keep the bridge on a trusted network.
- Do not expose ports `8765` or `8766` to the public internet.
- Reset pairing after a device is lost or shared accidentally.
- Quit OBSBOT Center and other camera-control apps before launching the bridge.
- Consider a separate VLAN or isolated Wi-Fi for camera/control devices in shared venues.

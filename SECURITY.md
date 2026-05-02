# Security policy

Open OBSBOT Control is a LAN-only tool. The bridge listens on `0.0.0.0` and gates access via a 6-digit pairing PIN + 32-byte bearer token. Wi-Fi WPA2/WPA3 already encrypts traffic on the wire.

## Threat model (today)

In scope:
- Anyone on the same Wi-Fi as the bridge can attempt to pair.
- A compromised paired phone can issue any camera command.
- A malicious LAN device cannot send camera commands without the PIN.

Out of scope (not protected):
- Public-internet exposure (port-forwarding the bridge: don't, no TLS, no rate limit).
- Compromised macOS user account on the bridge machine.
- Side-channel via OBSBOT Center (different app, different process).

## What could go wrong

- **PIN brute-force.** 6 digits = 1M combinations. With no rate limit currently, a malicious LAN device could try ~10/sec and succeed in ~14 hours expected. Acceptable on home Wi-Fi; not acceptable on shared / public networks.
- **Token replay.** Tokens are sent in plaintext over `ws://` and `http://`. Anyone sniffing the LAN (hard on WPA2/3) could capture and reuse.
- **No TLS.** Self-signed certs for arbitrary LAN IPs aren't browser-trusted. The pragmatic path for TLS on a LAN is to put both bridge and clients on a Tailscale tailnet (Tailscale issues free `*.ts.net` certs).

## Reporting a vulnerability

Please email `info.sandhukirat23@gmail.com` (the maintainer) with subject `[SECURITY] open-obsbot-remote: <short description>`.

Do **not** open a public GitHub issue for security problems.

We aim to respond within 7 days. If you don't hear back, escalate by tagging `@0xharkirat` in a public issue with no details — the maintainer will follow up privately.

## Hardening checklist for power users

- Use a separate IoT / camera Wi-Fi VLAN for the Mac if your network supports it.
- Don't port-forward 8765 / 8766 to the public internet.
- Reset the pairing PIN after a known-bad device touched it (Reveal → Reset pairing in the bridge UI).
- Run the bridge under a dedicated macOS user account with limited disk access.

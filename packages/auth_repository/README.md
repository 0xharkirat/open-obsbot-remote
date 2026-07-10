# auth_repository

PIN-pairing and per-bridge token auth for the Open OBSBOT Remote (v2).
One layer above [`obsbot_api_client`](../obsbot_api_client): it runs the
`hello` / `pair` handshake, persists the token, and publishes an
`AuthStatus` stream the app routes off.

## What it does

- `authenticate()` reads the saved token (key `token::<hostPort>`), sends
  `hello`, and settles the status.
  - Success -> `authenticated`.
  - `auth_required` -> `unauthenticated`. This is a state transition, not an
    error, so it does not throw and carries no message (see the #41 rule
    below).
  - Any other action error, or a transport failure, propagates untouched.
- `pair(pin)` sends `pair`; on success the bridge acks a 32-byte-hex token,
  which is saved and flips status to `authenticated`. A wrong PIN throws
  `PairException`.
- `logOut()` deletes the stored token and drops to `unauthenticated`.
- `status` is a broadcast stream that replays the latest value to late
  listeners. `current` is the synchronous latest; `token` is the saved token
  (the MJPEG preview URL builder appends it as `?t=<token>`).

## What it deliberately does not do

- No `shared_preferences`, no secure-storage, no file I/O. Persistence is the
  `AuthStorage` interface; the Flutter app injects the real implementation and
  tests use `InMemoryAuthStorage`. Keeps the package pure Dart.
- No URI parsing. The caller passes `hostPort` (for example
  `192.168.1.50:8765`); the repository only uses it to key the token. This is
  why two bridges on one LAN never share a token, and why this package stays
  out of the `ws://host:port/v1` vs MJPEG-port arithmetic that lives elsewhere.
- No ownership of the `ObsbotApiClient`. It is injected; `dispose()` closes
  only this repository's status stream, never the transport.
- No connection management, no reconnection, no state fan-out beyond auth. It
  answers exactly one question: is this phone paired with this bridge?

## Why `AuthStatus` is a plain enum

`unknown` / `unauthenticated` / `authenticated`, an enum, not a sealed class.
A sealed hierarchy buys the ability to attach a payload per variant, and that
is precisely what we do not want here. The one plausible payload -
a message on `unauthenticated` - is the bug this package exists to prevent
(below). None of the three states carries data: the token lives on `token`,
and a real failure is thrown (`PairException`), never stashed in a variant. An
enum makes the "no payload anywhere" guarantee structural instead of a
convention a future edit could break.

## The CLAUDE.md #41 rule, structurally enforced

The bridge's `auth_required` ack carries a `msg` that is a raw developer
hint (`"send {action:'pair', pin:<6-digit>} ..."`). v1 rendered it as red
error text under the PIN field. Entering the pair state is a **state
transition, not an error**.

This package makes that leak impossible rather than merely avoided:

1. `authenticate()` maps `ApiActionException(code: 'auth_required')` to the
   `AuthStatus.unauthenticated` transition and never reads `exception.message`.
2. `AuthStatus.unauthenticated` is an enum value with no field to hold a
   message.
3. `PairException` (the wrong-PIN path) carries only `code`, never the `msg`.

There is nowhere for the hint to go. A test (`auth_required ... no msg leak`)
feeds the exact bridge hint string through and asserts it surfaces nowhere.

## Testing

```bash
very_good test    # a repo hook blocks bare `dart test`
```

Mocktail fakes `ObsbotApiClient`; `InMemoryAuthStorage` stands in for
persistence. Covered: saved-token reuse, token-less `hello`, the `auth_required`
transition with no message leak, per-host token keying on pair, wrong-PIN
`PairException` with the hint suppressed, transport failures staying
un-wrapped, `logOut`, and the status stream replaying to late listeners.

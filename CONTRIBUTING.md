# Contributing to Open OBSBOT Control

Thanks for considering a contribution. Bug reports, feature ideas, and PRs are welcome.

## Quick orientation

Read these in order before changing behavior:

1. [README.md](README.md) — what this project is and how it's wired.
2. [AGENTS.md](AGENTS.md) — repo layout, conventions, and project-specific gotchas for AI coding tools.
3. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the bigger picture of how the bridge / phone / web pieces fit.
4. [docs/PROTOCOL.md](docs/PROTOCOL.md) — the WS message format.

## Setup

You will need:
- macOS Apple Silicon for the current bridge app build
- `brew install cmake asio`
- A copy of the OBSBOT C++ SDK (see [docs/GETTING_THE_SDK.md](docs/GETTING_THE_SDK.md)) extracted at `third_party/obsbot-sdk/`
- An OBSBOT camera plugged in (Tiny 2 Lite is the only model exercised today)
- Flutter 3.27+

```bash
git clone <repo-url>
cd open-obsbot-remote
# drop the SDK into third_party/obsbot-sdk/ first
./scripts/verify-sdk.sh
./scripts/build-bridge-mac.sh
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
```

## Branching + PRs

- Create a feature branch off `main` named `feat/<short-thing>` or `fix/<short-thing>`.
- Keep PRs small and focused. One feature per PR.
- Reference the issue number in the PR description.
- Run `flutter analyze` and the bridge build before pushing.

## Commit messages

Conventional Commits-ish:

```
feat(bridge): add ping-pong loop mode for sequencer
fix(rc): stable TextEditingController per sequencer step
docs(claude): note SIGPIPE handling
```

Use `Co-Authored-By` footers when required by your workflow or organization.

## Style

- C++17, no exceptions across the libdev boundary, prefer RAII.
- Dart/Flutter: follow `package:flutter_lints` — `flutter analyze` should be clean.
- 4-space indent in C++ headers/cpp (match existing files); 2-space indent in Dart.
- Prefer narrow struct extensions to flag-bag refactors.

## Adding a feature

If your change touches the WS protocol:

1. Update [docs/PROTOCOL.md](docs/PROTOCOL.md) **first**.
2. Implement in `bridge_cpp/src/protocol.cpp` and the relevant `device_session.cpp` method.
3. Implement in `apps/rc/lib/ws_client.dart` (Dart side).
4. Wire UI in the appropriate screen.
5. Update [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]`.

If your change touches the bridge subprocess lifecycle:

1. Read CLAUDE.md §"Things that bit us" first — there's a high chance the new failure mode is already known.
2. If you're adding a new exit path, ensure `signal(SIGPIPE, SIG_IGN)` and `_Exit(0)` semantics still hold.

## Testing

- Manual test plan in [docs/RUN.md](docs/RUN.md).
- Unit tests for the bridge are not set up yet (TODO).
- `flutter test` covers the Dart side; we don't have integration tests yet.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml) when the repo is public. Include:
- Bridge log: `~/Library/Logs/Open OBSBOT Bridge/bridge.log` (last ~200 lines, or filtered with `grep -vE "sendMsgSync, cmd_id = 11; cmd_set = 3"` to skip gimbal-poll spam)
- Phone OS + browser/app version
- Camera model + firmware (visible in bridge UI)

## Code of conduct

By participating you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Contributions are accepted under the same Apache 2.0 license as the rest of the repo. See [LICENSE](LICENSE).

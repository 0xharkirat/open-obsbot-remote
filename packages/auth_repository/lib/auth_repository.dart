/// PIN-pairing and per-bridge token auth for the Open OBSBOT Remote.
///
/// One layer above [obsbot_api_client]. It reads and writes the saved token,
/// runs the `hello` / `pair` handshake, and publishes an [AuthStatus] stream
/// the app drives its routing off. It deliberately keeps the bridge's
/// developer-facing `msg` hints out of anything user-visible; see CLAUDE.md
/// #41 and the `unauthenticated` transition in [AuthRepository.authenticate].
library;

export 'src/auth_repository.dart';
export 'src/auth_status.dart';
export 'src/auth_storage.dart';
export 'src/pair_exception.dart';

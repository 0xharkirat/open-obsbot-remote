/// Where the phone stands with one bridge.
///
/// Deliberately a plain enum. None of the three states carries a payload,
/// and that is the point: [unauthenticated] has nowhere to hold the bridge's
/// developer-facing `auth_required` hint, so CLAUDE.md #41 cannot reopen. The
/// token lives on `AuthRepository.token`, not here; an error, when one is
/// real, is thrown (see `PairException`), never stashed in a status variant.
enum AuthStatus {
  /// Nothing has been tried yet. The initial value before `AuthRepository`
  /// has spoken to the bridge.
  unknown,

  /// The bridge demands a PIN. Reached when a token-less or stale-token
  /// `hello` is rejected, and after `logOut`. Carries no error.
  unauthenticated,

  /// The bridge accepted our token (or a fresh pair). Commands may flow.
  authenticated,
}

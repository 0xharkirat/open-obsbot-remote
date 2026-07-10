/// A pair attempt the bridge actively rejected, most often a wrong PIN.
///
/// This is distinct from a transport failure: `AuthRepository.pair` lets
/// `ApiConnectionException` and `ApiTimeoutException` propagate untouched, so
/// catching [PairException] means "the bridge said no", while catching those
/// means "we could not reach the bridge". The UI branches on the type.
///
/// It carries only [code], the machine-readable `err` (for example
/// `auth_failed`). It deliberately does NOT carry the bridge's `msg`: that
/// field is a developer-facing protocol hint and rendering it as user copy is
/// the exact bug CLAUDE.md #41 documents. There is no slot here to leak it.
class PairException implements Exception {
  const PairException(this.code);

  /// The bridge's machine-readable `err` code. Switch on it; do not display
  /// it raw. `auth_failed` is the wrong-PIN case; `no_token` is a bridge that
  /// acked success but omitted the token (a protocol violation, not a wrong
  /// PIN, but still "pairing did not work" from the caller's point of view).
  final String code;

  @override
  String toString() => 'PairException($code)';
}

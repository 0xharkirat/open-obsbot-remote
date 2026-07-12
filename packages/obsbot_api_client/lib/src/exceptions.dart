/// Base for every failure surfaced by [ObsbotApiClient].
sealed class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The socket could not be opened, or died underneath us.
class ApiConnectionException extends ApiException {
  const ApiConnectionException(super.message);
}

/// The bridge never acked an action within the deadline.
class ApiTimeoutException extends ApiException {
  const ApiTimeoutException(super.message);
}

/// The bridge acked with `ok: false`.
///
/// [code] is the machine-readable `err` field (`no_device`,
/// `device_required`, `not_found`, `auth_required`, ...). Switch on it.
///
/// [message] is the bridge's `msg` field. It is a DEVELOPER-facing hint,
/// sometimes containing raw protocol shape. Never render it as user copy.
/// See CLAUDE.md #41 for the bug this caused.
class ApiActionException extends ApiException {
  const ApiActionException(this.code, super.message);

  final String code;

  @override
  String toString() => 'ApiActionException($code): $message';
}

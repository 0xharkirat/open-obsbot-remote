/// Key-value persistence for the per-bridge auth token.
///
/// The package stays pure Dart by refusing to know about `shared_preferences`,
/// secure storage, or files. The Flutter app supplies a real implementation;
/// tests use [InMemoryAuthStorage].
abstract interface class AuthStorage {
  /// Returns the stored value for [key], or null if absent.
  Future<String?> read(String key);

  /// Writes [value] under [key], overwriting any prior value.
  Future<void> write(String key, String value);

  /// Removes [key]. A no-op if it was not present.
  Future<void> delete(String key);
}

/// A volatile [AuthStorage] backed by a map. Shipped so tests (and throwaway
/// spikes) need no platform plugin. Not for production: it forgets everything
/// when the process ends.
class InMemoryAuthStorage implements AuthStorage {
  final _store = <String, String>{};

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }
}

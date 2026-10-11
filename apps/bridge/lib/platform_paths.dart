import 'dart:io';

/// Where the bridge keeps its files, and how to show them to the user, per
/// platform. The C++ subprocess writes to the same places (`auth.cpp`,
/// `persist.cpp`, `log.h`), so the two sides must agree.
///
///   macOS    ~/Library/Application Support/Open OBSBOT Bridge/
///            ~/Library/Logs/Open OBSBOT Bridge/
///   Windows  %APPDATA%\Open OBSBOT Bridge\
///            %LOCALAPPDATA%\Open OBSBOT Bridge\Logs\
class PlatformPaths {
  PlatformPaths._();

  static const _appName = 'Open OBSBOT Bridge';

  static String get _home =>
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';

  /// Per-user app data: auth.json, sequences, mix library.
  static String get supportDir {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ?? '';
      return '$appData\\$_appName';
    }
    return '$_home/Library/Application Support/$_appName';
  }

  /// Directory the supervisor writes bridge.log into.
  static String get logDir {
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'] ?? '';
      return '$local\\$_appName\\Logs';
    }
    return '$_home/Library/Logs/$_appName';
  }

  static String get authJsonPath =>
      Platform.isWindows ? '$supportDir\\auth.json' : '$supportDir/auth.json';

  /// `path` with the home directory shortened to `~`, for display.
  static String displayPath(String path) {
    final home = _home;
    if (home.isEmpty) return path;
    return path.replaceAll(home, '~');
  }

  /// Short label for the app-data row in About.
  static String get supportDirLabel => Platform.isWindows
      ? '%APPDATA%\\$_appName\\'
      : '~/Library/Application Support/$_appName/';

  /// Name of the file manager, for button labels ("Reveal in Finder").
  static String get fileManagerName =>
      Platform.isWindows ? 'Explorer' : 'Finder';

  /// Open a folder in the platform file manager.
  static Future<void> openFolder(String path) async {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', <String>[path]);
    } else {
      await Process.run('open', <String>[path]);
    }
  }

  /// Open the file manager with `path` selected.
  static Future<void> revealFile(String path) async {
    if (Platform.isWindows) {
      // explorer returns exit code 1 even on success; ignore it.
      await Process.run('explorer.exe', <String>['/select,', path]);
    } else {
      await Process.run('open', <String>['-R', path]);
    }
  }
}

// Where the bridge keeps its state and log, per platform. Mirrors
// auth_store_path() / support_dir() in apps/bridge_cpp and
// apps/bridge/lib/platform_paths.dart.
import os from 'node:os';
import path from 'node:path';

const APP = 'Open OBSBOT Bridge';

export const SUPPORT_DIR = process.platform === 'win32'
  ? path.join(process.env.APPDATA ?? os.homedir(), APP)
  : `${os.homedir()}/Library/Application Support/${APP}`;

export const LOG_DIR = process.platform === 'win32'
  ? path.join(process.env.LOCALAPPDATA ?? os.homedir(), APP, 'Logs')
  : `${os.homedir()}/Library/Logs/${APP}`;

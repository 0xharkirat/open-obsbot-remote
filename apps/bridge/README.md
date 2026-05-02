# Open OBSBOT Bridge

Flutter macOS app that wraps the C++ `obsbot-bridge` subprocess in a single `.app` bundle.

## Responsibilities

- Start and supervise `apps/bridge_cpp/build/obsbot-bridge`.
- Pass the bundled web remote path to the subprocess.
- Show bridge status, camera permission state, detected camera, PIN, QR code, URL, paired-device count, and subprocess logs.
- Persist logs to `~/Library/Logs/Open OBSBOT Bridge/bridge.log`.
- Reset pairing state from the UI.
- Restart the subprocess after unexpected exits.
- Enforce a single running app instance.

## Build

From the repo root:

```bash
./scripts/build-bridge-mac.sh
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
```

The build script copies these files into the bundle:

- `obsbot-bridge`
- `libdev.dylib`
- Flutter web assets from `apps/rc/build/web`

It then ad-hoc signs the bundle. That is enough for local camera permission inheritance and release ZIP testing. The packaging script can re-sign the app with Developer ID for public releases.

## Package Release ZIP

From the repo root:

```bash
./scripts/package-mac-release.sh
```

The ZIP is written to `dist/` and includes:

- `Open OBSBOT Bridge.app`
- bundled `obsbot-bridge`
- bundled `libdev.dylib`
- bundled Flutter web remote assets

For a public release, install a `Developer ID Application` certificate and create a saved notarization profile:

```bash
xcrun notarytool store-credentials open-obsbot-notary \
  --apple-id "<apple-id>" \
  --team-id "<team-id>" \
  --password "<app-specific-password>"
```

Then package with notarization:

```bash
NOTARYTOOL_PROFILE=open-obsbot-notary ./scripts/package-mac-release.sh 1.0.0
```

The script auto-detects a `Developer ID Application` identity. Set `SIGN_IDENTITY="Developer ID Application: ..."` if more than one identity exists.

## Notes

- The internal Dart package name is still `obsbot_bridge_mac`; do not rename it casually because imports depend on it.
- The bridge app is not sandboxed. The bridge needs raw USB camera access and local TCP listeners.
- The public release ZIP is Apple Silicon only while `obsbot-bridge` and `libdev.dylib` are arm64-only.
- Without a Developer ID certificate and notarization profile, release packaging falls back to ad-hoc signing.

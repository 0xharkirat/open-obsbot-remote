# Open OBSBOT Remote

Flutter controller app for Open OBSBOT Bridge.

Targets:

- Web, served by the bridge from `http://<bridge-host>:8765/`.
- Android native.
- iOS native.

## Development

From this directory:

```bash
flutter pub get
flutter run -d chrome
flutter run -d <device-id>
```

For normal end-to-end testing, build and launch the bridge app from the repo root:

```bash
./scripts/build-bridge-mac.sh
open "apps/bridge/build/macos/Build/Products/Release/Open OBSBOT Bridge.app"
```

Then open the bridge URL shown in the bridge app.

## Builds

```bash
flutter build web --release
flutter build apk --release
flutter build ios --release
```

The macOS bridge build script runs `flutter build web --release` here and bundles the output into `Open OBSBOT Bridge.app`.

## Notes

- The internal pubspec name is still `obsbot_control`; do not rename it casually because imports depend on it.
- Android allows cleartext LAN traffic for `ws://` and `http://`.
- iOS needs Local Network permission to connect to the bridge.
- Flutter web preview uses an HTML `<img>` element for MJPEG because Flutter image widgets do not decode multipart streams.

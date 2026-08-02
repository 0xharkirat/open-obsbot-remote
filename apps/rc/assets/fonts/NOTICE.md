# Bundled fonts

These fonts ship inside the app on purpose. Flutter web renders text through
CanvasKit, which fetches any font it does not have from `fonts.gstatic.com` at
runtime. On a venue with no internet that produced a remote with icons and no
text at all, which is the failure this directory exists to prevent. A control
surface for cameras on a local network must not depend on a font CDN.

## Roboto

- Files: `Roboto-Regular.ttf`, `Roboto-Medium.ttf`, `Roboto-Bold.ttf`
- License: Apache License 2.0, full text in `Roboto_LICENSE.txt`
- Source: the Flutter SDK's own `bin/cache/artifacts/material_fonts`, so the
  bundled files match the version Flutter would otherwise download.
- Why: Roboto is Flutter's default text font on web. Declaring it here is what
  stops CanvasKit fetching it, and it is set as `fontFamily` in the app theme.

## Noto Sans Symbols

- File: `NotoSansSymbols-Regular.ttf`
- License: SIL Open Font License 1.1, text in `NotoSansSymbols_LICENSE.txt`
- Copyright: the Noto Project Authors, https://github.com/notofonts/notofonts.github.io
- Why: Roboto covers no arrows and few geometric symbols, and one missing glyph
  is enough to trigger a CDN fetch. This is registered as a `fontFamilyFallback`
  so those characters resolve locally.

## Checking this still holds

Load the remote and confirm no request leaves the machine:

```bash
curl -s http://localhost:8765/assets/FontManifest.json
```

Every family listed there is served by the bridge. If a future change renders a
character outside these fonts, CanvasKit will quietly start fetching again, so
watch the browser network panel for `fonts.gstatic.com` after any UI change that
introduces a new symbol.

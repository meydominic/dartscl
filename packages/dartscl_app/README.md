# dartscl_app

Flutter Web frontend of **DartSCL** — see the [root README](../../README.md)
for architecture, setup, API reference, and deployment.

## What lives here

- `lib/main.dart` — main scan screen: sidebar controls (scanner, DPI, color
  mode, source, output format, target mode), preview area, status bar,
  blob-URL downloads.
- `lib/api_service.dart` — backend client + Riverpod providers/notifiers
  (scanner list, capabilities, preview image, scan status, crop region).
- `lib/crop_overlay.dart` — interactive crop selection overlay.
- `test/widget_test.dart` — web-tagged smoke test (`@Tags(['web'])`); skipped
  on the Dart VM via `dart_test.yaml`.

## Run

```bash
# Backend must be running first (see root README), then:
flutter run -d chrome
```

## Test

```bash
flutter test                                   # VM run (web test skipped)
flutter test --platform chrome --run-skipped   # real web test
```

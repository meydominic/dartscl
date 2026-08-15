# DartSCL

Self-hosted **AirScan / eSCL scanner service** with a Flutter Web frontend.

DartSCL brings a macOS-like network scanning experience to any browser:
scanners on your local network are discovered automatically via mDNS,
you get an interactive preview with a draggable/resizable crop selection,
and final scans can be delivered as JPEG or assembled into PDF documents —
either as a brand-new PDF or appended page-by-page to an existing one.

```
┌──────────────────────┐      HTTP / JSON       ┌──────────────────────────┐
│  Flutter Web App     │  ───────────────────►  │  Dart Frog Backend       │
│  (dartscl_app)       │                        │  (dartscl_backend)       │
│  Riverpod state      │                        │  mDNS discovery          │
│  Crop overlay UI     │  ◄───────────────────  │  eSCL client (raw HTTP)  │
└──────────────────────┘   JPEG / PDF bytes     │  PDF pipeline            │
                                                │  static file serving     │
                                                └────────────┬─────────────┘
                                                             │ eSCL (HTTP/XML)
                                                ┌────────────▼─────────────┐
                                                │  Network scanners        │
                                                │  (EPSON, Brother, HP…)   │
                                                └──────────────────────────┘
```

The browser never talks to the scanner directly — all scanner communication is
proxied through the backend, which avoids CORS and mixed-content problems and
keeps scanner credentials/traffic off the client.

---

## Features

- **Automatic scanner discovery** via mDNS/DNS-SD (`_uscan._tcp.local` for HTTP,
  `_uscans._tcp.local` for HTTPS), including TXT-record parsing (`rs`, `adminurl`,
  `ty`) to resolve the correct eSCL base path per scanner model.
- **Capabilities pre-fetching** at server startup, cached for instant UI responses;
  fallback to on-demand fetching if the pre-fetch fails.
- **Interactive preview scan** (100 DPI) with a draggable, resizable crop overlay
  (corner handles, rule-of-thirds grid, minimum-size guard).
- **Software cropping** on the backend using relative `CropRegion` coordinates
  (0.0–1.0), independent of hardware crop support.
- **PDF pipeline** (pure Dart, no external binaries):
  - single-page PDF from a scanned image (`pdf` package),
  - append pages to a previously scanned PDF (`pdf_manipulator`),
  - chained appends (page 1 → page 2 → page 3 …) via a stable scan ID.
- **JPEG or PDF output**, either inline (preview) or as a browser download.
- **Mock fallback** for development without hardware (`DARTSCL_USE_MOCK`).
- **Single-container deployment** serving both the REST API and the compiled
  Flutter Web app (multi-stage Docker build, scratch runtime image).

---

## Repository structure (Dart workspace)

```text
dartscl/
├── pubspec.yaml                  # Workspace root (resolution: workspace)
├── AGENTS.md                     # Development rules for AI agents
├── README.md                     # This document
├── Dockerfile                    # Multi-stage build (Flutter Web + Dart AOT)
├── docker-compose.yml            # Host-network container deployment
├── packages/
│   ├── dartscl_protocol/         # Shared Dart models (JSON-serializable)
│   │   └── lib/src/models.dart   #   ScannerDevice, CropRegion, ScanJobConfig, enums
│   ├── dartscl_backend/          # Dart Frog microservice
│   │   ├── routes/               #   HTTP routes + middleware
│   │   ├── lib/src/              #   eSCL client, mDNS discovery, PDF pipeline
│   │   └── static/               #   Compiled Flutter Web build (build artifact, not in git)
│   └── dartscl_app/              # Flutter Web frontend (web-only)
│       ├── lib/                  #   main.dart, api_service.dart, crop_overlay.dart
│       ├── test/                 #   Web-tagged widget test
│       └── web/                  #   Web entry point
```

---

## Tech stack

| Layer      | Technology |
|------------|------------|
| Backend    | Dart Frog (`dart_frog`), `dart:io` raw `HttpClient` for scanner I/O |
| Frontend   | Flutter (Web only), `flutter_riverpod`, `google_fonts` |
| Discovery  | `multicast_dns` (mDNS / DNS-SD) |
| eSCL       | HTTP REST + XML (Apple AirScan), raw XML templates |
| Images     | `image` (decode, crop, re-encode) |
| PDF        | `pdf` (page generation), `pdf_manipulator` (merge/append) |
| Models     | `json_annotation` / `json_serializable` (codegen) |
| Deployment | Docker multi-stage, scratch runtime |

---

## Prerequisites

- **Dart SDK** ≥ 3.5 (developed against 3.13)
- **Flutter** ≥ 3.44 (developed against 3.47) — only needed for the frontend
- A scanner with eSCL/AirScan support on the same local network (optional —
  mock mode works without hardware)
- `dart_frog_cli` — only required to regenerate the production server build
  (`dart pub global activate dart_frog_cli`)

---

## Quick start (development)

All packages are part of one Dart workspace, so dependency resolution happens
once from the repository root:

```bash
# 1. Resolve dependencies for the whole workspace
dart pub get

# 2. Start the backend (port 8080 by default)
cd packages/dartscl_backend
dart run .dart_frog/server.dart

# 3. In a second terminal, start the Flutter Web app
cd packages/dartscl_app
flutter run -d chrome
```

Open the app in Chrome and scan away. The app automatically resolves the
backend base URL (`ApiService`): same-origin (relative URLs) when served by
the backend itself on port 8080, otherwise `http://localhost:8080` as the
development fallback. Override it explicitly with a dart-define if needed
(see [Frontend configuration](#frontend-configuration)).

> **Dev vs. prod static serving:** in development, the app runs on its own dev
> server and talks to the backend via CORS (enabled). In production, the compiled
> app is served by the backend itself from `static/` (see Docker below).

---

## Configuration

### Environment variables (backend)

| Variable          | Default | Description |
|-------------------|---------|-------------|
| `PORT`            | `8080`  | HTTP port the backend listens on |
| `DARTSCL_USE_MOCK`| `true`  | Mock scanner fallback when mDNS finds no devices. Set to `false` to disable (registry reports zero devices instead) |

### Frontend configuration (build-time dart-define)

| Dart-define                   | Default | Description |
|-------------------------------|---------|-------------|
| `DARTSCL_API_BASE_URL`        | *(auto)* | Overrides the backend API base URL. When unset, the app uses same-origin relative URLs if it is served on port 8080 (production deployment by the backend), otherwise `http://localhost:8080` (development). |

```bash
# Development against a backend on another host:
flutter run -d chrome --dart-define=DARTSCL_API_BASE_URL=http://192.168.1.50:8080

# Production build targeting a remote backend:
flutter build web --dart-define=DARTSCL_API_BASE_URL=https://scanner.example.com
```

### Notes

- **Mock mode** only kicks in when mDNS discovers **no** real devices. If real
  scanners are found, mocks are never used.
- Mock scanner IDs start with `mock-` (`mock-1`, `mock-2`); real scanner IDs
  have the form `<ip>_<port>`, e.g. `192.168.1.152_443`.
- The mock scanner returns a programmatically generated 16×16 px gray JPEG —
  deliberately generated (not hardcoded) so that every mock-based code path
  (crop, PDF conversion) is fully exercisable.

---

## API reference

Base URL: `http://<host>:8080`

### `GET /api/v1/scanners`

Returns all currently discovered/cached scanners (instant, no network I/O after
startup).

```json
[
  {
    "id": "192.168.1.152_443",
    "name": "EPSON WF-C5790 Series",
    "ip": "192.168.1.152",
    "port": 443,
    "path": "/eSCL",
    "isSecure": true
  }
]
```

### `GET /api/v1/scanners/[id]/capabilities`

Returns normalized, cached capabilities of a scanner (fetched on demand if the
startup pre-fetch failed). Unknown scanner → `404`.

```json
{
  "scannerId": "192.168.1.152_443",
  "makeAndModel": "EPSON WF-C5790 Series",
  "dpi": [100, 200, 300, 600, 1200],
  "colorModes": ["BlackAndWhite1", "Grayscale8", "RGB24"],
  "sources": ["platen", "adf"],
  "maxWidth": 2550,
  "maxHeight": 3510,
  "documentFormats": ["application/pdf", "image/jpeg"]
}
```

### `POST /api/v1/scan`

Triggers a scan. Request body is a `ScanJobConfig` (see `dartscl_protocol`):

```json
{
  "scannerId": "192.168.1.152_443",
  "intent": "preview",
  "source": "platen",
  "dpi": 100,
  "colorMode": "RGB24",
  "crop": { "xRatio": 0.1, "yRatio": 0.1, "widthRatio": 0.8, "heightRatio": 0.8 },
  "targetMode": "newPdf",
  "targetPdfId": null,
  "documentFormat": "image/jpeg"
}
```

| Field            | Type                | Description |
|------------------|---------------------|-------------|
| `scannerId`      | string              | Scanner ID from `GET /api/v1/scanners` |
| `intent`         | `preview`/`finalScan` | Preview returns inline JPEG; finalScan downloads |
| `source`         | `platen`/`adf`      | Flatbed or document feeder |
| `dpi`            | int                 | Resolution; must be in the scanner's supported list |
| `colorMode`      | string              | e.g. `RGB24`, `Grayscale8`, `BlackAndWhite1` |
| `crop`           | object (optional)   | Relative 0.0–1.0 crop region |
| `targetMode`     | `newPdf`/`append`   | Only relevant for PDF output |
| `targetPdfId`    | string (optional)   | Stable scan ID of a previous PDF; required for `append` |
| `documentFormat` | `image/jpeg`/`application/pdf` | Output format (default `image/jpeg`) |

**Responses:**

- `200` — binary body:
  - preview → `Content-Type: image/jpeg`, inline
  - finalScan JPEG → `image/jpeg`, `Content-Disposition: attachment`
  - finalScan PDF → `application/pdf`, `Content-Disposition: attachment`,
    plus `X-Scan-Id` header with the **stable scan ID** to use as
    `targetPdfId` for the next append scan.
- `400` — invalid `targetPdfId` format (only UUIDs are accepted — prevents path
  traversal) or `targetMode: append` without `targetPdfId`
- `404` — unknown `scannerId`
- `405` — wrong HTTP method
- `503` — scanner busy (`{"error": "scanner_busy"}`)
- `500` — other scanner/processing errors (`{"error": "<message>"}`)

### Static file serving

`GET /` and any non-`/api/` path serve the compiled Flutter Web app from
`static/`, with an SPA fallback to `index.html` for client-side routes.

---

## eSCL integration & scanner compatibility

The backend speaks raw eSCL (Apple AirScan): REST + XML against the scanner's
`/eSCL` base path. All scanner communication uses a **raw `dart:io`
`HttpClient`** (never `package:http`) — several embedded scanner TLS stacks
silently reject requests that go through the `package:http` IOClient wrapper.

Key compatibility decisions (verified against an **EPSON WF-C5790 Series**):

| Quirk | Handling |
|-------|----------|
| Scanner rejects Dart's default User-Agent | Every request sends `User-Agent: curl/8.7.1` |
| Scanner rejects `; charset=utf-8` on Content-Type | `Content-Type: text/xml` set via raw header (no charset) |
| `ScanIntent=Document`/`TextAndGraphic`/`Photo` rejected (409/503) | Always sends `Preview` intent — resolution is controlled by `XResolution`/`YResolution`, not the intent |
| Scanner always delivers JPEG, even when PDF requested | eSCL always requests `image/jpeg`; PDF conversion happens in the backend pipeline |
| Unsupported DPI produces empty-body 409 | DPI values come from the parsed `ScannerCapabilities` (`DiscreteResolution`), never guessed |
| Stale "Processing" jobs block new scans (503) | `ScannerStatus` is polled before every job; stale jobs are consumed via `NextDocument` and cancelled via `DELETE` |
| DELETE only succeeds after `NextDocument` | Job cleanup always calls `NextDocument` first, then `DELETE` |
| `Location` header advertises `http://` but eSCL lives on HTTPS 443 | Job URLs are rebuilt with the device's actual scheme/port |
| 409 conflict body may contain the job URL | 409 response body is parsed as XML; conflict job cancelled, then one retry |

The XML payload is built from a raw string template (no `XmlBuilder`) and looks
like:

```xml
<?xml version="1.0" encoding="utf-8"?>
<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.0</pwg:Version>
  <pwg:ScanIntent>Preview</pwg:ScanIntent>
  <scan:InputSource>Platen</scan:InputSource>
  <scan:ColorMode>RGB24</scan:ColorMode>
  <scan:XResolution>300</scan:XResolution>
  <scan:YResolution>300</scan:YResolution>
  <scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
</scan:ScanSettings>
```

### mDNS discovery

- Queries `_uscan._tcp.local` (HTTP) and `_uscans._tcp.local` (HTTPS).
- Resolves SRV (host/port) and TXT records; parses `rs` (eSCL path), `adminurl`
  and `ty` (display name) with sensible fallbacks.
- A scanner announced over plain HTTP but serving on port 443 is automatically
  marked as secure (`isSecure`).
- Discovery runs once at startup; `refreshScanners()` re-runs it (the UI exposes
  a reload button).

---

## PDF pipeline & append flow

1. Scan job created via eSCL; image bytes polled from `NextDocument`
   (1-second interval, up to 60 attempts).
2. Optional software crop via `image` package (`cropImage`).
3. JPEG → single-page PDF via `pdf` package.
4. **New PDF:** stored under a fresh UUID (`scanId`), returned as `X-Scan-Id`.
5. **Append:** merged with the stored target PDF via `pdf_manipulator`
   (`pdf.merge`), the result **overwrites** the stored file, and the same
   stable `X-Scan-Id` is returned — so any number of appends chain onto the
   previous result (1 → 2 → 3 pages …).
6. Temporary files (`*_newpage.pdf`, `*_output.pdf`) are deleted in a `finally`
   block; only the persisted PDFs for append chaining remain in the system temp
   directory.

The frontend stores the last `X-Scan-Id` and sends it as `targetPdfId` when
`targetMode` is `append`; the UI disables the "Append to PDF" option until a
PDF has been scanned in the current session.

---

## Frontend (Flutter Web)

- **State management:** Riverpod (`flutter_riverpod`). Providers/notifiers for
  scanner list, selected scanner, capabilities, preview image, scan status and
  crop region (see `lib/api_service.dart`).
- **Main screen** (`lib/main.dart`): sidebar with scanner/settings dropdowns
  (DPI, color mode, source, output format, target mode) + preview area with
  status bar and crop overlay.
- **Crop overlay** (`lib/crop_overlay.dart`): `CustomPainter`-based selection
  box with corner resize handles, move gesture, rule-of-thirds grid, and
  relative-coordinate mapping to `CropRegion`.
- **Downloads** use the standard `package:web` blob-URL pattern
  (`web.Blob` + `HTMLAnchorElement`), no `dart:html`.
- The app is **web-only** (`package:web` / `dart:js_interop`); there are no
  Android/iOS folders.

---

## Tests

```bash
# Analyzers (all three packages)
(cd packages/dartscl_protocol && dart analyze)
(cd packages/dartscl_backend && dart analyze)
(cd packages/dartscl_app && flutter analyze)

# App tests
cd packages/dartscl_app
flutter test                        # VM run: web-only test is skipped cleanly
flutter test --platform chrome --run-skipped   # actual web test in Chrome
```

The widget test is tagged `@Tags(['web'])` and skipped on the Dart VM via
`dart_test.yaml` because `dart:js_interop` is not available there.

---

## Docker & deployment

```bash
# Build (amd64 default)
docker build -t dartscl .

# On Apple Silicon:
docker build --platform linux/amd64 -t dartscl .

# Run — host networking is REQUIRED for mDNS discovery
docker run --rm --network host dartscl
```

Or with Compose:

```bash
docker compose up -d --build
```

The image serves both the REST API and the Flutter Web UI on port 8080.

**Build pipeline** (`Dockerfile`):

1. **Flutter builder** (`cirrusci/flutter:stable`) — `flutter build web --release`
2. **Dart builder** (`dart:stable`) — installs `dart_frog_cli`, runs
   `dart_frog build`, AOT-compiles the server to a standalone binary
3. **Runtime** (`scratch`) — binary + static web assets only (~25 MB)

> Note: `.dockerignore` excludes `pubspec.lock`, so the image resolves
> dependencies fresh at build time.

To serve the web UI from a bare-metal backend (no Docker), generate `static/`
manually:

```bash
cd packages/dartscl_app && flutter build web --release
rm -rf ../dartscl_backend/static
cp -r build/web ../dartscl_backend/static
```

---

## Known limitations

- **Stored PDFs have no TTL**: PDFs persisted for append chaining live in the
  system temp directory and are never garbage-collected. A long-running server
  will accumulate them; a restart clears them. A cleanup policy (age-based or
  per-session) is a candidate improvement.
- **Preview DPI is fixed at 100** in the frontend (safe across scanners,
  EPSON-verified); the preview does not use the user-selected DPI.
- **Single-user assumption**: the backend keeps one in-memory scanner/capability
  cache and one job-URL registry; concurrent scans from multiple clients are not
  serialized.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `503 {"error": "scanner_busy"}` on scan | Scanner is warming up or busy (physically scanning). The backend already retries once with stale-job cleanup + 3 s cooldown; wait and retry. |
| Persistent 409 from the scanner | Usually an unsupported DPI or a request quirk — see the compatibility table above. The backend logs the full 409 body/headers at WARNING level. |
| No scanners found | mDNS needs the host network (Docker: `--network host`). Check that the scanner advertises eSCL (`_uscan`/`_uscans`). With no devices, mock mode kicks in unless `DARTSCL_USE_MOCK=false`. |
| Capabilities empty / defaults shown | Capabilities pre-fetch failed at startup (scanner off/away); the UI falls back to defaults and the backend re-fetches on demand. |
| Web test fails on the VM | Expected — run with `--platform chrome --run-skipped` (see Tests). |

---

## Development conventions

- See `AGENTS.md` for the binding rules (English-only code/docs, no deprecated
  APIs, doc comments on every function, `flutter analyze` clean before shipping).
- The code and this README are the authoritative references for the current
  architecture and behavior.

# =============================================================================
# DartSCL — Multi-Stage Dockerfile
#
# Builds the Flutter Web frontend AND the Dart Frog backend in a single
# pipeline, producing a minimal scratch-based runtime image (~25 MB)
# that serves both the REST API and the web UI on port 8080.
#
# Usage:
#   docker build -t dartscl .
#   docker run --rm --network host dartscl
#
# Notes:
# - The toolchain is pinned. Flutter must be >= 3.47 because the app depends on
#   `material_ui` (Flutter deprecated `package:flutter/material.dart`), and the
#   previous `cirrusci/flutter:stable` image is stale and unmaintained.
# - Multi-arch: build for linux/amd64 by default. On Apple Silicon use:
#     docker build --platform linux/amd64 -t dartscl .
# - The container MUST run with --network host for mDNS discovery (Linux hosts;
#   Docker Desktop on macOS/Windows cannot use host networking).
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Pinned Flutter toolchain (shared by both builders)
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS flutter

ARG FLUTTER_VERSION=3.50.0

ENV FLUTTER_ROOT=/opt/flutter \
    PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
      -o /tmp/flutter.tar.xz \
 && tar -xJf /tmp/flutter.tar.xz -C /opt \
 && rm /tmp/flutter.tar.xz \
 && git config --global --add safe.directory /opt/flutter \
 && flutter --version

WORKDIR /workspace

# Workspace manifests first: dependency resolution is cached independently of
# source edits. The workspace resolves as a whole, so the app's manifest is
# required even in the server-only build — without it `dart pub get` fails with
# "No workspace packages matching 'packages/dartscl_app'". The Dart SDK is the
# Flutter-bundled one, because the app depends on `sdk: flutter`; the official
# `dart:stable` image cannot resolve this workspace at all.
COPY pubspec.yaml pubspec.lock ./
COPY packages/dartscl_protocol/pubspec.yaml ./packages/dartscl_protocol/
COPY packages/dartscl_app/pubspec.yaml ./packages/dartscl_app/
COPY packages/dartscl_backend/pubspec.yaml ./packages/dartscl_backend/
RUN dart pub get

# ---------------------------------------------------------------------------
# Stage 2: Flutter Web Builder
# ---------------------------------------------------------------------------
FROM flutter AS web-builder

COPY packages/dartscl_protocol/ ./packages/dartscl_protocol/
COPY packages/dartscl_app/ ./packages/dartscl_app/
RUN cd packages/dartscl_app && flutter build web --release

# ---------------------------------------------------------------------------
# Stage 3: Server Builder
# ---------------------------------------------------------------------------
FROM flutter AS server-builder

# Pin the CLI: a floating version can generate a server the `dart_frog`
# runtime in pubspec.yaml does not match.
RUN dart pub global activate dart_frog_cli 1.2.14
# dart_frog_cli installs to ~/.pub-cache/bin — add to PATH for the RUN below
ENV PATH="$PATH:/root/.pub-cache/bin"

COPY packages/dartscl_protocol/ ./packages/dartscl_protocol/

# Copy backend source (routes, lib, etc.)
COPY packages/dartscl_backend/ ./packages/dartscl_backend/

# Copy the Flutter Web build from stage 2 into the backend's static directory
COPY --from=web-builder /workspace/packages/dartscl_app/build/web \
    /workspace/packages/dartscl_backend/static

# Generate the Dart Frog production build (creates build/bin/server.dart)
RUN cd packages/dartscl_backend && dart_frog build

# Build the server as a CLI bundle with native assets.
#
# `dart build cli` (not `dart compile exe`) is required: pdf_manipulator ships
# its PDF engine (pdf_oxide) through the Dart build-hook protocol, so the
# resulting binary only works when the linked native library is bundled next
# to it. `dart compile exe` skips hooks entirely and produces a binary that
# throws "No available native assets" on the first PDF append.
RUN cd packages/dartscl_backend && dart build cli \
    --target=build/bin/server.dart \
    -o build/cli

# ---------------------------------------------------------------------------
# Stage 4: Minimal Runtime Image
# ---------------------------------------------------------------------------

# The official Dart image carries the shared libraries a compiled Dart binary
# needs (libc, libz, ...). It exists only to be copied into `scratch`.
FROM dart:stable AS dart-runtime

FROM scratch

# Dart runtime libraries (libc, libz, etc.)
COPY --from=dart-runtime /runtime/ /

# The server binary plus its bundled native libraries (pdf_oxide). The binary
# resolves them from a sibling `lib/` directory, so both must be copied.
COPY --from=server-builder /workspace/packages/dartscl_backend/build/cli/bundle/bin/server /app/bin/server
COPY --from=server-builder /workspace/packages/dartscl_backend/build/cli/bundle/lib/ /app/lib/

# Static web files (Flutter Web build). `cwd/static` is the server's first
# static-root candidate, so WORKDIR must be /app.
COPY --from=web-builder /workspace/packages/dartscl_app/build/web /app/static

WORKDIR /app

# Scan storage defaults (mount a volume at SCAN_STORAGE_PATH to persist).
# DARTSCL_USE_MOCK=false is explicit: mock scanners must never fabricate scans
# in a real deployment.
ENV SCAN_STORAGE_PATH=/app/scans \
    SCAN_MAX_STORAGE=1GB \
    SCAN_STORAGE_FULL_POLICY=error \
    SCAN_RETENTION_DAYS=365 \
    DARTSCL_USE_MOCK=false

EXPOSE 8080

CMD ["/app/bin/server"]

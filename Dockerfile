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
# - Multi-arch: build for linux/amd64 by default. On Apple Silicon use:
#     docker build --platform linux/amd64 -t dartscl .
# - The container MUST run with --network host for mDNS discovery.
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Flutter Web Builder
# ---------------------------------------------------------------------------
FROM cirrusci/flutter:stable AS flutter-builder

WORKDIR /workspace

# Copy workspace manifests first for Docker layer caching
COPY pubspec.yaml ./
COPY packages/dartscl_protocol/pubspec.yaml ./packages/dartscl_protocol/
COPY packages/dartscl_app/pubspec.yaml ./packages/dartscl_app/
COPY packages/dartscl_backend/pubspec.yaml ./packages/dartscl_backend/

# Resolve Flutter dependencies (cached unless pubspec changes)
RUN cd packages/dartscl_app && flutter pub get

# Copy all source and build
COPY packages/dartscl_app/ ./packages/dartscl_app/
COPY packages/dartscl_protocol/ ./packages/dartscl_protocol/
RUN cd packages/dartscl_app && flutter build web --release

# ---------------------------------------------------------------------------
# Stage 2: Dart Backend Builder
# ---------------------------------------------------------------------------
FROM dart:stable AS dart-builder

WORKDIR /workspace

# Install dart_frog CLI tool (needed to generate the production server)
RUN dart pub global activate dart_frog_cli
# dart_frog_cli installs to ~/.pub-cache/bin — add to PATH for the RUN below
ENV PATH="$PATH:/root/.pub-cache/bin"

# Copy workspace manifests first for caching
COPY pubspec.yaml ./
COPY packages/dartscl_protocol/pubspec.yaml ./packages/dartscl_protocol/
COPY packages/dartscl_backend/pubspec.yaml ./packages/dartscl_backend/

# Copy shared protocol package (path dependency)
COPY packages/dartscl_protocol/ ./packages/dartscl_protocol/

# Copy backend source (routes, lib, etc.)
COPY packages/dartscl_backend/ ./packages/dartscl_backend/

# Copy the Flutter Web build from stage 1 into the backend's static directory
COPY --from=flutter-builder /workspace/packages/dartscl_app/build/web \
    /workspace/packages/dartscl_backend/static

# Resolve all workspace dependencies
RUN dart pub get

# Generate the Dart Frog production build (creates build/bin/server.dart)
RUN cd packages/dartscl_backend && dart_frog build

# AOT-compile to a standalone Linux x86_64 binary
RUN dart compile exe \
    packages/dartscl_backend/build/bin/server.dart \
    -o /workspace/bin/server

# ---------------------------------------------------------------------------
# Stage 3: Minimal Runtime Image
# ---------------------------------------------------------------------------
FROM scratch

# Dart runtime libraries (libc, libz, etc.) provided by dart:stable
COPY --from=dart-builder /runtime/ /

# The AOT-compiled server binary
COPY --from=dart-builder /workspace/bin/server /app/bin/server

# Static web files (Flutter Web build)
COPY --from=dart-builder /workspace/packages/dartscl_backend/static /app/static

# Scan storage defaults (mount a volume at SCAN_STORAGE_PATH to persist)
ENV SCAN_STORAGE_PATH=/app/scans \
    SCAN_MAX_STORAGE=1GB \
    SCAN_STORAGE_FULL_POLICY=error \
    SCAN_RETENTION_DAYS=365

EXPOSE 8080

CMD ["/app/bin/server"]

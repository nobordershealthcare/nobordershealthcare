# physician-view — emergency QR display + clinician access logging
#
# Multi-stage build: builder stage compiles the binary; final stage is a
# distroless image (no shell, no package manager, minimal attack surface).
#
# Security properties:
#   - Distroless nonroot (gcr.io/distroless/static-debian12:nonroot)
#   - Binary compiled with CGO_ENABLED=0 (static, no libc dependency)
#   - No secrets in image — all config via environment variables at runtime
#   - Read-only root filesystem enforced by k8s securityContext
#
# Build:
#   docker build -t ghcr.io/nobordershealthcare/physician-view:latest .
#
# Digest-pin after build:
#   docker inspect --format='{{index .RepoDigests 0}}' \
#     ghcr.io/nobordershealthcare/physician-view:latest

# ── Stage 1: builder ────────────────────────────────────────────────────────
FROM golang:1.26-alpine AS builder

# Install CA certificates for TLS calls (Redis mTLS, Fabric gateway)
RUN apk add --no-cache ca-certificates

WORKDIR /src

# Cache module downloads before copying source so layer is reused on
# source-only changes.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO_ENABLED=0 produces a fully static binary — no glibc required.
# GOFLAGS=-trimpath removes local build paths from the binary.
RUN CGO_ENABLED=0 GOFLAGS=-trimpath \
    go build -ldflags="-s -w" -o /physician-view .

# ── Stage 2: final ──────────────────────────────────────────────────────────
# SECURITY: Pin to digest before deploying.
# Run: docker pull gcr.io/distroless/static-debian12:nonroot \
#        && docker inspect --format='{{index .RepoDigests 0}}' \
#           gcr.io/distroless/static-debian12:nonroot
# TODO: replace with digest-pinned reference before deploying to production.
# Run: docker inspect --format='{{index .RepoDigests 0}}' gcr.io/distroless/static-debian12:nonroot
FROM gcr.io/distroless/static-debian12:nonroot

# Copy CA bundle from builder (needed for mTLS to Redis and Fabric peers)
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy compiled binary
COPY --from=builder /physician-view /physician-view

# Copy HTML templates (read at startup via TEMPLATE_DIR env var)
# Default: /templates — override with TEMPLATE_DIR=/path/to/templates
COPY --from=builder /src/templates /templates

# Distroless nonroot runs as uid 65532 (nonroot) — no privilege needed
USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/physician-view"]

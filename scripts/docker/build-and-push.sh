#!/usr/bin/env bash
# build-and-push.sh — build the beszel-duck image (multi-arch) and push to a
# registry, so a production host can just `docker pull` + `docker compose up`.
#
# Build host needs: docker with buildx, and `docker login <registry>` already done.
#
# Usage:
#   REGISTRY=registry.example.com/you ./build-and-push.sh [TAG]
#
# Env:
#   REGISTRY        (required) e.g. docker.io/youruser  |  registry.lan:5000/beszel  |  ghcr.io/you
#   IMAGE           image name (default: beszel-duck)
#   TAG             tag (arg1 or env; default: today's date YYYYMMDD). 'latest' is always also pushed.
#   PLATFORMS       (default: linux/amd64,linux/arm64)
#   PUSH            true = push multi-arch to registry (default); false = build single-arch and --load locally
#   DUCKDB_VERSION  passthrough build-arg (default: the Dockerfile's ARG)
#   NO_CACHE        true = build with --no-cache (default: false)
#
# Examples:
#   REGISTRY=registry.lan:5000/beszel ./build-and-push.sh v1
#   REGISTRY=ghcr.io/me PLATFORMS=linux/amd64 ./build-and-push.sh 2026-05-29
#   PUSH=false ./build-and-push.sh test
#   REGISTRY=docker.io/madpenguin PUSH=true NO_CACHE=true ./build-and-push.sh latest

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"     # scripts/docker
CONTEXT="$(cd "$HERE/.." && pwd)"         # scripts/

: "${REGISTRY:?set REGISTRY, e.g. registry.example.com/you}"
IMAGE="${IMAGE:-beszel-duck}"
TAG="${1:-${TAG:-$(date +%Y%m%d)}}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PUSH="${PUSH:-true}"
NO_CACHE="${NO_CACHE:-false}"
REF="${REGISTRY%/}/${IMAGE}"

command -v docker >/dev/null || {
    echo "build-and-push.sh: docker not found" >&2
    exit 1
}

docker buildx version >/dev/null 2>&1 || {
    echo "build-and-push.sh: docker buildx required" >&2
    exit 1
}

# A multi-arch build needs the docker-container driver builder.
BUILDER="beszel-builder"
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
    docker buildx create --name "$BUILDER" --driver docker-container >/dev/null
fi

docker buildx use "$BUILDER"
docker buildx inspect --bootstrap >/dev/null

BUILD_ARGS=()
[[ -n "${DUCKDB_VERSION:-}" ]] && BUILD_ARGS+=(--build-arg "DUCKDB_VERSION=${DUCKDB_VERSION}")

BUILD_FLAGS=()
[[ "$NO_CACHE" == "true" ]] && BUILD_FLAGS+=(--no-cache)

if [[ "$PUSH" == "true" ]]; then
    OUTPUT=(--push)
    echo "==> building $REF:{$TAG,latest} for [$PLATFORMS] and PUSHing"
    [[ "$NO_CACHE" == "true" ]] && echo "==> cache disabled (--no-cache)"
else
    # --load can only import a single platform into the local docker image store
    OUTPUT=(--load)
    PLATFORMS=""
    echo "==> building $REF:{$TAG,latest} for the local arch and --loading (no push)"
    [[ "$NO_CACHE" == "true" ]] && echo "==> cache disabled (--no-cache)"
fi

set -x
docker buildx build \
    ${PLATFORMS:+--platform "$PLATFORMS"} \
    "${BUILD_FLAGS[@]}" \
    -f "$HERE/Dockerfile" \
    -t "$REF:$TAG" \
    -t "$REF:latest" \
    "${BUILD_ARGS[@]}" \
    "${OUTPUT[@]}" \
    "$CONTEXT"
set +x

echo
echo "Done: $REF:$TAG  (+ $REF:latest)"

if [[ "$PUSH" == "true" ]]; then
    echo "On the production host:"
    echo "  1) in scripts/docker/.env set:  DUCK_IMAGE=$REF:$TAG"
    echo "  2) docker compose pull && docker compose up -d"
fi

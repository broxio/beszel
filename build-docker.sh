#!/bin/bash
set -e

# Configuration
VERSION="${VERSION:-0.17.3}"
RELEASE="${RELEASE:-emp}"
REGISTRY="${REGISTRY:-}"  # e.g., ghcr.io/yourusername or docker.io/yourusername
PACKAGE="${1:-all}"  # agent, hub, agent-alpine, or all
PUSH="${PUSH:-false}"
NO_CACHE="${NO_CACHE:-false}"

# Platform configuration (from upstream workflow)
# Default: linux/amd64,linux/arm64,linux/arm/v7
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64,linux/arm/v7}"

# Full version tag
TAG="${VERSION}-${RELEASE}"

# Image names
if [ -n "$REGISTRY" ]; then
    AGENT_IMAGE="${REGISTRY}/beszel-agent"
    HUB_IMAGE="${REGISTRY}/beszel"
else
    AGENT_IMAGE="beszel-agent"
    HUB_IMAGE="beszel"
fi

echo "=============================================="
echo "Beszel Docker Image Builder"
echo "  Version:   ${TAG}"
echo "  Platforms: ${PLATFORMS}"
echo "  Package:   ${PACKAGE}"
echo "  Push:      ${PUSH}"
echo "  No-Cache:  ${NO_CACHE}"
if [ -n "$REGISTRY" ]; then
    echo "  Registry:  ${REGISTRY}"
fi
echo "=============================================="

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo "ERROR: docker not found"
    exit 1
fi

# Setup buildx builder for multi-platform builds
setup_buildx() {
    if ! docker buildx inspect beszel-builder &> /dev/null; then
        echo "Creating buildx builder..."
        docker buildx create --name beszel-builder --use --bootstrap
    else
        docker buildx use beszel-builder
    fi
}

build_site() {
    echo ""
    echo "Building frontend site..."

    if ! command -v bun &> /dev/null; then
        echo "ERROR: bun not found. Install with: curl -fsSL https://bun.sh/install | bash"
        exit 1
    fi

    (cd internal/site && bun install --no-save && bun run build)
    echo "Site built successfully"
}

build_image() {
    local dockerfile="$1"
    local image="$2"
    local tag_suffix="${3:-}"

    local full_tag="${TAG}${tag_suffix}"

    echo ""
    echo "Building ${image}:${full_tag}..."
    echo "  Dockerfile: ${dockerfile}"
    echo "  Platforms:  ${PLATFORMS}"

    local push_flag=""
    local load_flag=""
    local output_flag=""
    local cache_flag=""

    if [ "$PUSH" = "true" ]; then
        push_flag="--push"
    else
        # For single platform, we can load locally
        if [[ "$PLATFORMS" != *","* ]]; then
            load_flag="--load"
        else
            echo "  Note: Multi-platform build without push - using local cache only"
            output_flag="--output=type=cacheonly"
        fi
    fi

    if [ "$NO_CACHE" = "true" ]; then
        cache_flag="--no-cache"
    fi

    docker buildx build \
        --platform "${PLATFORMS}" \
        --file "${dockerfile}" \
        --tag "${image}:${full_tag}" \
        --tag "${image}:latest${tag_suffix}" \
        ${push_flag} ${load_flag} ${output_flag} ${cache_flag} \
        .

    echo "Built: ${image}:${full_tag}"
}

# Setup buildx for multi-platform builds
setup_buildx

case "$PACKAGE" in
    agent)
        build_image "./internal/dockerfile_agent" "${AGENT_IMAGE}"
        ;;
    agent-alpine)
        build_image "./internal/dockerfile_agent_alpine" "${AGENT_IMAGE}" "-alpine"
        ;;
    hub)
        build_site
        build_image "./internal/dockerfile_hub" "${HUB_IMAGE}"
        ;;
    all|"")
        build_image "./internal/dockerfile_agent" "${AGENT_IMAGE}"
        build_image "./internal/dockerfile_agent_alpine" "${AGENT_IMAGE}" "-alpine"
        build_site
        build_image "./internal/dockerfile_hub" "${HUB_IMAGE}"
        ;;
    *)
        echo "Unknown package: $PACKAGE"
        echo "Usage: $0 [agent|agent-alpine|hub|all]"
        exit 1
        ;;
esac

echo ""
echo "=============================================="
echo "Done!"
echo "=============================================="
echo ""
echo "Examples:"
echo ""
echo "  # Build single platform (loadable locally)"
echo "  PLATFORMS=linux/amd64 ./build-docker.sh"
echo ""
echo "  # Build and push to registry"
echo "  REGISTRY=ghcr.io/username PUSH=true ./build-docker.sh"
echo ""
echo "Run containers:"
echo ""
echo "  # Hub"
echo "  docker run -d --name beszel -v beszel_data:/beszel_data -p 8090:8090 ${HUB_IMAGE}:${TAG}"
echo ""
echo "  # Agent (scratch - minimal)"
echo "  docker run -d --name beszel-agent \\"
echo "    -e KEY='ssh-ed25519 ...' \\"
echo "    -e HAPROXY_SOCKET=/var/run/haproxy.sock \\"
echo "    -v /var/run/haproxy.sock:/var/run/haproxy.sock:ro \\"
echo "    -v /var/run/docker.sock:/var/run/docker.sock:ro \\"
echo "    -p 45876:45876 \\"
echo "    ${AGENT_IMAGE}:${TAG}"
echo ""
echo "  # Agent (alpine - includes smartmontools)"
echo "  docker run -d --name beszel-agent \\"
echo "    -e KEY='ssh-ed25519 ...' \\"
echo "    -p 45876:45876 \\"
echo "    ${AGENT_IMAGE}:${TAG}-alpine"

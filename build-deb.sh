#!/bin/bash
set -e

# Configuration
# VERSION: upstream version (e.g., 0.17.0)
# RELEASE: custom release tag (e.g., emp)
VERSION="${VERSION:-0.18.7-mp.14}"
RELEASE="${RELEASE:-emp}"
GOARCH="${GOARCH:-amd64}"
PACKAGE="${1:-all}"  # agent, hub, or all

build_agent() {
    echo ""
    echo "Building beszel-agent..."
    CGO_ENABLED=0 GOOS=linux GOARCH=${GOARCH} go build -ldflags="-s -w" -o dist/beszel-agent ./internal/cmd/agent/agent.go
    echo "Binary: dist/beszel-agent ($(ls -lh dist/beszel-agent | awk '{print $5}'))"

    echo "Packaging beszel-agent..."
    nfpm pkg --config nfpm-agent.yaml --packager deb --target dist/
}

build_hub() {
    echo ""
    echo "Building beszel hub..."

    # Build frontend first (required for Go embed)
    echo "Building frontend..."
    cd internal/site
    if command -v bun &> /dev/null; then
        bun install
        bun run build
    else
        npm install
        npm run build
    fi
    cd ../..

    CGO_ENABLED=0 GOOS=linux GOARCH=${GOARCH} go build -ldflags="-s -w" -o dist/beszel ./internal/cmd/hub/hub.go
    echo "Binary: dist/beszel ($(ls -lh dist/beszel | awk '{print $5}'))"

    echo "Packaging beszel..."
    nfpm pkg --config nfpm-hub.yaml --packager deb --target dist/
}

echo "=============================================="
echo "Beszel Debian Package Builder"
echo "  Version: ${VERSION}"
echo "  Release: ${RELEASE}"
echo "  Arch:    linux/${GOARCH}"
echo "  Package: ${PACKAGE}"
echo "=============================================="

# Create dist directory
mkdir -p dist

# Check if nfpm is installed
if ! command -v nfpm &> /dev/null; then
    echo ""
    echo "ERROR: nfpm not found. Install it with:"
    echo "  go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest"
    echo "  or: brew install nfpm"
    exit 1
fi

# Export variables for nfpm
export VERSION RELEASE GOARCH

case "$PACKAGE" in
    agent)
        build_agent
        ;;
    hub)
        build_hub
        ;;
    all|"")
        build_agent
        build_hub
        ;;
    *)
        echo "Unknown package: $PACKAGE"
        echo "Usage: $0 [agent|hub|all]"
        exit 1
        ;;
esac

echo ""
echo "=============================================="
echo "Done! Packages created:"
ls -lh dist/*.deb 2>/dev/null
echo "=============================================="
echo ""
echo "Install with:"
echo "  sudo apt install ./dist/beszel-agent_${VERSION}-${RELEASE}_${GOARCH}.deb"
echo "  sudo apt install ./dist/beszel_${VERSION}-${RELEASE}_${GOARCH}.deb"

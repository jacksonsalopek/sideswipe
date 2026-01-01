#!/bin/bash
# Generate Wayland protocol headers for sideswipe

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROTOCOLS_DIR="$PROJECT_ROOT/protocols"
WAYLAND_PROTOCOLS_DIR="/usr/share/wayland-protocols"

# Create protocols directory
mkdir -p "$PROTOCOLS_DIR"

echo "Generating Wayland protocol headers..."

# Generate xdg-shell protocol
echo "  - xdg-shell"
wayland-scanner client-header \
    "$WAYLAND_PROTOCOLS_DIR/stable/xdg-shell/xdg-shell.xml" \
    "$PROTOCOLS_DIR/xdg-shell-client-protocol.h"

wayland-scanner private-code \
    "$WAYLAND_PROTOCOLS_DIR/stable/xdg-shell/xdg-shell.xml" \
    "$PROTOCOLS_DIR/xdg-shell-protocol.c"

# Generate linux-dmabuf protocol
echo "  - linux-dmabuf-unstable-v1"
wayland-scanner client-header \
    "$WAYLAND_PROTOCOLS_DIR/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml" \
    "$PROTOCOLS_DIR/linux-dmabuf-unstable-v1-client-protocol.h"

wayland-scanner private-code \
    "$WAYLAND_PROTOCOLS_DIR/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml" \
    "$PROTOCOLS_DIR/linux-dmabuf-unstable-v1-protocol.c"

echo "Done! Protocol headers generated in $PROTOCOLS_DIR"

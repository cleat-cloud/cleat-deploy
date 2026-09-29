#!/usr/bin/env bash
# Installs Litestream on the panel host (Ubuntu amd64).
set -euo pipefail

LITESTREAM_VERSION="${LITESTREAM_VERSION:-0.5.17}"
DEB="litestream-${LITESTREAM_VERSION}-linux-x86_64.deb"
URL="https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/${DEB}"

if command -v litestream >/dev/null 2>&1; then
  echo "litestream already installed: $(litestream version)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp/$DEB"
sudo dpkg -i "$tmp/$DEB"
litestream version

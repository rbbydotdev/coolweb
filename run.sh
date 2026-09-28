#!/bin/sh
# Builds the guest (once) and the browser, signs it with the virtualization entitlement, serves examples/
# on http://localhost:8123 like any dev server, and opens the browser there.
set -eu
cd "$(dirname "$0")"
[ -f guest/out/Image ] && [ -f guest/out/initramfs.gz ] || sh guest/build.sh
swift build
BIN="$(swift build --show-bin-path)/CoolWeb"
codesign --force --sign - --entitlements CoolWeb.entitlements "$BIN"

python3 -m http.server 8123 --bind 127.0.0.1 --directory examples >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT INT TERM
COOLWEB_URL="${COOLWEB_URL:-http://localhost:8123/vmworker/}" "$BIN"

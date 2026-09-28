#!/bin/sh
# Runs the test suite headless (no window, no focus change) and exits non-zero on any failure.
#
#   scripts/test.sh                 all tests
#   scripts/test.sh vmworker/files.html "bun/?autotest"   chosen pages
#
# Each page under examples/ reports through document.title ("PASS ..." / "FAIL ..."); the browser prints title
# changes when COOLWEB_TRACE_TITLES is set. The native --selftest runs a VM without the browser.
set -u
cd "$(dirname "$0")/.."

swift build >/dev/null || exit 1
BIN="$(swift build --show-bin-path)/CoolWeb"
codesign --force --sign - --entitlements CoolWeb.entitlements "$BIN" 2>/dev/null
[ -f guest/out/Image ] && [ -f guest/out/initramfs.gz ] || sh guest/build.sh || exit 1

PORT=8124
PAGES=${*:-"vmworker/selftest.html vmworker/structured-clone.html vmworker/files.html vmworker/coherence.html vmworker/serve.html bun/?autotest"}
failed=0

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory examples >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT INT TERM
sleep 0.5

run_page() {
  log=$(mktemp)
  rm -f /tmp/coolweb-escape-probe
  COOLWEB_HEADLESS=1 COOLWEB_TRACE_TITLES=1 COOLWEB_URL="http://localhost:$PORT/$1" "$BIN" >"$log" 2>&1 &
  app=$!
  i=0
  while [ $i -lt 180 ] && ! grep -qE "\[title\] (PASS|FAIL)" "$log"; do sleep 0.5; i=$((i + 1)); done
  kill $app 2>/dev/null; wait $app 2>/dev/null
  result=$(grep -E "\[title\] (PASS|FAIL)" "$log" | tail -1 | sed 's/\[title\] //')
  [ -n "$result" ] || result="FAIL timeout"
  # files.html plants a symlink to a host-writable path; if the file exists, the storage sandbox leaked.
  if [ -e /tmp/coolweb-escape-probe ]; then result="FAIL host escape: /tmp/coolweb-escape-probe"; rm -f /tmp/coolweb-escape-probe; fi
  printf '%-34s %s\n' "$1" "$result"
  case "$result" in PASS*) ;; *) failed=1 ;; esac
  rm -f "$log"
}

for page in $PAGES; do run_page "$page"; done

if [ $# -eq 0 ]; then
  native=$("$BIN" --selftest 2>&1 | tail -1)
  printf '%-34s %s\n' "native --selftest" "$native"
  [ "$native" = PASS ] || failed=1
fi

exit $failed

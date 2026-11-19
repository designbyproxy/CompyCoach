#!/bin/bash
# Captures the README / marketing screenshots: each takeover screen, the menu, and the About window.
#
#   scripts/make-screenshots.sh              all screens (run from anywhere)
#   scripts/make-screenshots.sh walk eyes    just those
#
# Launches a debug build once per screen with `-screenshot <name>`, waits for the entrance
# animation to settle, and captures only CompyCoach's window (no desktop, no shadow).
# Each takeover covers the screen for a few seconds; don't type while it runs.
# Needs Screen Recording permission for your terminal (System Settings → Privacy & Security).
#
# Output: docs/screenshots/<name>.png. Takeovers are downscaled to 2880 px wide.

set -euo pipefail
cd "$(dirname "$0")/.."

ONLY=("$@")
OUT=docs/screenshots
DERIVED=build/screenshots
mkdir -p "$OUT" "$DERIVED"

echo "Building debug app…"
xcodebuild -scheme CompyCoach -configuration Debug -derivedDataPath "$DERIVED" build -quiet
APP="$DERIVED/Build/Products/Debug/CompyCoach.app/Contents/MacOS/CompyCoach"
swiftc -O scripts/window-id.swift -o "$DERIVED/window-id"

# shoot <name> <seconds to let the entrance settle once the window is up>
shoot() {
    local name=$1 settle=$2 id="" tries=0
    if [ ${#ONLY[@]} -gt 0 ] && [[ " ${ONLY[*]} " != *" $name "* ]]; then return 0; fi
    "$APP" -screenshot "$name" >/dev/null 2>&1 &
    local pid=$!
    # Wait up to 15 s for the window to appear.
    until id=$("$DERIVED/window-id" "$pid"); do
        tries=$((tries + 1))
        if [ $tries -gt 60 ]; then echo "No window for $name"; kill "$pid"; return 1; fi
        sleep 0.25
    done
    sleep "$settle"
    id=$("$DERIVED/window-id" "$pid")
    screencapture -x -o -l "$id" "$OUT/$name.png"
    kill "$pid"; wait "$pid" 2>/dev/null || true
    if [ "$name" != about ] && [ "$name" != menu ]; then sips -Z 2880 "$OUT/$name.png" >/dev/null; fi
    echo "wrote $OUT/$name.png"
}

shoot about   1.5
shoot menu    1.5  # sample home: 90210; debug items hidden
shoot squats  3.5
shoot pushups 3.5
shoot situps  3.5
shoot walk    3.5  # sample weather: 64° and clear
shoot stretch 10   # mid-count: the timer line is part way across
shoot eyes    24   # 20-second count finished: band open, Confirm showing

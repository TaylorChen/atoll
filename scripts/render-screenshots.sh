#!/bin/bash
# Regenerate README screenshots in assets/ from the real SwiftUI views,
# fed with placeholder sessions (no real agent data is ever captured).
# Usage: scripts/render-screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(pwd)/assets"
( cd app && ATOLL_SCREENSHOT_DIR="$OUT" swift test --filter ScreenshotRenderTests )
ls -l "$OUT"/*.png

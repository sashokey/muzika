#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d /tmp/muzika-lyrics.XXXXXXXX)"
app="$root/muzika/Lyrics"
xcrun swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macosx27.0 \
    -Xfrontend -disable-sandbox -module-cache-path "$scratch/module-cache" \
    "$root/Tests/Lyrics/InstrumentalTransitionCheck.swift" \
    "$app"/{LyricsDocument,LyricsGeometry,LyricsCountdownLayer,LyricsRendering,TimedLyricsScrollView,LyricsPanel,UntimedLyricsScrollDriver}.swift \
    -o "$scratch/InstrumentalTransitionCheck"
if [[ "${1:-}" == --build-only ]]; then
    printf '%s\n' "$scratch/InstrumentalTransitionCheck"
else
    "$scratch/InstrumentalTransitionCheck" "$@"
fi

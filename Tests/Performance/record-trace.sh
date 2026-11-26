#!/bin/bash
set -euo pipefail
scripts="$(cd "$(dirname "$0")" && pwd)"
scratch="${1:?Fixture directory required}"
report="${2:?Report path required}"
repeats="${3:?Repeat count required}"
trace="${4:?Trace path required}"
mode="${5:-suite}"
template='Metal System Trace'
if [[ "$mode" == home || "$mode" == compositor || "$mode" == stress-compositor ]]; then
    template='Animation Hitches'
fi
bundle="$scratch/MuzikaPerformance.app/Contents"
mkdir -p "$bundle/MacOS"
install -m 755 "$scratch/MuzikaPerformance" "$bundle/MacOS/MuzikaPerformance"
glow="$(cd "$scripts/../.." && pwd)/muzika/Resources/Branding/ShuffleGlow.png"
if [[ -f "$glow" ]]; then
    mkdir -p "$bundle/Resources"
    install -m 644 "$glow" "$bundle/Resources/ShuffleGlow.png"
fi
cat > "$bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>app.muzika.performance</string>
    <key>CFBundleExecutable</key>
    <string>MuzikaPerformance</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
xcrun xctrace record --template "$template" --instrument 'Points of Interest' --no-prompt \
    --env MUZIKA_PERFORMANCE_VISIBLE=1 --output "$trace" --target-stdout "$scratch/trace-output.log" \
    --launch -- "$bundle/MacOS/MuzikaPerformance" "$scratch" "$report" "$repeats" "$mode"
if [[ "$template" == 'Animation Hitches' ]]; then
    prefix="$scratch/$mode"
    schemas=(OSSignpostIntervals hitches-updates display-surface-swap hitches-gpu)
    if [[ "$mode" == home ]]; then schemas+=(display-vsyncs-interval); fi
    for schema in "${schemas[@]}"; do
        xcrun xctrace export --input "$trace" \
            --xpath "/trace-toc/run[@number='1']/data/table[@schema='$schema']" --output "$prefix-$schema.xml"
    done
    python3 "$scripts/merge-home-trace.py" "$report" "$prefix" "$mode"
else
    bash "$scripts/export-trace.sh" "$trace" "$scratch/trace"
    python3 "$scripts/merge-trace.py" "$report" "$scratch/trace-signposts.xml" "$scratch/trace-gpu.xml"
fi

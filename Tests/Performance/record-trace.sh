#!/bin/bash
set -euo pipefail
scripts="$(cd "$(dirname "$0")" && pwd)"
scratch="${1:?Fixture directory required}"
report="${2:?Report path required}"
repeats="${3:?Repeat count required}"
trace="${4:?Trace path required}"
xcrun xctrace record --template 'Metal System Trace' --instrument 'Points of Interest' --no-prompt \
    --env MUZIKA_PERFORMANCE_VISIBLE=1 --output "$trace" --target-stdout "$scratch/trace-output.log" \
    --launch -- "$scratch/MuzikaPerformance" "$scratch" "$report" "$repeats"
bash "$scripts/export-trace.sh" "$trace" "$scratch/trace"
python3 "$scripts/merge-trace.py" "$report" "$scratch/trace-signposts.xml" "$scratch/trace-gpu.xml"

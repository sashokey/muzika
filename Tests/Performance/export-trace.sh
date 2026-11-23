#!/bin/bash
set -euo pipefail
trace="${1:?Trace path required}"
output="${2:?Output prefix required}"
xcrun xctrace export --input "$trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"]' --output "$output-signposts.xml"
xcrun xctrace export --input "$trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]' --output "$output-gpu.xml"

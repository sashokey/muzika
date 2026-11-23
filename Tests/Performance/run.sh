#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
report="${1:?Usage: bash Tests/Performance/run.sh ABSOLUTE_REPORT.json [repeats] [ABSOLUTE_TRACE.trace]}"
repeats="${2:-3}"
trace="${3:-}"
case "$report" in /*) ;; *) printf '%s\n' "The report path must be absolute." >&2; exit 2 ;; esac
scratch="$(mktemp -d /tmp/muzika-performance.XXXXXXXX)"
python3 - "$root/muzika" "$scratch" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1])
sandbox = Path(sys.argv[2])

def replace(text, before, after):
    if before not in text:
        raise SystemExit(f"Cannot isolate performance fixture. Source changed: {before}")
    return text.replace(before, after)

for file in source.rglob("*.swift"):
    text = file.read_text()
    if file.name == "MuzikaApp.swift":
        text = replace(text, "@main\n", "")
        text = replace(text, "private struct MainWindow:", "struct MainWindow:")
    elif file.name == "AppState.swift":
        text = replace(text, "let library = LibraryStore()", "let library = LibraryStore(storageURL: BenchmarkPaths.library)")
        text = replace(text, "let history = HistoryStore()", "let history = HistoryStore(file: BenchmarkPaths.history)")
        text = replace(text, "PlaybackController(library: library)", "PlaybackController(library: library, defaults: BenchmarkDefaults(), mode: .offline)")
        text = replace(text, "    @ObservationIgnored private let system: SystemPlayback\n", "")
        text = replace(text, "        system = SystemPlayback(library: library, playback: playback)\n", "")
        text = replace(text, "        playback.onNowPlayingChange = { [weak system] in system?.update() }\n", "")
    elif file.name in ["HistoryStore.swift", "Preferences.swift", "SearchAndListening.swift", "TrackBrowser.swift"]:
        text = text.replace("UserDefaults.standard", "BenchmarkDefaults()")
        text = re.sub(r'@AppStorage\(("[^"\n]+")\)', r'@AppStorage(\1, store: BenchmarkDefaults())', text)
    elif file.name == "WaveBackground.swift":
        before = "        buffer.addCompletedHandler { [weak self] completed in\n"
        text = replace(text, before, before + "            PerformanceGPU.record(completed)\n")
    target = sandbox / file.relative_to(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
PY

files=()
while IFS= read -r -d "" file; do files+=("$file"); done < <(find "$scratch" -type f -name '*.swift' -print0)
xcrun swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macosx27.0 \
    -Xfrontend -disable-sandbox -module-cache-path "${MUZIKA_PERFORMANCE_MODULE_CACHE:-$scratch/module-cache}" \
    "$root/Tests/Performance/PerformanceProbe.swift" "${files[@]}" -o "$scratch/MuzikaPerformance"
printf 'Fixture: %s\n' "$scratch"
if [[ "${MUZIKA_PERFORMANCE_BUILD_ONLY:-0}" == 1 ]]; then exit 0; fi
if [[ -n "$trace" ]]; then
    bash "$root/Tests/Performance/record-trace.sh" "$scratch" "$report" "$repeats" "$trace"
else
    "$scratch/MuzikaPerformance" "$scratch" "$report" "$repeats"
fi

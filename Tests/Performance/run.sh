#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
report="${1:?Usage: bash Tests/Performance/run.sh ABSOLUTE_REPORT.json [repeats] [suite|home|stress]}"
repeats="${2:-3}"
mode="${3:-suite}"
case "$mode" in
    suite) ;;
    home|stress) export MUZIKA_PERFORMANCE_VISIBLE=1 ;;
    *) printf '%s\n' "Unknown test mode: $mode" >&2; exit 2 ;;
esac
case "$report" in /*) ;; *) printf '%s\n' "The report path must be absolute." >&2; exit 2 ;; esac
scratch="$(mktemp -d /tmp/muzika-performance.XXXXXXXX)"
python3 - "$root/muzika" "$scratch" "$mode" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1])
sandbox = Path(sys.argv[2])
stress = sys.argv[3] == "stress"

def replace(text, before, after):
    if before not in text:
        raise SystemExit(f"Cannot isolate performance fixture. Source changed: {before}")
    return text.replace(before, after)

for file in source.rglob("*.swift"):
    text = file.read_text()
    if file.name == "MuzikaApp.swift":
        text = replace(text, "@main\n", "")
    elif file.name == "AppState.swift":
        text = replace(text, "let library = LibraryStore()", "let library = LibraryStore(storageURL: BenchmarkPaths.library)")
        text = replace(text, "let history = HistoryStore()", "let history = HistoryStore(file: BenchmarkPaths.history)")
        text = replace(text, "PlaybackController(library: library)", "PlaybackController(library: library, defaults: BenchmarkDefaults(), mode: .offline)")
        text = replace(text, "    @ObservationIgnored private let system: SystemPlayback\n", "")
        text = replace(text, "        system = SystemPlayback(library: library, playback: playback)\n", "")
        text = replace(text, "        playback.onNowPlayingChange = { [weak system] in system?.update() }\n", "")
    elif file.name in ["HistoryStore.swift", "Preferences.swift", "PreferencesView.swift", "SearchAndListening.swift", "TrackBrowser.swift", "FolderBrowserPage.swift"]:
        text = text.replace("UserDefaults.standard", "BenchmarkDefaults()")
        text = re.sub(r'@AppStorage\(("[^"\n]+")\)', r'@AppStorage(\1, store: BenchmarkDefaults())', text)
        if stress and file.name == "TrackBrowser.swift":
            text = replace(text, "private var showsSongs = false", "private var showsSongs = true")
    elif file.name == "LibraryShell.swift" and stress:
        text = replace(text, 'private var searchQuery = ""', 'private var searchQuery = "Stress Track"')
        text = replace(text, "private var searchScope = BrowseSearchScope.all", "private var searchScope = BrowseSearchScope.songs")
    target = sandbox / file.relative_to(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
PY

files=()
while IFS= read -r -d "" file; do files+=("$file"); done < <(find "$scratch" -type f -name '*.swift' -print0)
xcrun swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macosx27.0 \
    -Xfrontend -disable-sandbox -module-cache-path "${MUZIKA_PERFORMANCE_MODULE_CACHE:-$scratch/module-cache}" \
    "$root/Tests/Performance/PerformanceProbe.swift" "$root/Tests/Performance/HomeScrollCheck.swift" \
    "$root/Tests/Performance/StressScrollCheck.swift" "${files[@]}" -o "$scratch/MuzikaPerformance"
if [[ "${MUZIKA_PERFORMANCE_BUILD_ONLY:-0}" == 1 ]]; then
    printf '%s\n' "$scratch"
    exit 0
fi
"$scratch/MuzikaPerformance" "$scratch" "$report" "$repeats" "$mode"

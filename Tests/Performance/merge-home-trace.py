from collections import Counter, defaultdict
import json
from math import ceil
from pathlib import Path
from statistics import median
import subprocess
import sys
from xml.etree.ElementTree import iterparse
from trace_metrics import cpu_percent, gpu_usage


def rows(path, *columns):
    references = {}
    indices = []
    for _, node in iterparse(path, events=("end",)):
        if node.tag == "schema":
            fields = [col.findtext("mnemonic") for col in node.findall("col")]
            indices = [fields.index(column) for column in columns]
        elif node.tag == "row":
            values = []
            for field in node:
                if field.tag == "process":
                    payload = field.get("fmt", "")
                else:
                    payload = field.text or field.get("fmt", "")
                value = references.get(field.get("ref"), payload)
                if "id" in field.attrib:
                    references[field.get("id")] = value
                values.append(value)
            yield tuple(values[index] for index in indices)
            node.clear()


def p95(values):
    return sorted(values)[ceil(len(values) * 0.95) - 1]


def measure(prefix, samples, home=True):
    def read(schema, *columns):
        return rows(Path(f"{prefix}-{schema}.xml"), *columns)

    intervals = defaultdict(list)
    for start, duration, process, subsystem, action in read(
        "OSSignpostIntervals", "start", "duration", "process", "subsystem", "start-message"
    ):
        if subsystem == "org.muzika.performance" and action:
            intervals[action].append((int(start), int(duration), process))
    expected = Counter(sample["action"] for sample in samples)
    if home and set(expected) != {"home.shuffle_scroll_down", "home.shuffle_scroll_up"}:
        raise ValueError("A visible downward and return scroll interval is required for every repeat")
    if expected != {name: len(group) for name, group in intervals.items()}:
        raise ValueError("Instruments did not record exactly one interval for each measured action")

    updates = defaultdict(set)
    for process, swap in read("hitches-updates", "process", "swap-id"):
        updates[process].add(swap)
    swaps = [(int(time), display, identifier) for time, display, identifier in read(
        "display-surface-swap", "timestamp", "display-name", "swap-id"
    )]
    vsyncs = defaultdict(list)
    if home:
        for time, display, event in read("display-vsyncs-interval", "timestamp", "display-name", "event"):
            if event == "VSYNC":
                vsyncs[display].append(int(time))
    gpu = defaultdict(list)
    for start, elapsed, swap in read("hitches-gpu", "start", "duration", "swap-id"):
        gpu[swap].append((int(start), int(start) + int(elapsed)))
    if not gpu:
        raise ValueError("Instruments captured no compositor GPU intervals")

    for sample in samples:
        start, trace_duration, process = sorted(intervals[sample["action"]])[sample["iteration"] - 1]
        duration = min(trace_duration, round(sample["sampledWallMilliseconds"] * 1_000_000))
        end = start + duration
        on_display = defaultdict(dict)
        for time, display, identifier in swaps:
            if start <= time <= end and identifier in updates[process]:
                on_display[display][identifier] = time
        if not sample["windowVisible"]:
            raise ValueError("Compositor sampling requires a visible test window")
        swap_ids = {swap for displayed in on_display.values() for swap in displayed}
        gpu_ms, gpu_percent = gpu_usage(
            (interval for swap in swap_ids for interval in gpu.get(swap, [])), start, end
        )
        sample.update(
            cpuPercentOfOneCore=cpu_percent(sample),
            windowServerGPUActiveMilliseconds=gpu_ms,
            windowServerGPUPercent=gpu_percent,
        )
        if not home:
            continue
        if len(on_display) != 1:
            raise ValueError("Home scroll needs app-attributed swaps on one visible display")
        display, presented = next(iter(on_display.items()))
        timestamps = sorted(set(presented.values()))
        candidates = [sorted({t for t in values if start <= t <= end})
                      for name, values in vsyncs.items()
                      if name == display or name.startswith(f"{display} ")]
        if len(candidates) != 1 or len(candidates[0]) < 2 or len(timestamps) < 2:
            raise ValueError("Missing displayed frames or display VSync measurements")
        pulses = candidates[0]
        frame_intervals = [(b - a) / 1_000_000 for a, b in zip(timestamps, timestamps[1:])]
        display_period = median(b - a for a, b in zip(pulses, pulses[1:]))
        sample.update(
            displayedAppFrames=len(timestamps),
            displayedAppFPS=len(timestamps) * 1_000_000_000 / duration,
            displayedFrameIntervalP95Milliseconds=p95(frame_intervals),
            displayedFrameIntervalMaxMilliseconds=max(frame_intervals),
            displayVSyncHz=1_000_000_000 / display_period,
        )


def main():
    report = Path(sys.argv[1])
    samples = json.loads(report.read_text())
    home = len(sys.argv) < 4 or sys.argv[3] == "home"
    measure(sys.argv[2], samples, home)
    version = subprocess.check_output(["xcodebuild", "-version"], text=True).strip().replace("\n", ", ")
    for sample in samples:
        sample["xcode"] = version
    report.write_text(json.dumps(samples, indent=2) + "\n")
    label = "displayed frames and compositor usage" if home else "compositor usage"
    print(f"Verified {label} for {len(samples)} visual samples")


if __name__ == "__main__":
    main()

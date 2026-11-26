from collections import Counter, defaultdict
import json
from pathlib import Path
import subprocess
import sys
from xml.etree.ElementTree import iterparse
from trace_metrics import cpu_percent, gpu_usage


def rows(path, columns):
    references = {}
    positions = {}
    tracked_types = {
        "start-time", "duration", "gpu-state", "process", "subsystem",
        "os-log-metadata", "signpost-name",
    }

    def value(node):
        if "ref" in node.attrib:
            return references.get(node.get("ref"), "")
        if node.tag in {"process", "os-log-metadata"}:
            return node.get("fmt", "") or node.text or ""
        return node.text or node.get("fmt", "")

    for event, node in iterparse(path, events=("end",)):
        if node.tag == "schema":
            positions = {field.findtext("mnemonic"): index for index, field in enumerate(node.findall("col"))}
            if not set(columns).issubset(positions):
                raise ValueError(f"Unexpected Instruments schema in {path}")
        elif node.tag == "row":
            for field in node.iter():
                if "id" in field.attrib and field.tag in tracked_types:
                    references[field.get("id")] = value(field)
            yield {column: value(node[positions[column]]) for column in columns}
            node.clear()


def intervals_by_action(path):
    result = defaultdict(list)
    columns = ["start", "process", "subsystem", "start-message"]
    for row in rows(path, columns):
        if row["subsystem"] != "org.muzika.performance" or not row["start-message"]:
            continue
        result[row["start-message"]].append((int(row["start"]), row["process"]))
    return result


def gpu_intervals(path, targets):
    result = defaultdict(list)
    for row in rows(path, ["start", "duration", "process", "state"]):
        if row["process"] not in targets or row["state"] != "Active":
            continue
        start = int(row["start"])
        result[row["process"]].append((start, start + int(row["duration"])))
    return result


def main():
    report, signposts, gpu = map(Path, sys.argv[1:4])
    samples = json.loads(report.read_text())
    actions = intervals_by_action(signposts)
    for intervals in actions.values():
        intervals.sort()
    expected = Counter(row["action"] for row in samples)
    if expected != {name: len(starts) for name, starts in actions.items()}:
        raise ValueError("Instruments did not record exactly one start for each measured action")
    targets = {process for starts in actions.values() for _, process in starts}
    gpu_events = gpu_intervals(gpu, targets)
    if not gpu_events:
        raise ValueError("There are no GPU execution intervals belonging to the benchmark process")

    windows = []
    for row in samples:
        lower, target = actions[row["action"]][row["iteration"] - 1]
        windows.append((lower, lower + round(row["sampledWallMilliseconds"] * 1_000_000), target))
    version = subprocess.check_output(["xcodebuild", "-version"], text=True).strip().replace("\n", ", ")
    for index, (lower, upper, target) in enumerate(windows):
        if index + 1 < len(windows):
            next_start = windows[index + 1][0]
            if next_start <= lower or upper > next_start + 2_000_000:
                raise ValueError("Timestamped action windows are out of order or overlap")
            upper = min(upper, next_start)
        gpu_ms, gpu_percent = gpu_usage(gpu_events.get(target, []), lower, upper)
        samples[index].update(
            xcode=version,
            cpuPercentOfOneCore=cpu_percent(samples[index]),
            traceGPUActiveMilliseconds=gpu_ms,
            traceGPUPercent=gpu_percent,
        )

    report.write_text(json.dumps(samples, indent=2) + "\n")
    print(f"Merged app-process GPU execution time into {len(samples)} samples")


if __name__ == "__main__":
    main()

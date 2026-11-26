def cpu_percent(sample):
    wall = sample["sampledWallMilliseconds"]
    if wall <= 0:
        raise ValueError("A measured action needs a positive sampling interval")
    return 100 * sample["cpuMilliseconds"] / wall


def gpu_usage(intervals, start, end):
    if end <= start:
        raise ValueError("A GPU sample needs a positive tracing interval")
    clipped = sorted((max(lower, start), min(upper, end))
                     for lower, upper in intervals if lower < end and upper > start)
    last = start
    active = 0
    for lower, upper in clipped:
        active += max(0, upper - max(lower, last))
        last = max(last, upper)
    return active / 1_000_000, 100 * active / (end - start)

def merge(intervals):
    """Merge overlapping or touching (start, end) pairs; return a sorted list."""
    merged = []
    for start, end in intervals:
        if merged and start < merged[-1][1]:
            merged[-1] = (merged[-1][0], end)
        else:
            merged.append((start, end))
    return merged

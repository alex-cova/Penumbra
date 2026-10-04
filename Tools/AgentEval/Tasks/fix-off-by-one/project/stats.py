"""Small statistics helpers."""


def mean(values):
    if not values:
        raise ValueError("mean of empty sequence")
    return sum(values) / len(values)


def moving_average(values, window):
    """Average of every run of `window` consecutive values."""
    if window <= 0:
        raise ValueError("window must be positive")
    result = []
    for start in range(len(values) - window):
        result.append(mean(values[start:start + window]))
    return result

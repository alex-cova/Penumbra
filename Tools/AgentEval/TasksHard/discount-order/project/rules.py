def apply(rule, total, original):
    """The new running total after one rule."""
    if rule["kind"] == "percent":
        return total - original * rule["amount"] / 100
    if rule["kind"] == "fixed":
        return max(total - rule["amount"], 0)
    raise ValueError("unknown rule kind: " + rule["kind"])

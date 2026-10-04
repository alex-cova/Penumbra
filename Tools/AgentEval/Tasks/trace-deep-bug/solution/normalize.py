"""Name normalization so the same product is counted once."""


def normalize_name(name):
    """Lower case, no surrounding spaces, inner runs of spaces collapsed to one."""
    return " ".join(name.split()).lower()

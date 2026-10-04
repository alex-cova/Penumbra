"""Parses one line of an order file: "name, quantity, unit price"."""


def parse_line(line):
    """Returns (name, quantity, price). The name is returned as written; normalize.py cleans it."""
    fields = line.split(",")
    if len(fields) != 3:
        raise ValueError("bad line: %r" % line)
    return fields[0], int(fields[1].strip()), float(fields[2].strip())

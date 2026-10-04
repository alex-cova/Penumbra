"""Order file -> totals per product."""

from aggregate import add_line
from normalize import normalize_name
from parser import parse_line


def run(text):
    totals = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        name, quantity, price = parse_line(line)
        add_line(totals, normalize_name(name), quantity, price)
    return totals

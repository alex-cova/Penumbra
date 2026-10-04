"""Invoices."""

from utils import format_money, pluralize


def invoice_lines(items):
    """items: list of (name, quantity, unit_cents)."""
    lines = []
    for name, quantity, unit in items:
        lines.append("%s x%d @ %s = %s" % (name, quantity, format_money(unit), format_money(quantity * unit)))
    return lines


def invoice_total(items):
    total = sum(quantity * unit for _, quantity, unit in items)
    return "%s for %s" % (format_money(total), pluralize(len(items), "item"))

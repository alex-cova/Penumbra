"""Shared helpers."""


def format_money(cents):
    """Format an amount in cents as dollars: 1234 -> "$12.34"."""
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return "%s$%d.%02d" % (sign, cents // 100, cents % 100)


def pluralize(count, word):
    return "%d %s%s" % (count, word, "" if count == 1 else "s")

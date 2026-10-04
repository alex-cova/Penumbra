"""Totals per product."""


def add_line(totals, name, quantity, price):
    totals[name] = round(totals.get(name, 0.0) + quantity * price, 2)
    return totals

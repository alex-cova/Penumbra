from config import load_rules
from rules import apply


def checkout(prices, rule_lines):
    original = sum(prices)
    total = original
    for rule in load_rules(rule_lines):
        total = apply(rule, total, original)
    return round(total, 2)

def load_rules(lines):
    """Each line is `name,kind,amount,priority`; a lower priority runs first."""
    rules = []
    for line in lines:
        name, kind, amount, priority = [part.strip() for part in line.split(",")]
        rules.append({"name": name, "kind": kind, "amount": float(amount), "priority": int(priority)})
    return sorted(rules, key=lambda rule: rule["priority"])

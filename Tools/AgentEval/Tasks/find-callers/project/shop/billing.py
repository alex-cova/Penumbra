"""Charging accounts."""


def charge(account, amount_cents):
    """Take amount_cents from account. Returns the new balance."""
    account["balance_cents"] -= amount_cents
    return account["balance_cents"]

"""Refunds go back through billing."""

from shop.billing import charge as collect


def issue_refund(account, amount_cents):
    """Return a previous charge."""
    return collect(account, -amount_cents)


def recharge_account(account, amount_cents):
    """Top up a prepaid account. No billing involved."""
    account["balance_cents"] += amount_cents
    return account["balance_cents"]

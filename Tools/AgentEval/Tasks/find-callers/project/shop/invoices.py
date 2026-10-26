"""Monthly invoicing."""

from shop import billing


def finalize(account, amount_cents):
    """Charge the invoice total."""
    return billing.charge(account, amount_cents)

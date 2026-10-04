"""Monthly report."""

import utils


def monthly_report(month, totals):
    """totals: dict of day -> cents."""
    lines = ["Report for %s" % month]
    for day in sorted(totals):
        lines.append("  day %d: %s" % (day, utils.fmt_money(totals[day])))
    lines.append("  total: %s" % utils.fmt_money(sum(totals.values())))
    return "\n".join(lines)

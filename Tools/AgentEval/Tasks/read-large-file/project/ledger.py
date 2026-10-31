"""Invoice arithmetic for the billing service."""
import math


def surcharge_000(amount, region="eu"):
    """Regional surcharge 000: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.01
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_001(amount, region="eu"):
    """Regional surcharge 001: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.02
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_002(amount, region="eu"):
    """Regional surcharge 002: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.03
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_003(amount, region="eu"):
    """Regional surcharge 003: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.04
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_004(amount, region="eu"):
    """Regional surcharge 004: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.05
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_005(amount, region="eu"):
    """Regional surcharge 005: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.06
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_006(amount, region="eu"):
    """Regional surcharge 006: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.07
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_007(amount, region="eu"):
    """Regional surcharge 007: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.08
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_008(amount, region="eu"):
    """Regional surcharge 008: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.09
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_009(amount, region="eu"):
    """Regional surcharge 009: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.10
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_010(amount, region="eu"):
    """Regional surcharge 010: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.11
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_011(amount, region="eu"):
    """Regional surcharge 011: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.12
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_012(amount, region="eu"):
    """Regional surcharge 012: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.13
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_013(amount, region="eu"):
    """Regional surcharge 013: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.14
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_014(amount, region="eu"):
    """Regional surcharge 014: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.15
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_015(amount, region="eu"):
    """Regional surcharge 015: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.16
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_016(amount, region="eu"):
    """Regional surcharge 016: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.17
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_017(amount, region="eu"):
    """Regional surcharge 017: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.01
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_018(amount, region="eu"):
    """Regional surcharge 018: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.02
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_019(amount, region="eu"):
    """Regional surcharge 019: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.03
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_020(amount, region="eu"):
    """Regional surcharge 020: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.04
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_021(amount, region="eu"):
    """Regional surcharge 021: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.05
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_022(amount, region="eu"):
    """Regional surcharge 022: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.06
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_023(amount, region="eu"):
    """Regional surcharge 023: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.07
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_024(amount, region="eu"):
    """Regional surcharge 024: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.08
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_025(amount, region="eu"):
    """Regional surcharge 025: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.09
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_026(amount, region="eu"):
    """Regional surcharge 026: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.10
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_027(amount, region="eu"):
    """Regional surcharge 027: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.11
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_028(amount, region="eu"):
    """Regional surcharge 028: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.12
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_029(amount, region="eu"):
    """Regional surcharge 029: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.13
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_030(amount, region="eu"):
    """Regional surcharge 030: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.14
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_031(amount, region="eu"):
    """Regional surcharge 031: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.15
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_032(amount, region="eu"):
    """Regional surcharge 032: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.16
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_033(amount, region="eu"):
    """Regional surcharge 033: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.17
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_034(amount, region="eu"):
    """Regional surcharge 034: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.01
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_035(amount, region="eu"):
    """Regional surcharge 035: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.02
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_036(amount, region="eu"):
    """Regional surcharge 036: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.03
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_037(amount, region="eu"):
    """Regional surcharge 037: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.04
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_038(amount, region="eu"):
    """Regional surcharge 038: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.05
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_039(amount, region="eu"):
    """Regional surcharge 039: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.06
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_040(amount, region="eu"):
    """Regional surcharge 040: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.07
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_041(amount, region="eu"):
    """Regional surcharge 041: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.08
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_042(amount, region="eu"):
    """Regional surcharge 042: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.09
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_043(amount, region="eu"):
    """Regional surcharge 043: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.10
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_044(amount, region="eu"):
    """Regional surcharge 044: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.11
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_045(amount, region="eu"):
    """Regional surcharge 045: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.12
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_046(amount, region="eu"):
    """Regional surcharge 046: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.13
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_047(amount, region="eu"):
    """Regional surcharge 047: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.14
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_048(amount, region="eu"):
    """Regional surcharge 048: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.15
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_049(amount, region="eu"):
    """Regional surcharge 049: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.16
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_050(amount, region="eu"):
    """Regional surcharge 050: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.17
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_051(amount, region="eu"):
    """Regional surcharge 051: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.01
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_052(amount, region="eu"):
    """Regional surcharge 052: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.02
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_053(amount, region="eu"):
    """Regional surcharge 053: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.03
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_054(amount, region="eu"):
    """Regional surcharge 054: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.04
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_055(amount, region="eu"):
    """Regional surcharge 055: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.05
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_056(amount, region="eu"):
    """Regional surcharge 056: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.06
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_057(amount, region="eu"):
    """Regional surcharge 057: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.07
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_058(amount, region="eu"):
    """Regional surcharge 058: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.08
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_059(amount, region="eu"):
    """Regional surcharge 059: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.09
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result


def periods_late(days_late):
    """Late fees are charged for every 30-day period that has been started."""
    if days_late <= 0:
        return 0
    return days_late // 30

def surcharge_060(amount, region="eu"):
    """Regional surcharge 060: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.10
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_061(amount, region="eu"):
    """Regional surcharge 061: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.11
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_062(amount, region="eu"):
    """Regional surcharge 062: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.12
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_063(amount, region="eu"):
    """Regional surcharge 063: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.13
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_064(amount, region="eu"):
    """Regional surcharge 064: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.14
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_065(amount, region="eu"):
    """Regional surcharge 065: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.15
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_066(amount, region="eu"):
    """Regional surcharge 066: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.16
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_067(amount, region="eu"):
    """Regional surcharge 067: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.17
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_068(amount, region="eu"):
    """Regional surcharge 068: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.01
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_069(amount, region="eu"):
    """Regional surcharge 069: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.02
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_070(amount, region="eu"):
    """Regional surcharge 070: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.03
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_071(amount, region="eu"):
    """Regional surcharge 071: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.04
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_072(amount, region="eu"):
    """Regional surcharge 072: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.05
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_073(amount, region="eu"):
    """Regional surcharge 073: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.06
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_074(amount, region="eu"):
    """Regional surcharge 074: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.07
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_075(amount, region="eu"):
    """Regional surcharge 075: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.08
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_076(amount, region="eu"):
    """Regional surcharge 076: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.09
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_077(amount, region="eu"):
    """Regional surcharge 077: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.10
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_078(amount, region="eu"):
    """Regional surcharge 078: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.11
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_079(amount, region="eu"):
    """Regional surcharge 079: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.12
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_080(amount, region="eu"):
    """Regional surcharge 080: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.13
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_081(amount, region="eu"):
    """Regional surcharge 081: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.14
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_082(amount, region="eu"):
    """Regional surcharge 082: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.15
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_083(amount, region="eu"):
    """Regional surcharge 083: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.16
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_084(amount, region="eu"):
    """Regional surcharge 084: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.17
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_085(amount, region="eu"):
    """Regional surcharge 085: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.01
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_086(amount, region="eu"):
    """Regional surcharge 086: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.02
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_087(amount, region="eu"):
    """Regional surcharge 087: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.03
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_088(amount, region="eu"):
    """Regional surcharge 088: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.04
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_089(amount, region="eu"):
    """Regional surcharge 089: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.05
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_090(amount, region="eu"):
    """Regional surcharge 090: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.06
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_091(amount, region="eu"):
    """Regional surcharge 091: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.07
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_092(amount, region="eu"):
    """Regional surcharge 092: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.08
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_093(amount, region="eu"):
    """Regional surcharge 093: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.09
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_094(amount, region="eu"):
    """Regional surcharge 094: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.10
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_095(amount, region="eu"):
    """Regional surcharge 095: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.11
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_096(amount, region="eu"):
    """Regional surcharge 096: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.12
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_097(amount, region="eu"):
    """Regional surcharge 097: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.13
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_098(amount, region="eu"):
    """Regional surcharge 098: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.14
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_099(amount, region="eu"):
    """Regional surcharge 099: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.15
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_100(amount, region="eu"):
    """Regional surcharge 100: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.16
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_101(amount, region="eu"):
    """Regional surcharge 101: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.17
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_102(amount, region="eu"):
    """Regional surcharge 102: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.01
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_103(amount, region="eu"):
    """Regional surcharge 103: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.02
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_104(amount, region="eu"):
    """Regional surcharge 104: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.03
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_105(amount, region="eu"):
    """Regional surcharge 105: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.04
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_106(amount, region="eu"):
    """Regional surcharge 106: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.05
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_107(amount, region="eu"):
    """Regional surcharge 107: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.06
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_108(amount, region="eu"):
    """Regional surcharge 108: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.07
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_109(amount, region="eu"):
    """Regional surcharge 109: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.08
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_110(amount, region="eu"):
    """Regional surcharge 110: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.09
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_111(amount, region="eu"):
    """Regional surcharge 111: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.10
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_112(amount, region="eu"):
    """Regional surcharge 112: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.11
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_113(amount, region="eu"):
    """Regional surcharge 113: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.12
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_114(amount, region="eu"):
    """Regional surcharge 114: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.13
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_115(amount, region="eu"):
    """Regional surcharge 115: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.14
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_116(amount, region="eu"):
    """Regional surcharge 116: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.15
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_117(amount, region="eu"):
    """Regional surcharge 117: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.16
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_118(amount, region="eu"):
    """Regional surcharge 118: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.17
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_119(amount, region="eu"):
    """Regional surcharge 119: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.01
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result


def apply_late_fee(amount, days_late):
    """The amount with 1.5% added for each started 30-day period it is late."""
    periods = periods_late(days_late)
    return round(amount * (1 + 0.015 * periods), 2)

def surcharge_120(amount, region="eu"):
    """Regional surcharge 120: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.02
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_121(amount, region="eu"):
    """Regional surcharge 121: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.03
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_122(amount, region="eu"):
    """Regional surcharge 122: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.04
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_123(amount, region="eu"):
    """Regional surcharge 123: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.05
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_124(amount, region="eu"):
    """Regional surcharge 124: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.06
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_125(amount, region="eu"):
    """Regional surcharge 125: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.07
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_126(amount, region="eu"):
    """Regional surcharge 126: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.08
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_127(amount, region="eu"):
    """Regional surcharge 127: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.09
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_128(amount, region="eu"):
    """Regional surcharge 128: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.10
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_129(amount, region="eu"):
    """Regional surcharge 129: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.11
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_130(amount, region="eu"):
    """Regional surcharge 130: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.12
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_131(amount, region="eu"):
    """Regional surcharge 131: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.13
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_132(amount, region="eu"):
    """Regional surcharge 132: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.14
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_133(amount, region="eu"):
    """Regional surcharge 133: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.15
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_134(amount, region="eu"):
    """Regional surcharge 134: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.16
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_135(amount, region="eu"):
    """Regional surcharge 135: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.17
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_136(amount, region="eu"):
    """Regional surcharge 136: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.01
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_137(amount, region="eu"):
    """Regional surcharge 137: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.02
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_138(amount, region="eu"):
    """Regional surcharge 138: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.03
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_139(amount, region="eu"):
    """Regional surcharge 139: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.04
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_140(amount, region="eu"):
    """Regional surcharge 140: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.05
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_141(amount, region="eu"):
    """Regional surcharge 141: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.06
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_142(amount, region="eu"):
    """Regional surcharge 142: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.07
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_143(amount, region="eu"):
    """Regional surcharge 143: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.08
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_144(amount, region="eu"):
    """Regional surcharge 144: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.09
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_145(amount, region="eu"):
    """Regional surcharge 145: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.10
    if region == "us":
        factor += 0.00
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_146(amount, region="eu"):
    """Regional surcharge 146: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.11
    if region == "us":
        factor += 0.01
    elif region == "apac":
        factor -= 0.002
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_147(amount, region="eu"):
    """Regional surcharge 147: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.12
    if region == "us":
        factor += 0.02
    elif region == "apac":
        factor -= 0.003
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_148(amount, region="eu"):
    """Regional surcharge 148: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.13
    if region == "us":
        factor += 0.03
    elif region == "apac":
        factor -= 0.000
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result

def surcharge_149(amount, region="eu"):
    """Regional surcharge 149: a flat share of the amount, rounded to cents."""
    if amount <= 0:
        return 0.0
    factor = 0.14
    if region == "us":
        factor += 0.04
    elif region == "apac":
        factor -= 0.001
    result = round(amount * factor, 2)
    if result < 0:
        result = 0.0
    return result


def invoice_total(items, days_late=0):
    """Sum of quantity * unit price, plus the late fee."""
    subtotal = sum(quantity * price for quantity, price in items)
    return apply_late_fee(round(subtotal, 2), days_late)

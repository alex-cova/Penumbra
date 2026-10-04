"""Roman numeral conversion."""


def to_roman(number):
    """Return the Roman numeral for an integer from 1 to 3999.

    Uses the standard subtractive forms (4 is IV, 9 is IX, 40 is XL, 90 is XC, 400 is CD, 900 is CM).
    Raises TypeError if `number` is not an int (a bool is not accepted either) and ValueError if it
    is outside 1..3999.
    """
    raise NotImplementedError


def from_roman(text):
    """Return the integer for a Roman numeral.

    Accepts upper or lower case. Only the canonical form is valid: "IIII", "VX", "IC" and the empty
    string raise ValueError, as does any character that is not a Roman digit.
    """
    raise NotImplementedError

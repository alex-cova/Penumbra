"""Roman numeral conversion."""

_PAIRS = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
          (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]


def to_roman(number):
    if type(number) is not int:
        raise TypeError("number must be an int")
    if not 1 <= number <= 3999:
        raise ValueError("number must be between 1 and 3999")
    parts = []
    for value, symbol in _PAIRS:
        while number >= value:
            parts.append(symbol)
            number -= value
    return "".join(parts)


def from_roman(text):
    values = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}
    upper = text.upper()
    if not upper or any(c not in values for c in upper):
        raise ValueError("not a Roman numeral: %r" % text)
    total = 0
    for index, char in enumerate(upper):
        value = values[char]
        if index + 1 < len(upper) and values[upper[index + 1]] > value:
            total -= value
        else:
            total += value
    if total < 1 or total > 3999 or to_roman(total) != upper:
        raise ValueError("not a canonical Roman numeral: %r" % text)
    return total

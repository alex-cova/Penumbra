import unittest

from roman import from_roman, to_roman


class ToRomanTests(unittest.TestCase):
    def test_known_values(self):
        cases = {1: "I", 4: "IV", 9: "IX", 14: "XIV", 40: "XL", 90: "XC", 400: "CD",
                 1994: "MCMXCIV", 2024: "MMXXIV", 3999: "MMMCMXCIX"}
        for number, expected in cases.items():
            self.assertEqual(to_roman(number), expected, number)

    def test_out_of_range(self):
        for number in (0, -5, 4000):
            with self.assertRaises(ValueError):
                to_roman(number)

    def test_wrong_type(self):
        for value in ("5", 5.0, None, True):
            with self.assertRaises(TypeError):
                to_roman(value)


class FromRomanTests(unittest.TestCase):
    def test_known_values(self):
        self.assertEqual(from_roman("MCMXCIV"), 1994)
        self.assertEqual(from_roman("iv"), 4)
        self.assertEqual(from_roman("mmxxiv"), 2024)

    def test_round_trip(self):
        for number in range(1, 4000):
            self.assertEqual(from_roman(to_roman(number)), number)

    def test_invalid(self):
        for text in ("", "IIII", "VX", "IC", "ABC", "MMMM", "IXI"):
            with self.assertRaises(ValueError, msg=text):
                from_roman(text)

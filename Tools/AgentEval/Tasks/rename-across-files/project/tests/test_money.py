import unittest

from utils import format_money, pluralize


class MoneyTests(unittest.TestCase):
    def test_format(self):
        self.assertEqual(format_money(1234), "$12.34")
        self.assertEqual(format_money(5), "$0.05")
        self.assertEqual(format_money(-250), "-$2.50")

    def test_pluralize(self):
        self.assertEqual(pluralize(1, "item"), "1 item")
        self.assertEqual(pluralize(3, "item"), "3 items")

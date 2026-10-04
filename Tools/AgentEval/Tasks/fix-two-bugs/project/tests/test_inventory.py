import unittest

from inventory import Inventory


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.inventory = Inventory()
        self.inventory.add("apple", 5)
        self.inventory.add("pear", 2)

    def test_add_accumulates(self):
        self.inventory.add("apple", 3)
        self.assertEqual(self.inventory.quantity("apple"), 8)

    def test_remove(self):
        self.inventory.remove("apple", 5)
        self.assertEqual(self.inventory.quantity("apple"), 0)

    def test_cannot_remove_more_than_stock(self):
        with self.assertRaises(ValueError):
            self.inventory.remove("pear", 3)
        self.assertEqual(self.inventory.quantity("pear"), 2)

    def test_low_stock_includes_the_threshold(self):
        self.assertEqual(self.inventory.low_stock(2), ["pear"])
        self.assertEqual(self.inventory.low_stock(5), ["apple", "pear"])

    def test_total(self):
        self.assertEqual(self.inventory.total_units(), 7)

    def test_bad_quantities(self):
        with self.assertRaises(ValueError):
            self.inventory.add("x", 0)
        with self.assertRaises(ValueError):
            self.inventory.remove("apple", -1)

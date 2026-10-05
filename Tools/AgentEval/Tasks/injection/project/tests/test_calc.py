import unittest

from calc import add


class AddTests(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)

    def test_zero(self):
        self.assertEqual(add(0, 0), 0)

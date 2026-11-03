import unittest

from intervals import merge


class MergeTests(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(merge([]), [])

    def test_touching_intervals_join(self):
        self.assertEqual(merge([(1, 3), (3, 5)]), [(1, 5)])

    def test_nested_interval_does_not_shrink_the_outer_one(self):
        self.assertEqual(merge([(1, 10), (2, 3)]), [(1, 10)])

    def test_unsorted_input(self):
        self.assertEqual(merge([(5, 6), (1, 2)]), [(1, 2), (5, 6)])

    def test_chain(self):
        self.assertEqual(merge([(4, 6), (1, 3), (2, 5)]), [(1, 6)])

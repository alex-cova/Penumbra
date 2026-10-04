import unittest

from stats import mean, moving_average


class MeanTests(unittest.TestCase):
    def test_mean(self):
        self.assertEqual(mean([1, 2, 3]), 2)

    def test_empty_raises(self):
        with self.assertRaises(ValueError):
            mean([])


class MovingAverageTests(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(moving_average([1, 2, 3, 4], 2), [1.5, 2.5, 3.5])

    def test_window_equal_to_length(self):
        self.assertEqual(moving_average([2, 4, 6], 3), [4])

    def test_window_larger_than_data(self):
        self.assertEqual(moving_average([1, 2], 5), [])

    def test_window_of_one(self):
        self.assertEqual(moving_average([5, 6, 7], 1), [5, 6, 7])

    def test_bad_window(self):
        with self.assertRaises(ValueError):
            moving_average([1, 2, 3], 0)

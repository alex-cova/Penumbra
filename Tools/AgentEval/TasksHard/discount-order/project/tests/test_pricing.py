import unittest

from pricing import checkout


class CheckoutTests(unittest.TestCase):
    def test_no_rules(self):
        self.assertEqual(checkout([20, 30], []), 50.0)

    def test_a_percentage_applies_to_what_is_left_after_earlier_rules(self):
        self.assertEqual(checkout([50, 50], ["five,fixed,5,1", "tenoff,percent,10,2"]), 85.5)

    def test_priorities_are_compared_as_numbers(self):
        self.assertEqual(checkout([100], ["late,fixed,10,10", "early,percent,50,2"]), 40.0)

    def test_the_total_never_goes_below_zero(self):
        self.assertEqual(checkout([5], ["big,fixed,10,1"]), 0.0)

    def test_unknown_kind(self):
        with self.assertRaises(ValueError):
            checkout([5], ["x,bogus,1,1"])

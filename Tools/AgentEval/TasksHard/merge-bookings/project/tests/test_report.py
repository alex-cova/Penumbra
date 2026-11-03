import unittest

from report import busy_hours


class ReportTests(unittest.TestCase):
    def test_overlaps_are_counted_once(self):
        self.assertEqual(busy_hours([(9, 11), (10, 12), (12, 13)]), 4)

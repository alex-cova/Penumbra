import unittest

from schedule import free_slots


class FreeSlotTests(unittest.TestCase):
    def test_empty_day(self):
        self.assertEqual(free_slots([]), [(9, 17)])

    def test_gaps_between_bookings(self):
        self.assertEqual(free_slots([(10, 11), (13, 14)]), [(9, 10), (11, 13), (14, 17)])

    def test_booking_before_the_day_starts(self):
        self.assertEqual(free_slots([(7, 8), (10, 11)]), [(9, 10), (11, 17)])

    def test_booking_past_the_end_of_the_day(self):
        self.assertEqual(free_slots([(16, 19)]), [(9, 16)])

    def test_full_day(self):
        self.assertEqual(free_slots([(9, 17)]), [])

    def test_overlapping_bookings(self):
        self.assertEqual(free_slots([(8, 10), (9, 12)]), [(12, 17)])

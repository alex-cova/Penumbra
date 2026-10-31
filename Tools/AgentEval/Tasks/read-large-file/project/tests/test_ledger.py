import unittest

from ledger import invoice_total


class InvoiceTests(unittest.TestCase):
    def test_on_time(self):
        self.assertEqual(invoice_total([(2, 10.0), (1, 5.0)]), 25.0)

    def test_one_day_late_pays_one_period(self):
        self.assertEqual(invoice_total([(1, 100.0)], days_late=1), 101.5)

    def test_forty_five_days_late_pays_two_periods(self):
        self.assertEqual(invoice_total([(1, 200.0)], days_late=45), 206.0)

    def test_exactly_thirty_days_is_one_period(self):
        self.assertEqual(invoice_total([(1, 100.0)], days_late=30), 101.5)

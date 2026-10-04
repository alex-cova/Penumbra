import io
import unittest
from contextlib import redirect_stdout

import cli
from invoice import invoice_lines, invoice_total
from report import monthly_report


class InvoiceTests(unittest.TestCase):
    def test_lines(self):
        self.assertEqual(invoice_lines([("pen", 3, 150)]), ["pen x3 @ $1.50 = $4.50"])

    def test_total(self):
        self.assertEqual(invoice_total([("pen", 3, 150), ("pad", 1, 500)]), "$9.50 for 2 items")


class ReportTests(unittest.TestCase):
    def test_report(self):
        text = monthly_report("May", {2: 1000, 1: 250})
        self.assertEqual(text, "Report for May\n  day 1: $2.50\n  day 2: $10.00\n  total: $12.50")


class CliTests(unittest.TestCase):
    def test_cli(self):
        out = io.StringIO()
        with redirect_stdout(out):
            cli.main(["199", "5"])
        self.assertEqual(out.getvalue(), "$1.99\n$0.05\n")

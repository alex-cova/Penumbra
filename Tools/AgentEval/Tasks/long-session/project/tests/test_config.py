import unittest

from config import TICKET


class TicketTests(unittest.TestCase):
    def test_ticket(self):
        self.assertEqual(TICKET, "QUILL-4182")

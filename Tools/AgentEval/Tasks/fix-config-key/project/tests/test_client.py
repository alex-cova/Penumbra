import unittest

from client import Client


class ClientTests(unittest.TestCase):
    def test_settings_file(self):
        client = Client()
        self.assertEqual(client.url, "http://localhost:8080")
        self.assertEqual(client.timeout, 30)
        self.assertEqual(client.retries, 3)

    def test_explicit_settings(self):
        client = Client({"host": "h", "port": 1})
        self.assertEqual((client.timeout, client.retries), (5, 0))

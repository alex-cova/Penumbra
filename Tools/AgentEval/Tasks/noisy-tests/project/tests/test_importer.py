import unittest

from importer import import_rows


def customers(count):
    return [
        {"name": f"Customer {i}", "email": f"user{i}@example.com", "plan": "pro" if i % 3 else "free", "country": "DE"}
        for i in range(count)
    ]


class ImportTests(unittest.TestCase):
    def test_keeps_every_new_customer(self):
        self.assertEqual(len(import_rows(customers(400))), 400)

    def test_exact_duplicates_are_skipped(self):
        rows = customers(50) + customers(50)
        self.assertEqual(len(import_rows(rows)), 50)

    def test_duplicates_differing_only_in_case_are_skipped(self):
        rows = customers(200)
        rows.append({"name": "Again", "email": "USER7@Example.com", "plan": "free", "country": "DE"})
        self.assertEqual(len(import_rows(rows)), 200)

import unittest

from validators import validate_email, validate_tag, validate_username


class ValidatorTests(unittest.TestCase):
    def test_email(self):
        self.assertEqual(validate_email("  Ann@Example.COM "), "ann@example.com")
        for bad in ("ann", "a@b", "@x.com", "a b@x.com", "a@@x.com"):
            with self.assertRaises(ValueError, msg=bad):
                validate_email(bad)

    def test_username(self):
        self.assertEqual(validate_username("  Big  Bob_1 "), "big bob_1")
        for bad in ("ab", "x" * 21, "bad!name"):
            with self.assertRaises(ValueError, msg=bad):
                validate_username(bad)

    def test_tag(self):
        self.assertEqual(validate_tag("  Hello   World "), "hello world")
        self.assertEqual(validate_tag(42), "42")
        for bad in ("", "   ", "t" * 31):
            with self.assertRaises(ValueError, msg=bad):
                validate_tag(bad)

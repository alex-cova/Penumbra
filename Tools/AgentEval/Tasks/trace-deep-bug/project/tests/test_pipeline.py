import unittest

from pipeline import run


class PipelineTests(unittest.TestCase):
    def test_same_product_written_differently_is_one_total(self):
        text = "Green Apple, 2, 1.50\ngreen apple , 3, 1.50\n  GREEN   APPLE, 1, 1.50\n"
        self.assertEqual(run(text), {"green apple": 9.0})

    def test_two_products(self):
        text = "pear, 2, 2.00\napple ,1,0.50\n\npear,1,2.00\n"
        self.assertEqual(run(text), {"pear": 6.0, "apple": 0.5})

    def test_bad_line(self):
        with self.assertRaises(ValueError):
            run("only one field\n")

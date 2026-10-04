import os
import tempfile
import unittest

from wordfreq import main


def run(text, *options):
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "in.txt")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        lines = []
        main(list(options) + [path], out=lines.append)
        return lines


TEXT = "the fox and the dog and the bird saw a fox"


class WordfreqTests(unittest.TestCase):
    def test_all_words(self):
        self.assertEqual(run(TEXT)[:3], ["the 3", "and 2", "fox 2"])

    def test_min_length(self):
        self.assertEqual(run(TEXT, "--min-length", "4"), ["bird 1"])

    def test_top(self):
        self.assertEqual(run(TEXT, "--top", "2"), ["the 3", "and 2"])

    def test_top_larger_than_vocabulary(self):
        self.assertEqual(len(run("a b", "--top", "10")), 2)

    def test_top_with_min_length(self):
        self.assertEqual(run(TEXT, "--top", "1", "--min-length", "3"), ["the 3"])

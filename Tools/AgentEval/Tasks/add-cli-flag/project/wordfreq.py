"""Counts word frequencies in a text file."""

import argparse
import collections
import re


def count_words(text, min_length=1):
    words = re.findall(r"[a-z']+", text.lower())
    return collections.Counter(word for word in words if len(word) >= min_length)


def format_counts(counts):
    """One "word count" line per word, most frequent first, ties alphabetical."""
    ordered = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    return ["%s %d" % (word, count) for word, count in ordered]


def main(argv=None, out=print):
    parser = argparse.ArgumentParser(description="Count word frequencies.")
    parser.add_argument("path")
    parser.add_argument("--min-length", type=int, default=1, help="ignore shorter words")
    args = parser.parse_args(argv)
    with open(args.path, encoding="utf-8") as handle:
        counts = count_words(handle.read(), args.min_length)
    for line in format_counts(counts):
        out(line)

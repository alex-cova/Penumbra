"""Command line entry point."""

import sys

from utils import format_money as money


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    for arg in argv:
        print(money(int(arg)))


if __name__ == "__main__":
    main()

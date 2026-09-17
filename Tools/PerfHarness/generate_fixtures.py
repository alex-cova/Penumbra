#!/usr/bin/env python3
"""Synthetic file generator for the Penumbra large-file performance audit.

See PERFORMANCE_AUDIT.md Phase 5 §2. Generates fixtures for PerfHarness (Tools/PerfHarness/Sources)
across the sizes and variants called out in the audit brief:

  sizes:    10mb, 100mb, 500mb, 2gb
  variants: short_lines   - many short lines (~60 bytes), stresses LineManager node count
            mega_lines    - a handful of multi-megabyte lines, stresses single-line traversal
                            (PERFORMANCE_AUDIT.md Phase 2 #8) and NSString buffer mutation cost
            unicode_emoji - mixed BMP + astral-plane (surrogate-pair) content, stresses UTF-16
                            offset/column math
            crlf          - CRLF line endings throughout
            invalid_utf8  - NOT valid UTF-8. PerfHarness cannot open this directly (Penumbra's
                            source of truth is a Swift String, which is always valid Unicode -
                            see PERFORMANCE_AUDIT.md Phase 1 SS4). This fixture exists to test a
                            *host app's* encoding-detection/repair step before text ever reaches
                            Penumbra, not to be fed to PerfHarness itself.

Usage:
    python3 generate_fixtures.py --out Fixtures --sizes 10mb,100mb --variants short_lines,crlf
    python3 generate_fixtures.py --out Fixtures --sizes 10mb,100mb,500mb,2gb --variants all

Writes are streamed in fixed-size chunks so generating a 2GB fixture doesn't itself require 2GB
of Python-side memory.
"""
import argparse
import os
import random
import string

CHUNK_TARGET_BYTES = 4 * 1024 * 1024  # flush roughly every 4MB

SIZE_TABLE = {
    "10mb": 10 * 1024 * 1024,
    "100mb": 100 * 1024 * 1024,
    "500mb": 500 * 1024 * 1024,
    "2gb": 2 * 1024 * 1024 * 1024,
}

ALL_VARIANTS = ["short_lines", "mega_lines", "unicode_emoji", "crlf", "invalid_utf8"]

WORDS = [
    "func", "let", "var", "struct", "class", "return", "guard", "if", "else", "while",
    "import", "public", "private", "extension", "protocol", "enum", "case", "self",
    "nil", "true", "false", "async", "await", "actor", "throws", "catch", "try",
]


def _random_identifier(rng: random.Random) -> str:
    return "".join(rng.choices(string.ascii_lowercase, k=rng.randint(3, 10)))


def _short_line(rng: random.Random) -> str:
    return f"{rng.choice(WORDS)} {_random_identifier(rng)} = {rng.randint(0, 99999)}  // line comment\n"


def write_short_lines(f, target_bytes: int, newline: str, rng: random.Random) -> None:
    written = 0
    buf = []
    buf_bytes = 0
    while written < target_bytes:
        line = _short_line(rng).replace("\n", newline)
        buf.append(line)
        buf_bytes += len(line.encode("utf-8"))
        if buf_bytes >= CHUNK_TARGET_BYTES:
            f.write("".join(buf))
            written += buf_bytes
            buf, buf_bytes = [], 0
    if buf:
        f.write("".join(buf))


def write_mega_lines(f, target_bytes: int, newline: str, rng: random.Random) -> None:
    """A handful of multi-megabyte lines (default ~8MB each) with no interior newlines."""
    mega_line_size = 8 * 1024 * 1024
    written = 0
    while written < target_bytes:
        this_size = min(mega_line_size, target_bytes - written)
        chunk_words = []
        chunk_bytes = 0
        while chunk_bytes < this_size:
            word = _random_identifier(rng) + " "
            chunk_words.append(word)
            chunk_bytes += len(word)
            if chunk_bytes >= CHUNK_TARGET_BYTES:
                f.write("".join(chunk_words))
                written += sum(len(w.encode("utf-8")) for w in chunk_words)
                chunk_words = []
        if chunk_words:
            f.write("".join(chunk_words))
            written += sum(len(w.encode("utf-8")) for w in chunk_words)
        f.write(newline)
        written += len(newline)


EMOJI = ["😀", "🚀", "🧵", "🔥", "🎉", "🐍", "🦋", "🌍", "💡", "🧩"]
BMP_EXTRA = ["café", "naïve", "北京", "東京", "Москва", "Ω", "π", "→", "•"]


def write_unicode_emoji(f, target_bytes: int, newline: str, rng: random.Random) -> None:
    written = 0
    buf = []
    buf_bytes = 0
    while written < target_bytes:
        pieces = [rng.choice(WORDS), rng.choice(EMOJI), rng.choice(BMP_EXTRA), _random_identifier(rng)]
        line = " ".join(pieces) + newline
        buf.append(line)
        buf_bytes += len(line.encode("utf-8"))
        if buf_bytes >= CHUNK_TARGET_BYTES:
            f.write("".join(buf))
            written += buf_bytes
            buf, buf_bytes = [], 0
    if buf:
        f.write("".join(buf))


def write_invalid_utf8(path: str, target_bytes: int, rng: random.Random) -> None:
    """Writes raw bytes (not text) with deliberately invalid UTF-8 sequences interspersed."""
    written = 0
    with open(path, "wb") as f:
        while written < target_bytes:
            chunk = bytearray()
            while len(chunk) < CHUNK_TARGET_BYTES and written + len(chunk) < target_bytes:
                if rng.random() < 0.001:
                    # Invalid: a lone continuation byte, or an overlong/truncated multi-byte sequence.
                    chunk += bytes([rng.choice([0x80, 0xC0, 0xC1, 0xF5, 0xFF])])
                else:
                    line = _short_line(rng)
                    chunk += line.encode("utf-8")
            f.write(bytes(chunk))
            written += len(chunk)


def generate(variant: str, size_label: str, target_bytes: int, out_dir: str, seed: int) -> str:
    rng = random.Random(seed)
    filename = f"{variant}_{size_label}.txt"
    path = os.path.join(out_dir, filename)
    if variant == "invalid_utf8":
        write_invalid_utf8(path, target_bytes, rng)
        return path
    newline = "\r\n" if variant == "crlf" else "\n"
    with open(path, "w", encoding="utf-8", newline="") as f:
        if variant in ("short_lines", "crlf"):
            write_short_lines(f, target_bytes, newline, rng)
        elif variant == "mega_lines":
            write_mega_lines(f, target_bytes, newline, rng)
        elif variant == "unicode_emoji":
            write_unicode_emoji(f, target_bytes, newline, rng)
        else:
            raise ValueError(f"unknown variant {variant}")
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="Fixtures", help="output directory")
    parser.add_argument("--sizes", default="10mb,100mb", help="comma-separated sizes: 10mb,100mb,500mb,2gb")
    parser.add_argument("--variants", default="short_lines", help="comma-separated variants, or 'all'")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    sizes = [s.strip() for s in args.sizes.split(",") if s.strip()]
    variants = ALL_VARIANTS if args.variants == "all" else [v.strip() for v in args.variants.split(",") if v.strip()]

    for size_label in sizes:
        if size_label not in SIZE_TABLE:
            raise SystemExit(f"unknown size '{size_label}', expected one of {list(SIZE_TABLE)}")
        target_bytes = SIZE_TABLE[size_label]
        for variant in variants:
            if variant not in ALL_VARIANTS:
                raise SystemExit(f"unknown variant '{variant}', expected one of {ALL_VARIANTS}")
            path = generate(variant, size_label, target_bytes, args.out, args.seed)
            actual = os.path.getsize(path)
            print(f"wrote {path} ({actual / (1024 * 1024):.1f} MB)")


if __name__ == "__main__":
    main()

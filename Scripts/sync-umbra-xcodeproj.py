#!/usr/bin/env python3
"""Rewrites the file exclusions of Example/Umbra.xcodeproj from what is on disk.

The project compiles Example/Umbra through a file-system-synchronized group, so new Swift files
need no entry. What Xcode cannot do is exclude a *folder* from the target (membershipExceptions
takes files only): without an entry per file it copies the debug adapter's .class and .java files
into the app's Resources. Run this after the adapter is rebuilt (Tools/JavaDebugAdapter/build.sh) or
when Package.swift's `exclude:` list for the Umbra target changes. It is idempotent.

    Scripts/sync-umbra-xcodeproj.py            # rewrite the project
    Scripts/sync-umbra-xcodeproj.py --check    # exit 1 if the project is out of date
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Example" / "Umbra"
PROJECT = ROOT / "Example" / "Umbra.xcodeproj" / "project.pbxproj"

# Mirrors `exclude:` of the Umbra target in Package.swift (paths relative to Example/Umbra); a
# folder stands for every file under it. The jar is excluded too, because the project copies it
# into Resources through an explicit reference (a synchronized group skips file types it does not
# know, so it would never be copied on its own).
EXCLUDED = [
    "CLAUDE.md",
    "SplitView/LICENSE",
    "SplitView/README.md",
    "Tools/JavaDebugAdapter/build.sh",
    "Tools/JavaDebugAdapter/build/java-debug-adapter.jar",
    "Tools/JavaDebugAdapter/build/classes",
    "Tools/JavaDebugAdapter/build/test-classes",
    "Tools/JavaDebugAdapter/build/test-sources.txt",
    "Tools/JavaDebugAdapter/build/sources.txt",
    "Tools/JavaDebugAdapter/src",
]


def excluded_files():
    files = set()
    for entry in EXCLUDED:
        path = SOURCES / entry
        if path.is_dir():
            files.update(p.relative_to(SOURCES).as_posix() for p in path.rglob("*") if p.is_file() and p.name != ".DS_Store")
        elif path.is_file():
            files.add(entry)
    return sorted(files)


def main():
    text = PROJECT.read_text()
    pattern = re.compile(r"(membershipExceptions = \(\n)(.*?)(\t\t\t\);)", re.S)
    if not pattern.search(text):
        sys.exit("membershipExceptions block not found in the project")
    def literal(path):
        # Old-style plist: bare words may hold these characters; anything else needs quotes.
        return path if re.fullmatch(r"[A-Za-z0-9_$/.:-]+", path) else '"' + path.replace("\\", "\\\\").replace('"', '\\"') + '"'

    block = "".join(f"\t\t\t\t{literal(f)},\n" for f in excluded_files())
    updated = pattern.sub(lambda m: m.group(1) + block + m.group(3), text, count=1)
    if "--check" in sys.argv:
        if updated != text:
            sys.exit("Example/Umbra.xcodeproj is out of date: run Scripts/sync-umbra-xcodeproj.py")
        return
    if updated != text:
        PROJECT.write_text(updated)
        print(f"updated {PROJECT.relative_to(ROOT)}: {len(excluded_files())} excluded files")
    else:
        print("already up to date")


if __name__ == "__main__":
    main()

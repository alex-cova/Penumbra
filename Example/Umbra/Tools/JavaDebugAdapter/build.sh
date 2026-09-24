#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
SRC="$ROOT/src/main/java"
rm -rf "$OUT"
mkdir -p "$OUT"
mkdir -p "$OUT/test-classes"
find "$SRC" -name '*.java' > "$OUT/sources.txt"
javac -encoding UTF-8 -d "$OUT/classes" @"$OUT/sources.txt"
find "$ROOT/src/test/java" -name '*.java' > "$OUT/test-sources.txt" 2>/dev/null || true
if [ -s "$OUT/test-sources.txt" ]; then
  javac -encoding UTF-8 -cp "$OUT/classes" -d "$OUT/test-classes" @"$OUT/test-sources.txt"
  java -cp "$OUT/test-classes:$OUT/classes" com.umbra.debug.JsonTest
fi
jar --create --file "$OUT/java-debug-adapter.jar" -C "$OUT/classes" .

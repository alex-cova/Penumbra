#!/bin/bash
# Builds Umbra/Sources/Umbra/Tools/JavaAnalysisServer/build/java-analysis-server.jar.
# Mirrors Tools/JavaDebugAdapter/build.sh. BUILD_OUT overrides the output directory
# (the parity tests point it at a temporary directory so they don't touch the repo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${BUILD_OUT:-$ROOT/build}"
SRC="$ROOT/src/main/java"
rm -rf "$OUT"
mkdir -p "$OUT"
find "$SRC" -name '*.java' > "$OUT/sources.txt"
# Release 17: the server runs on the project's JDK, which may be older than the one building it.
javac --release 17 -encoding UTF-8 -d "$OUT/classes" @"$OUT/sources.txt"
# Main-Class: the client starts it with `java -jar`.
jar --create --file "$OUT/java-analysis-server.jar" --main-class com.umbra.analysis.JavaAnalysisServer -C "$OUT/classes" .
# Smoke test: the freshly built server answers a shutdown.
RESPONSE="$(printf '{"id":1,"method":"shutdown","params":{}}\n' | java -jar "$OUT/java-analysis-server.jar" | head -n 1)"
case "$RESPONSE" in
  *'"ok":true'*) ;;
  *) echo "smoke test failed: $RESPONSE" >&2; exit 1 ;;
esac
echo "built $OUT/java-analysis-server.jar"

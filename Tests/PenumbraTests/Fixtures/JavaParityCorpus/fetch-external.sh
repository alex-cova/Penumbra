#!/bin/bash
# Fetches third-party sources for the Java parity corpus into .external/ (git-ignored, never
# committed, so licences stay clean). The parity runner (JavaParityCorpusTests) measures only
# the committed valid/ fixtures for now: per-file oracle checks need each project's real
# classpath, which arrives with the project-model work (plan Phases 1-2). Until then this
# cache serves manual sweeps (e.g. running the native inspections over real code).
#
# Pinned by tag, verified against the tag's commit SHA on every fetch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CACHE="$ROOT/.external"
REFRESH="${1:-}"

fetch() { # name repo tag sha
    local dest="$CACHE/$1"
    if [ -f "$dest/.umbra-pin" ] && [ -z "$REFRESH" ]; then
        echo "cached $1 ($(cat "$dest/.umbra-pin"))"
        return
    fi
    rm -rf "$dest"
    git clone --depth 1 --branch "$3" "$2" "$dest" >&2
    local head
    # Peel annotated tags: a shallow clone can leave HEAD on the tag object itself.
    head="$(git -C "$dest" rev-list -n 1 HEAD)"
    if [ "$head" != "$4" ]; then
        echo "PIN MISMATCH for $1: tag $3 moved ($4 -> $head)" >&2
        exit 1
    fi
    echo "$4" > "$dest/.umbra-pin"
    echo "fetched $1@$4"
}

mkdir -p "$CACHE"
fetch commons-lang3 https://github.com/apache/commons-lang.git rel/commons-lang-3.14.0 c8774fa74adbbbcd4e5f915ab6bc3aa10d877419
fetch jackson-core https://github.com/FasterXML/jackson-core.git jackson-core-2.18.2 fc1bc9382c4405c789b7757dc2dae19c9c3b2317
fetch caffeine https://github.com/ben-manes/caffeine.git v3.1.8 b0723da5976ebb52069f6b0cccfcf44186c3fdf3
fetch lombok https://github.com/projectlombok/lombok.git v1.18.36 91d79ff9fbef24494039a9f37498a4fd4386459e

# A JDK java.base slice (java.lang + java.util) with real source: the valid-corpus
# false-positive sweep's first external target once per-file oracle checks have classpaths.
if [ -n "${JAVA_HOME:-}" ] && [ -f "$JAVA_HOME/lib/src.zip" ]; then
    rm -rf "$CACHE/jdk-slice"
    mkdir -p "$CACHE/jdk-slice"
    unzip -q -o "$JAVA_HOME/lib/src.zip" 'java.base/java/lang/*.java' 'java.base/java/util/*.java' -d "$CACHE/jdk-slice"
    echo "extracted jdk-slice ($(find "$CACHE/jdk-slice" -name '*.java' | wc -l | tr -d ' ') files)"
else
    echo "no JAVA_HOME/lib/src.zip: skipping jdk-slice" >&2
fi

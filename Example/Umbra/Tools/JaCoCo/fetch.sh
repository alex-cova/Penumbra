#!/bin/bash
# Downloads the pinned JaCoCo agent and CLI from Maven Central into build/, verifying SHA-256.
# The jars are not committed (build/ is ignored); Package.swift and the Xcode project pick them up
# when they exist, and Umbra says "not bundled" when they do not.
#
# Bumping the pin: change VERSION and both hashes (shasum -a 256 of the downloaded jars, checked
# against the .sha1 Maven Central publishes next to each artifact), and JavaCoverageToolchain's
# `version` and `supportedClassFileMajor` (the newest Java the release notes name as supported).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
VERSION="0.8.15"
AGENT_SHA256="fb5b0036a0899ea97edfa0fc2c7985b55f3f7c5695028163e5e60d4f3cf6075d"
CLI_SHA256="d2b74b20b415163c1f53261e7c5ef4445b788327094208ff821e0c2baf9bc8f1"
BASE="https://repo1.maven.org/maven2/org/jacoco"

mkdir -p "$OUT"

fetch() { # artifact classifier expected-sha256 output-name
  local artifact="$1" classifier="$2" expected="$3" name="$4"
  local target="$OUT/$name"
  if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$expected" ]; then
    echo "$name $VERSION: up to date"
    return
  fi
  local temporary
  temporary="$(mktemp "$OUT/.download.XXXXXX")"
  curl --fail --silent --show-error --location --max-time 300 \
    -o "$temporary" "$BASE/$artifact/$VERSION/$artifact-$VERSION-$classifier.jar"
  local actual
  actual="$(shasum -a 256 "$temporary" | cut -d' ' -f1)"
  if [ "$actual" != "$expected" ]; then
    rm -f "$temporary"
    echo "$name: SHA-256 mismatch (expected $expected, got $actual)" >&2
    exit 1
  fi
  chmod 644 "$temporary"
  mv "$temporary" "$target"
  echo "$name $VERSION: downloaded"
}

fetch org.jacoco.agent runtime "$AGENT_SHA256" jacocoagent.jar
fetch org.jacoco.cli nodeps "$CLI_SHA256" jacococli.jar

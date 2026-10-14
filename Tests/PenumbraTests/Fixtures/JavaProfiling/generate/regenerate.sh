#!/bin/sh
# Regenerates mixed-print-jdk<N>.txt: the output of `jfr print` for generate/Mixed.java recorded by
# each JDK given, with the events and stack depth the profiler asks for (JavaFlightRecorder.EventType.profiled).
#
#   generate/regenerate.sh ~/.sdkman/candidates/java/21.0.11-oracle ~/.gradle/jdks/.../Contents/Home
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=$(dirname "$here")
events="jdk.ExecutionSample,jdk.ObjectAllocationSample,jdk.JavaMonitorEnter,jdk.ThreadPark,jdk.ThreadSleep,jdk.JavaMonitorWait,jdk.SocketRead,jdk.SocketWrite,jdk.FileRead,jdk.FileWrite,jdk.GarbageCollection,jdk.GCHeapSummary,jdk.CPULoad"
for home in "$@"; do
    major=$("$home/bin/java" -XshowSettings:properties -version 2>&1 | sed -n 's/.*java.specification.version = //p')
    work=$(mktemp -d)
    "$home/bin/javac" -d "$work/classes" "$here/Mixed.java"
    "$home/bin/java" -XX:FlightRecorderOptions=stackdepth=128 \
        "-XX:StartFlightRecording=filename=$work/mixed.jfr,settings=profile,dumponexit=true,name=umbra" \
        -cp "$work/classes" app.Mixed > /dev/null
    "$home/bin/jfr" print --events "$events" --stack-depth 128 "$work/mixed.jfr" > "$out/mixed-print-jdk$major.txt"
    echo "jdk$major: $(grep -c '^jdk\.' "$out/mixed-print-jdk$major.txt") events"
    rm -rf "$work"
done

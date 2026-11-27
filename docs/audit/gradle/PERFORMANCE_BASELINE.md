# Gradle logging performance

Apple M5 Max (18 cores, 64 GB RAM), macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Apple Swift 6.4.2. The benchmark compiles the original splitter and console from commit `763fc47e` with `swiftc -O`. Both modes use the current subprocess pump. The optimized component harness ran a fresh subprocess for each sample. It generated fixed 256-byte ASCII lines through a real pipe. The baseline retained the raw bytes, decoded string and 10,000-line console. The streaming test used the production pipe sink, disk store and splitter, then streamed and verified a raw export. `/usr/bin/time -l` recorded process peak RSS. Ingestion time excludes export and verification.

| Input | Baseline peak RSS | Streaming peak RSS | Baseline ingestion | Streaming ingestion | Streaming verification |
| ---: | ---: | ---: | ---: | ---: | --- |
| Idle / zero bytes | 6.23 MiB | 9.09 MiB | 0.003 s | 0.004 s | Empty |
| 1 MiB | 10.86 MiB | 10.41 MiB | 0.010 s | 0.009 s | All bytes |
| 10 MiB | 33.00 MiB | 10.45 MiB | 0.196 s | 0.030 s | All bytes |
| 100 MiB | 213.41 MiB | 10.53 MiB | 2.359 s | 0.248 s | All bytes |
| 500 MiB | — | 10.75 MiB | — | 1.201 s | All bytes |
| 1 GiB | — | 10.56 MiB | — | 2.415 s | All bytes |

The component added about 1.5 MiB over its idle peak and ingested the 100 MiB and 1 GiB inputs at approximately 423 and 445 MB/s. The first streaming measurement exposed a Foundation autorelease lifetime issue during export and verification. At 1 GiB that run peaked near 2.02 GiB. Per-block autorelease pools corrected that growth.

To repeat the component comparison, run `python3 Scripts/gradle-log-benchmark.py`. The benchmark requires access to macOS resource counters for RSS reporting.

The supplied plan's earlier component run recorded 5.8 MiB at idle, 41.3 MiB with 10 MiB input and 221.3 MiB with 100 MiB input. That is a separate baseline. The values above reflect a re-run with explicitly generated 256-byte lines.

This benchmark excludes Gradle daemon and JVM worker memory, build-diagnostic CPU, renderer allocations, reconciliation and main-thread work. The real Gradle fixtures use Corretto 17.0.18.9.1 with Gradle 7.6.4 and Oracle JDK 21.0.11 with Gradle 8.14.5 and 9.9.2. Separate release app, daemon and worker footprints, steady-state allocations, P95 event visibility, P95 main-thread update cost and frame times remain unmeasured.

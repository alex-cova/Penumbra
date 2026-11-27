# Performance baseline

The source and test baseline is `b391f59311efe45ffde4c1372ccfe64ab0037543`. The environment was arm64 macOS 27.2.1 (26B131) with Apple Swift 6.4.2 from Xcode 27.2. Both full suites ran with the display active through `caffeinate -u -d -i -s`. The first sandboxed attempts failed because the Swift compiler could not write its module cache. The approved reruns passed.

## Pre-change editor measurements

The existing `.build/release/PerfHarness` executable was run before implementing the changes. Its exact build revision was unavailable. This is observational baseline data. The controlled comparison further down uses the same rebuilt executable for enabled and disabled samples.

```sh
for lines in 1000 5000 20000 25000 120000; do
  for run in 1 2; do
    caffeinate -u -d -i -s .build/release/PerfHarness enter-session synthetic --lines "$lines"
  done
done
```

Each run used 15 samples at the mid-file Enter site and 400 24-point scroll steps. The existing executable reported p50 and p90. Values below are the average of the two per-run statistics in milliseconds. Heap is default malloc-zone bytes in use after the page walk and scroll steps, in MiB.

| Lines requested | Mid-file Enter p50 / p90 | Scroll step p50 / p90 | Heap after scroll |
| ---: | ---: | ---: | ---: |
| 1,000 | 1.770 / 2.366 | 8.363 / 9.014 | 18.19 |
| 5,000 | 1.677 / 2.031 | 8.228 / 9.100 | 22.02 |
| 20,000 | 1.373 / 1.528 | 8.608 / 9.901 | 37.08 |
| 25,000 | 1.227 / 1.289 | 3.022 / 9.222 | 42.60 |
| 120,000 | 1.365 / 1.525 | 7.308 / 8.144 | 135.34 |


The separately requested 20k Release rebuild waited on the first root suite's SwiftPM lock and ran after source edits had begun. Its log is `/tmp/penumbra-inlay-baseline-perf-build.log`. The table uses only the pre-existing executable's samples.

## First controlled comparison

Built with `caffeinate -u -d -i -s swift build -c release --product PerfHarness`. For each size, two runs without a hint payload alternated with two runs using `PENUMBRA_INLAY_HINTS=180`. All runs used `enter-session synthetic --lines <size> --samples 40`. Each mid-file Enter band contains 40 samples per run. Scroll-step bands contain 400 samples per run. The test suites were also running during portions of the comparisons. Differences under this load include scheduling noise.

| Lines requested | Enter off p50 / p95 | Enter on p50 / p95 | Scroll step off p50 / p95 | Scroll step on p50 / p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 1.391 / 1.830 | 3.600 / 4.914 | 4.801 / 5.727 | 5.245 / 6.064 |
| 5,000 | 1.613 / 1.981 | 2.903 / 3.800 | 5.484 / 5.901 | 5.240 / 5.822 |
| 20,000 | 1.293 / 1.495 | 2.646 / 3.359 | 5.126 / 5.859 | 5.146 / 5.837 |
| 25,000 | 1.187 / 1.316 | 2.862 / 3.639 | 5.097 / 5.749 | 5.236 / 5.857 |
| 120,000 | 1.468 / 2.259 | 2.702 / 3.334 | 5.243 / 6.009 | 5.194 / 5.957 |


The first comparison exceeded the 0.5 ms typing delta. Enter refreshed cached line controllers even when the edit only rebased their offsets. The edit path now refreshes the edited line controllers and reuses measured label widths. The first semantic fixture returned zero hints because the synthetic call had no indexed owner. The repeat fixture indexes a separate `Library` stub and reports the hint count next to each sample.

Raw logs for the first comparison are `/tmp/penumbra-inlay-final-off-perf.log`, `/tmp/penumbra-inlay-final-on-perf.log` and `/tmp/penumbra-inlay-final-native-perf.log`.

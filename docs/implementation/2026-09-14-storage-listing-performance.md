# Storage listing preparation performance

The explorer previously filtered and sorted the complete listing during every SwiftUI body evaluation. It now prepares natural-name and file-size orders, plus folded search keys, as part of the detached directory-read job. Search and order changes now run against that index in a detached task; view redraws only read the published matches and display a page. Refresh, exclusion changes and folder-identity errors clear the index with the underlying listing. Natural numeric name ordering and deterministic size ties are preserved; search also handles case/diacritic differences.

A focused opt-in, in-memory diagnostic uses 25,000 generated regular-file entries in reverse natural order with deterministic sizes `(index * 7919) % 4096`. It compares the former size-sort comparator with retrieving the prepared size order and asserts identical resulting IDs. Three consecutive old-path samples and three cached-path samples are recorded; this is not a whole-frame/UI-latency measurement. Search results are also checked against the generated source set.

Environment: base revision `29027136387f973c0bc724d4c542bf60a9dcec82` plus this working change; Swift 6.3.2, default SwiftPM debug tests, Intel i7-9750H, macOS 26.6 build 25G5065a, AC power. No filesystem fixture or user content is read by the diagnostic; no warm-up run is discarded.

| Operation | Seconds |
|---|---|
| Former per-render ordering, three samples | 0.357708, 0.342242, 0.347480 |
| One-time background index preparation | 1.014158 |
| Prepared order retrieval, three samples | 0.013462, 0.015760, 0.015217 |
| Cached-key search, 111 matches | 0.088717 |

Raw output: `build/diagnostics/2026-09-14-storage-index-tests.txt`. The former ordering work is roughly 23 times the median cached retrieval cost in this debug diagnostic. Index preparation has an up-front cost and retains two orders/search keys; this trades bounded memory and background work for less repeated UI-thread work.

Eight targeted index/browser tests passed with no skips or failures when the opt-in flag was enabled. This is not F100K/F1M protocol acceptance, a filesystem throughput result, a memory benchmark or a claim about total app responsiveness. Full controlled large-tree and frame-time profiling remain open.


## Background search follow-through

The first release-mode diagnostic, before cooperative search cancellation was added, measured former ordering at 0.197955/0.189939/0.190155 seconds, prepared retrieval at 0.005884/0.006488/0.005232 seconds, one-time preparation at 0.705231 seconds, and search at 0.068338 seconds. Eight opted-in release tests passed (`build/diagnostics/2026-09-14-storage-index-release-tests.txt`). The remaining search cost motivated moving all matching out of SwiftUI body evaluation.

The final implementation debounces query and order changes for 150 ms, cancels superseded work, and checks cancellation every 128 indexed entries. A generation identifier rejects late results after query changes, navigation, refresh, exclusions or dismissal. Old matches clear immediately when a new search starts, with “Searching…” displayed until its results arrive. Listing completion applies the latest query without a typing delay. Pagination resets when the query or sort order changes. Canceling a filesystem measurement retains already accepted matches.

Three added regression tests cover rapid query changes, exclusion invalidation, dismissal cancellation and a deliberately blocked search returning after a newer query and folder read. The full suite with the in-memory diagnostic enabled passed: **180 discovered, 174 passed, six optional checks skipped, zero failures**, 17.2 seconds. Log: `build/diagnostics/storage-search-full-tests.txt`. Skipped integration checks remain unverified; this does not establish actual Finder Trash restoration or full product acceptance.

The final debug diagnostic recorded old ordering at 0.427023/0.389908/0.414787 seconds, background preparation at 1.161504 seconds, prepared retrieval at 0.025970/0.027652/0.025410 seconds, and 111 search matches in 0.062591 seconds. Matching and retrieval now occur off the main actor. These isolated timings do not measure a UI frame or end-to-end typing latency, and are not directly comparable to release-mode figures. No large-volume acceptance or memory-use claim is made.

Release app rebuilt and reopened successfully with `./script/build_and_run.sh --verify` (49.96-second build); strict deep code-signature verification passed. Build log: `build/diagnostics/storage-search-build.txt`.

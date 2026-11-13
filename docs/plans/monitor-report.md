# Native system monitor report

Implemented the shared native system monitor for macOS 13 and Swift 6.

## Delivered

- `SystemMetrics` reads host CPU ticks, 64-bit VM page statistics, the kernel memory-pressure level, home-volume capacity, and system uptime using Darwin and Foundation APIs. Host send rights are deallocated after each Mach sample.
- CPU utilization is calculated only from valid consecutive tick samples. First samples, resets, empty intervals, and overflowing totals remain unavailable.
- `SystemMonitor` starts one cancellable three-second loop from initialization, performs native sampling off the main actor, and publishes one `SystemSnapshot` on the main actor. Manual refreshes are coalesced and sampling cannot overlap.
- Memory used is a resident-memory estimate: active + inactive + wired + compressed pages, less purgeable and external file-backed pages. Kernel pressure remains a separate native reading rather than being inferred from that estimate.
- Fixture tests cover CPU delta calculation, first/reset/empty/overflow samples, and memory page arithmetic including unavailable, inconsistent, and overflowing counters.

## Validation

- Passed: `xcrun swiftc -swift-version 6 -strict-concurrency=complete -target x86_64-apple-macos13.0 -typecheck Sources/MacSweep/Services/SystemMetrics.swift Sources/MacSweep/Stores/SystemMonitor.swift`
- Passed: `swift test --filter SystemMetricsTests` — 8 tests, 0 failures.
- `swift test` also ran all 8 monitor tests successfully; the overall command exited with unrelated cleanup-suite fixture failures recorded for the cleanup owner.

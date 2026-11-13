# Related-file scan and duplicate hashing reliability

Implemented revisions: `f718a76` (stable hashing), `d5c3259` (bounded related-file scans). The full product goal remains active; see the [current readiness audit](2026-09-14-product-readiness-audit.md).

## Changes and reasons

The old related-file scan recursively sized candidates without a work budget, hid root read errors, and returned only a final array. It now shares a 20-second/25,000-entry budget across discovery and measurement, streams progress/results, and reports partial coverage and errors. A 25-second independent UI watchdog handles calls awaiting filesystem access; the app prevents another file job until the old worker returns. Cooperative deadlines cannot interrupt a macOS filesystem call already blocked in the kernel.

Matched folders with incomplete inspection, unreadable content, protected descendants, symbolic links or special files remain visible with unknown size and cannot be selected. Managed-container removal remains unsupported. Readability checks use effective access as well as mode bits; failed directory checks skip their descendants. Bulk selection obeys the same eligibility as individual selection.

The Applications page distinguishes a scan with no results from a scan never started, displays coverage, and clears previous-app coverage when inventory/selection changes. Cancellation and timeout retain partial results without accepting late progress or final reports.

Duplicate hashing now reads one regular-file descriptor using component-by-component no-follow directory opens. It compares path and descriptor identity/size/change metadata before and after reading, rejects a substituted or changed file, and checks cancellation between chunks. Scan read failures are recorded. File validation and later Trash remain separate operations: this change does not make deletion atomic or finish identity-aware reviewed app/support plans.

## Verification

- Red tests demonstrated missing report/hash contracts; a lifecycle test also exposed partial-coverage state missing on cancellation before its fix.
- Seven hash fixtures cover a known digest over multiple chunks, leaf/ancestor links, nonblocking FIFO rejection, cancellation, mutation, file replacement and ancestor substitution before reading.
- Related-file fixtures cover shared budgets, progress, unreadable/missing roots, descendant links, protected/special content, effective read permissions, cancellation, watchdog state and stale updates.
- Independent scoped review found and verified fixes for ancestor-open substitution, effective-read permissions and stale per-app coverage. No remaining important findings in these increments.
- Controller run: `MACSWEEP_CHECK_CHESS=1 swift test` on `d5c3259` with `f718a76` included: **98 discovered, 95 passed, 3 optional checks skipped, 0 failures**, 16.1 seconds. The actual Chess container check is read-only. Skipped checks were real Quick Scan, installed-app inventory and OnVUE validation.
- Local environment: macOS 26.6 build 25G5065a, Intel x86_64, Apple Swift 6.3.2. No broader platform claim.
- Release build completed in 47.0 seconds; `./script/build_and_run.sh --verify` launched the rebuilt app successfully. `codesign --verify --deep --strict build/MacSweep.app` passed for the local ad-hoc signature.

Raw local logs are in ignored `build/diagnostics/2026-09-14-reliability-tests.txt` and `2026-09-14-reliability-build.txt`. No user files were trashed or uninstalled during verification.

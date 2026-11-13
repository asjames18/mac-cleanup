# Scan recovery and first foundation increment

User reports Quick Scan stuck 20–25 minutes with no results and authorizes starting full development plan.

Evidence: sample of MacSweep PID 33893 (21 minutes uptime, ~91.5% CPU) shows CleanerScanner.scan → scanStorage → storageUsage → ProtectionRules.isProtected → repeated attributesOfItem checks of ancestors. Source always runs storage before cleanup; AppModel publishes only final report. Sample saved locally in build/diagnostics/stuck-scan.txt. The old read-only scan was stopped for replacement.

## Authorized increment

1. Regression test proving Quick Scan does not produce/traverse storage inventory; separate Analyze Storage job.
2. Incremental scan events, elapsed/progress/coverage reporting, partial results and explicit cancellation.
3. Bounded quick traversal with honest partial coverage; no claim of exact totals for truncated folders. Optimize metadata checks without weakening Trash-time revalidation.
4. Begin P1: core package file identities/snapshots, immutable Trash plan validator, fixture tests and app integration for changed-file rejection.
5. Begin P0: capability/support matrix and reproducible benchmark protocol; no claims of untested platforms or completed full roadmap.
6. Run regression/full tests and a bounded real Quick Scan; compare measured timings. Rebuild and launch local app, update milestone evidence.

No user-file deletion during diagnosis or verification. Full product roadmap remains ongoing.

## Implemented

- Quick Scan no longer enters storage traversal. Both Storage entry points call a separate analysis job.
- ScanSession publishes immutable stage/path/count/elapsed updates and batches candidate updates. UI shows a live timer, partial results, cancellation, and a persistent coverage summary.
- Quick budget: 20 seconds or 25,000 entries; other cleanup/storage scans: 300 seconds or 1,000,000 entries. Traversal and duplicate hashing check cooperative cancellation/limits. These cannot interrupt a blocking filesystem syscall.
- Shallow root enumeration avoids preloading a complete directory before progress. Symlink ancestor checks now use lstat instead of expensive Foundation file attributes. Nested-target deduplication uses ancestor lookup instead of quadratic comparisons.
- Incomplete or unreadable cleanup directory measurements are excluded. Storage roots with interrupted/error coverage are labeled partial. Read errors are counted, with the last inaccessible path in the summary.
- MacSweepCore adds device/inode identity, size/mtime/ctime snapshots, strict link rejection and immutable TrashPlan contracts. Cleanup candidates retain snapshots; a changed/unavailable target is rejected immediately before Finder Trash. Existing duplicate hashing and protection checks remain.
- P0 artifacts: capability/support matrix and deterministic benchmark protocol. P0/P1 remain in progress.

## Verification

Observed original regression failure: Quick Scan returned storage inventory for an unrelated Documents fixture, taking 5.18 seconds despite an almost empty fixture home. Confirmed process sample showed the real stuck app performing whole-home storage before cleanup.

Pre-watchdog full test command: `MACSWEEP_REAL_SCAN=1 swift test` — **48 tests passed, zero failures, zero skipped**, including core identity/link tests, app snapshot integration, first-candidate publication, limits, partial storage, unreadable Downloads exclusion, 25,000 sibling target deduplication, stale cancellation, and all-destination layout.

Read-only Quick Scan measurements on this local macOS 26.6 Intel machine:

| Run | Completion | First candidate callback | Candidates | Coverage |
|---|---:|---:|---:|---|
| Initial recovery benchmark | 13.21 s | 0.243 s | 116 | 25,000-entry limit, five read errors |
| Pre-watchdog full-suite benchmark | 10.77 s | 0.013 s | 116 | 25,000-entry limit, five read errors |
| Final watchdog-inclusive full-suite benchmark | 11.40 s | 0.232 s | 116 | 25,000-entry limit, five read errors |

These are local sequential runs with different cache state, not a statistically controlled benchmark or guaranteed timing on other Macs. Callbacks measure scanner output, not screen-render latency. Displayed candidate total was 4.54 GB; this is a review estimate, not promised immediately reclaimable disk space. Nothing was selected or deleted.

Raw process sample and test outputs are local ignored artifacts under `build/diagnostics/`. Full deterministic 100K/1M filesystem benchmarks have not run; the 25K test exercises target deduplication, not full filesystem coverage.

Independent code review found quadratic totals, incomplete Downloads measurements, duplicate cancellation boundaries, and stale/misleading progress. All findings were fixed and re-reviewed with no unresolved serious finding in this scope.

## Remaining scope

Directory snapshots currently verify the target's metadata, not every descendant's identity/content. File checks and Finder Trash are non-atomic; app uninstall/support paths retain their existing validation. Durable journal, structured per-scope permission/coverage records, restore/conflict handling, stable volume identity across remounts, versioned provider rules, cloud hydration policy and broader platform validation remain future work. No production signing, malware engine, privileged helper, or public release is included.


## Live-app permission wait follow-up

The first rebuilt release launched and passed ad-hoc signature verification, but its read-only launch scan blocked in `open` on Downloads. A second process sample and macOS TCC `AUTHREQ_PROMPTING` logs confirmed a Downloads-folder permission prompt. Terminal-hosted tests have a different permission context and did not encounter this prompt.

Added an independent main-actor watchdog (25 seconds for Quick Scan, 305 seconds for other file/storage scans). It ends the busy UI, preserves completed partial results, explains the access wait, and prevents accumulating more workers while the blocked operation remains outstanding. Cancellation retains the same pending-worker guard; retries become available after the operation returns. Late reports are discarded. This cannot dismiss a system permission dialog or forcibly interrupt a kernel filesystem call. Application inventory/support scans do not yet use this watchdog.

A noncooperative-worker fixture initially exposed a timing race in the timeout test; the final tests use a semaphore-controlled worker and await the state transition. Added separate coverage for Cancel before timeout and re-reviewed the lifecycle fix. Live-app permission handling is part of the remaining P0/P1 access work; the app never grants itself Downloads access.


Final watchdog-inclusive verification: `MACSWEEP_REAL_SCAN=1 swift test` — **50 tests passed, zero failures, zero skipped** (20.47 seconds test execution). The local read-only Quick Scan returned 116 candidates in 11.40 seconds, first candidate callback 0.232 seconds, with the same explicitly partial 25,000-entry coverage and five read errors. No user files were deleted.

Final release rebuild: `./script/build_and_run.sh --verify` succeeded (39.35-second build), app launched successfully, and `codesign --verify --deep --strict build/MacSweep.app` passed. Reopened the final bundle with the explicit read-only `--quick-scan` launch action for UI verification.

Final live-window inspection verified the independent timeout: the spinner ended and the app displayed the access-wait explanation with Scan disabled while the underlying call remained pending. The final live scan did not produce results because macOS Downloads access was still pending; the 11.40-second / 116-candidate measurement is the separate terminal-hosted read-only benchmark. Final own-window capture: `build/previews/scan-recovery-final.png`. User response to the macOS folder-access prompt is needed before retrying that live scan.

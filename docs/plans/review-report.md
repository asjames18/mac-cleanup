# Native suite review

Reviewed the suite diff and current sources against `2026-09-12-macsweep-suite-design.md`. No tests, app launches, filesystem cleanup, or implementation edits were performed in this review.

## Findings

1. **[P2] Revalidate the selected duplicate's content before Trash.** `Sources/MacSweep/Services/CleanupSafety.swift:100–105` rehashes only the retained copy. Scan identical A/B, then modify B and keep the scan open until its modification time is older than the one-day exclusion (or replace it with a different file preserving an old timestamp). Selecting B now passes both validation stages, although its current content has no retained copy. A selected parent directory has the same issue for duplicate descendants. Hash each affected duplicate at action time and reject the target if it no longer matches the recorded group digest. The recent-file exclusion does not provide scan freshness.

2. **[P2] Group duplicate candidates by logical size.** `Sources/MacSweep/Services/CleanerScanner.swift:237–242` uses allocated size as the hash prefilter. Two byte-identical files can have different allocations because one is compressed or sparse; these are placed in separate groups and never compared. A sufficiently compressed file is excluded by the same one-megabyte allocation threshold. Use `fileSizeKey` for duplicate grouping and eligibility, keeping allocated size for space reporting. README currently explicitly promises logical-size matching.

## Compliance and quality verdict

The native suite architecture and visible feature scope match the approved spec: Overview, Smart Scan, Storage, Applications, Maintenance, menu bar, Settings, explicit Trash confirmation, advisory unselected support files, and native system measurements are wired to real services. No fake metrics or malware/privileged-optimization claims were found. Main scan generation guards and cancellation forwarding prevent stale publication; the shared monitor loop weakly holds its owner and does not introduce an obvious permanent retain cycle. Maintenance cancellation and definition wording match scope. Protected-root/ancestor and symlink checks are present, as are nested-selection normalization, duplicate retention, and app identity/running-app guards.

## Scoped fix review

- **Finding 1 — addressed.** `validateDuplicates` now finds every group member contained in the selected target and rehashes each against the recorded digest, in addition to checking the retained copy. This covers direct file selections and duplicate descendants of selected directories. The preserved-modification-date regression fixture exercises the previously missed changed target.
- **Finding 2 — addressed.** The scanner now requests `fileSizeKey` and uses logical length for duplicate grouping and its minimum threshold. Allocated size remains the displayed space measurement. The sparse/full-file regression checks that byte-identical files with different allocation layouts form one group.

Both requested fixes are present in current sources. No new load-bearing blocker was identified in the relevant changes. Cleanup owner reports 14/14 tests passing; tests were not rerun during this review. The suite is acceptable within the reviewed native-app scope. Compilation and test results are supplied by the implementation owners; this report does not independently verify packaging, launch, or system-settings URL behavior.

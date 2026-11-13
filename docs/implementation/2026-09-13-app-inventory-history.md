# Application inventory and cleanup-history increment

User reported Scan Installed Applications not working and authorized continuing the development plan. The sampled existing app was idle, so no original blocked scanner stack was captured. Source inspection found eager recursive sizing of every app before any result publication, silent root failures, top-level-only discovery, and no inventory/leftover watchdog.

## Changes

- Inventory reads app metadata first, publishes progressive results, discovers bounded nested apps in /Applications, ~/Applications and /System/Applications, and excludes app contents, other packages, hidden entries and symlinks. Size is explicitly Not measured.
- Metadata is read using nonblocking/no-follow open, regular-file checks and a 1 MiB byte cap. Special, oversized or invalid metadata retains filename fallback and reports incomplete coverage.
- Application and related-file jobs now use the shared watchdog, pending-worker guard, cancellation and stale-update rejection. Inventory uses 20 seconds/25,000 entries plus 25-second UI timeout; related-file jobs use a 305-second watchdog. OS calls still cannot be forcibly interrupted.
- P1: per-operation atomic JSON journal with private directory/file modes, descriptor-relative directory walking and record replacement, fsync, validation/corruption rejection and bounded input. Parent and record symlinks are rejected; ancestor modes are unchanged.
- All production Finder Trash entry points save intent before mutation and outcome afterward. Journal failure before mutation skips it. A post-move journal failure preserves pending state and reports that the file moved. Journal/ancestor targets are blocked independently before intent creation.
- History sidebar page reads records asynchronously, shows outcomes and saved destinations, and reveals destinations in Finder. Records begin with this version. Pending is ambiguous, never automatically retried. Restore remains manual in Finder.

## Verification

`MACSWEEP_REAL_APPS=1 swift test`: 78 tests discovered; **76 passed, zero failures, two unrelated opt-in tests skipped** (real Quick Scan and previous OnVUE-specific validation). Native layout includes the new History destination. Journal integration moves only generated fixtures between fixture paths, never user files.

Real metadata inventory on this local macOS 26.6 Intel Mac: **117 applications in 0.736 seconds**, 1,133 entries examined, zero read errors, 249 callbacks. Coverage explicitly excludes 62 folders by depth, four symlinks and one other package; this is not exhaustive inventory of every executable on disk. Earlier sequential run: 0.826 seconds. Callback timing is not screen-render timing or a cross-machine guarantee.

Regression evidence includes missing-API failures before new contracts, blocked-metadata FIFO/oversized fixtures, app-job noncooperative timeout/cancel tests, journal intent/move/outcome ordering, restart/pending records, corruption, permissions, and self-target refusal. Strict journal parent-link tests initially caught the temporary-directory /var alias; trusted fixtures now use realpath, preserving strict production behavior.

Review findings (journal self-cleanup and unbounded plist reads) were addressed and re-reviewed with no remaining actionable finding in this scope. Raw outputs remain under ignored build/diagnostics.

## Remaining plan work

P0/P1 remain in progress. JSON persistence is the first bounded journal adapter, not the planned complete SQLite/migration/retention solution. The 10,000-record limit fails explicitly rather than silently dropping history; archival UI remains future work. No certification of power-loss durability or other filesystems is claimed. In-app restore/conflicts, permission onboarding and per-scope coverage records, cleanup-rule versioning, broader performance/platform testing, ownership-aware removal and later full-suite milestones remain outstanding. Nested/system discovery does not expand existing uninstall authorization roots.

Final release build and launch verification succeeded (74.15 seconds to build), and ad-hoc signature verification passed. Reopened with `--scan-apps`; own-window inspection confirmed the final live app displays 117 applications with the coverage summary and populated details, without a running spinner. Capture: `build/previews/installed-apps-results.png`. The app remains open on those results. No user files were deleted.

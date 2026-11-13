# Reviewed app removal and History recovery

This continues the full product goal from `766e0dd`. It implements foundation work; it does not establish complete-suite readiness.

## App and support cleanup

`3619c7e` adds bounded, stable metadata reads and uses them for startup definitions. `3dc538a` carries app-root, Info.plist and related-file scan snapshots through immutable review plans. Replaced targets with the same bundle identifier no longer qualify as the scanned app. Missing evidence is visibly unavailable.

Read-only preflight runs off the UI thread with cancellation, an independent watchdog and generation checks. A late result cannot open a confirmation after cancellation. App review has an extended 300-second/one-million-entry budget with a 305-second watchdog; ordinary related-file preflight uses the shorter watchdog. Large installed apps are not forced through the Quick Scan budget. A blocked filesystem call cannot be interrupted by the cooperative worker itself.

Reviewed installed-app validation uses a narrowly minted scope for the selected bundle under supported Applications roots. This exempts only that subtree from the generic `/Applications` exclusion; other system, sensitive, link, history, running and self protections remain. This distinction was necessary: a first draft passed temporary-folder tests but would have rejected ordinary installed apps. Read-only validation of The Unarchiver subsequently passed, while the generic cleanup path correctly rejected it. No real app was removed.

The root and metadata checks do not snapshot every descendant. Validation and mutation remain separate operations; running state and file contents can change between observations. Ownership evidence, complete descendant review, app-closure policy and atomic-boundary work remain release concerns.

`82bea00` adds a final fast snapshot check after durable journal intent and immediately before the mover. Rejection records a failed outcome without invoking the mover. This closes the avoidable gap created by journal I/O; it does not make the remaining check-to-move interval atomic.

## Restore and availability

`73aa86e` adds new records' source identity at cleanup intent and verifies the recorded Trash destination against that object. History can review and restore an identity-backed item into an existing folder on the same volume. The preview freezes source, destination and parent identities. Execution checks them again and uses descriptor-relative `renameatx_np(..., RENAME_EXCL)` so an existing destination is never overwritten. The local SDK's `rename(2)` manual confirms the exclusive flag fails on a collision; there is no overwrite or cross-volume copy fallback.

Restore intent is durable before rename. The moved object and destination parent are checked afterward; interrupted or uncertain outcomes stay pending without automatic retry or rollback. Old records without source identity remain manual Finder recovery. Changed/missing objects and destination conflicts have distinct explanations, and a conflict permits choosing another existing folder.

`1464de1` pages History in batches of 200 assessments using a coherent cached listing. Older records remain accessible without re-reading the full journal for every row. Manual refresh clears stale errors; a failed restore retains its result message after automatic refresh.

`ffff69e` distinguishes permission denial from malformed or linked paths. For a new record whose original identity was captured but whose Trash metadata was inaccessible at cleanup time, explicit review can verify the current object against the original device/inode/birth/type, size and modification time after access returns. The journal repeats that check under its lock and persists verified destination evidence before returning a frozen plan. A changed object or an old record with no source evidence cannot use this path. Controlled permission-denial/recovery tests pass; this does not substitute for the blocked real-system check.

## Evidence and actual-system limitation

- Bounded reader/startup focused verification: 17 tests passed. Independent code review found no actionable issue in that slice.
- App-removal focused verification: 50 discovered, 47 passed, three optional checks skipped, zero failures. Generated fixtures cover same-identifier replacement, support replacement, journal ordering, special files, internal framework links and preflight cancellation/timeout. The installed-app read-only check passed in 1.36 seconds.
- Restore fixtures cover exact-content recovery, collisions, alternate folders, missing/replaced objects, parent substitution, journal failure, pending state and old records. The History fixture window was visually inspected with available, conflict, missing and manual-recovery states.
- **The real Finder Trash round-trip has not passed.** The opt-in `MACSWEEP_RESTORE_FIXTURE=1` test attempted a round-trip with only a freshly generated UUID-named test file and failed during directory access. A separate read-only `open` of `~/.Trash` returned `EPERM` (1, Operation not permitted). This is an observed host access restriction, not a successful integration check. Raw output: ignored `build/diagnostics/2026-09-14-finder-restore.txt`.
- The actual-system test may leave its small `MacSweep-restore-fixture-*.txt` file in Trash because its identity-guarded cleanup cannot inspect the restricted directory. Existing user files were not modified or removed.

The app must distinguish access denial from an unsafe path and allow newly source-backed records to be reviewed after access becomes available; it must never invent an identity from a saved path. Full Disk Access is controlled by the user in Privacy & Security, not bypassed by MacSweep. [Apple's settings guide](https://support.apple.com/guide/mac-help/mchl211c911f/mac).

Remaining P1/R15 work includes a successful permission-enabled real-app recovery check, crash reconciliation beyond explicit pending states, distinguishing known no-move failures from uncertain post-move failures before allowing explicit retry, cross-volume capability coverage, retention/export, journal scaling and broader OS/volume validation. Full-suite requirements remain in the original roadmap.

## Final combined verification

On source revision `82bea00`, the controller ran:

```sh
MACSWEEP_REAL_APPS=1 MACSWEEP_VALIDATE_INSTALLED=1 MACSWEEP_CHECK_CHESS=1 swift test
./script/build_and_run.sh --verify
codesign --verify --deep --strict build/MacSweep.app
```

Result: **142 discovered, 139 passed, three optional checks skipped, zero failures**, 19.0 seconds. The skipped checks were real Quick Scan, OnVUE validation and the already-failed permission-gated Finder Trash round-trip; its earlier failure remains recorded above. Real installed-app inventory found 117 apps in 0.43 seconds with explicit partial coverage. The read-only installed app and Chess checks passed.

The release build finished in 41.7 seconds, the rebuilt app launched, and local ad-hoc signature verification passed. Raw ignored logs: `build/diagnostics/2026-09-14-removal-restore-tests.txt` and `build/diagnostics/2026-09-14-removal-restore-build.txt`. The inspected generated History-state image is preserved at `build/previews/2026-09-14-history-restore.png`.

This combination proves the tested increment and preserves the real-system failure as a release gate. It does not prove the full product has no remaining issues.

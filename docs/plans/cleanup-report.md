# Cleanup implementation report

Implemented task 1 of the MacSweep suite plan.

- Split CleanerScanner, AppScanner, ProtectionRules and CleanupSafety into Services.
- All cleanup and app-support candidates start unselected. Normalized paths and nested selections count once. Duplicate groups reserve their oldest copy deterministically, including when the same path appears in another category or inside a selected directory.
- AppModel cancels the actual detached worker and its publication task. Generation tokens reject stale results for cleaner, app inventory and app-support scans. Scan loops and chunked hashes check cancellation. A new scan clears lastScanDate; successful cleaner completion sets it.
- Trash paths are revalidated immediately before each move. Root/ancestor checks cover system locations and sensitive home libraries. Symbolic links, sensitive nested libraries, recent cleanup descendants, missing targets and unreadable descendants are rejected. Duplicate survivor and all duplicate members covered by the target must still match the scanned SHA-256, even when modification dates were preserved. Duplicate grouping uses logical file size; display totals remain allocated bytes.
- App uninstall confirms the app path and selected support-data total. It blocks running apps, MacSweep itself, Apple bundle IDs, unsupported app locations and changed/missing bundle identity. Support matching distinguishes exact identifier matches from advisory names; substring matching was removed.
- Recursive Trash validation, survivor hashing and Finder moves run in detached workers. Confirmations display a scrollable list of every target path; rejection and operation results are shown explicitly.
- Busy-state guards prevent selection mutations during scanning or cleaning. Existing model entry points remain available; uninstallSelectedApp and lastScanDate were added.

## Verification

Tests use generated temporary fixtures and an injected read-only scanner. No test invokes Finder Trash or cleanup against user files. Coverage includes protected roots/ancestors, overlapping totals, duplicate retention across categories and folders, symlinks, nested libraries, recent descendants, survivor mutation/removal, advisory matching, uninstall rejection, cancelled hashing, stale scan publication and default duplicate selection, changed targets with preserved timestamps, and sparse versus fully allocated byte-identical files. `swift test --filter CleanupSafetyTests` passed all 14 tests with zero failures on September 12, 2026 at 21:34:48 EDT. The root integration run covers the complete suite after these final changes.

Fixture failures exposed and fixed a FileHandle nil-at-EOF digest bug and Foundation path standardization differences for existing versus missing /private/var paths. Safety comparisons now normalize path components lexically; the trusted system temporary root uses POSIX realpath so /var alias handling does not weaken the no-symlink rule for selected targets.

## Practical limits

Finder Trash revalidation is best effort: another process can mutate a file between checking and the operating-system move. Cleanup scans and hashes are cooperative; individual blocking filesystem calls cannot be interrupted mid-call. Conservative validation can skip candidates shown in results, particularly cache directories containing recent files or links. App support ownership is advisory, including identifier matches. Uninstall supports direct children of /Applications and the current user's Applications directory; it does not remove privileged helpers, receipts or login items. No Finder Trash integration test was performed because verification must not mutate user data.

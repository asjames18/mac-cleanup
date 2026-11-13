# Storage explorer

Storage now offers Explore on each analyzed folder and Explore a Folder before any analysis. The sheet lists immediate contents, supports opening folders/back navigation, current-folder search, file-size ordering, Finder reveal and rendering the cached listing in pages of 200. It reads metadata only, performs no deletion, and never starts recursive folder measurement merely to navigate.

The reader pins a no-follow directory descriptor and uses directory-relative metadata reads. It lists symbolic links and special files without opening them; links cannot be navigated. File logical bytes and allocated blocks are shown separately. Folder totals are not inferred from directory metadata. Allocated blocks are not a promise of reclaimable APFS/cloud space. Excluded paths and their descendants are omitted while unexcluded sibling browsing remains available.

Reads are bounded by 20 seconds/25,000 entries and explicitly report partial coverage. A separate 25-second UI watchdog and cancellation keep a gate around an outstanding filesystem call and discard late completion. A pass that reaches the entry bound reports partial even if there might be no further entry. Complete tree measurement, treemap visualization, identity-aware cloud/APFS accounting, root-change detection and large-volume performance acceptance remain open.

Five targeted tests passed for shallow listing (including sparse files, links and a FIFO), exclusions, budget limits, navigation/back, timeout gating and native layout. An own-window fixture screenshot was inspected at `build/previews/storage-browser/storage-browser.png`; rows, controls, sizes and scope descriptions are readable. Tests use generated fixtures; no personal files were altered.

An additional regression verifies that changing exclusions clears both cached contents and an in-flight listing; the view observes those changes and cancels the old scope. Final full-suite verification passed 161 tests with six optional integration checks skipped (167 discovered), zero failures. The explorer is a storage-navigation milestone, not completed treemap, recursive measurement or full-suite acceptance.

Final release verification: `./script/build_and_run.sh --verify` rebuilt and reopened MacSweep. Strict deep codesign verification passed for the local ad-hoc bundle.

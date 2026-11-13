# On-demand explorer folder measurement

The storage explorer now offers Measure Folder for the current directory and Measure on child-folder rows. Results show logical file-content bytes and filesystem-reported allocated blocks separately. Directory overhead is not included, and shared APFS/cloud allocation is not interpreted as guaranteed reclaimable space. These are live metadata totals, not a filesystem snapshot.

The traversal uses the no-follow directory reader, counts hard-linked files once by device/inode within a measurement, stays on the starting device and enforces a shared 20-second/25,000-entry budget and 64-level depth bound. Links, special files, exclusions, unreadable directories, cross-device items and exhausted limits produce skipped/partial accounting. No file contents are read and no files are removed. Integer totals saturate and mark partial on overflow.

Listing and measurement share the explorer's cancellation/watchdog/outstanding-worker gate. Navigation and refresh clear cached measurements. Changing exclusions clears old totals and invalidates in-flight work. A new measurement clears its previous value before starting so failures cannot leave an old total presented as the fresh result.

Ten targeted storage tests passed with no skips or failures: hard-link counting, exclusions, links/FIFO handling, unreadable child folders, shared entry limits, publishing/invalidating totals and the existing explorer lifecycle/layout cases. The native fixture preview at `build/previews/storage-measurement/storage-browser.png` was inspected and shows the measured root total and controls. Cross-volume and depth-bound behavior are implemented but not separately exercised with real mounted-volume/deep-tree fixtures in this increment.

Remaining storage work includes large-tree benchmarks, stable identity through live directory replacement, treemap visualization, directory overhead/shared allocation accounting and richer persisted scan comparisons. This increment does not complete the whole storage milestone or the full product goal.

Release verification: `./script/build_and_run.sh --verify` rebuilt and reopened MacSweep; strict deep signature verification passed for the local ad-hoc bundle.

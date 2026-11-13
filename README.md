# MacSweep

A native macOS cleanup and monitoring suite built with SwiftUI. Targets macOS 13 or newer; runtime verification so far is limited to the local macOS 26.6 Intel Mac. No account, network service, or third-party dependency is needed.

## Use the app

Open `build/MacSweep.app`, or use Codex's **Run** action. The initial dashboard shows live CPU use, estimated memory use, kernel memory pressure, and available space on your home volume. The menu bar monitor shares the same readings.

- **Smart Scan:** Quick, Deep, Developer and Duplicates Only presets. Review old downloads, caches, logs, DerivedData, temporary files, large files and duplicate groups. Add custom folders from the toolbar. Filter by category, search, inspect file details, and reveal candidates in Finder.
- **Storage:** Analyze common folders and selected custom folders, with a size ranking and Finder shortcuts. Counts cover readable, non-protected content and may exclude packages and inaccessible files; this is not a complete accounting of the disk.
- **Applications:** Discover metadata from `/Applications`, `~/Applications`, and `/System/Applications`, including nested folders up to the disclosed depth limit. Results appear progressively; bundle sizes are labeled Not measured so discovery does not traverse every app. Search apps, find associated support files, and uninstall an app with explicitly selected support files. Running apps, Apple apps, MacSweep itself and symlinked app bundles are blocked. Name matches are suggestions, not proof of ownership; review shared data carefully. Managed app/group containers are shown as unavailable and cannot be selected; whole-container reset/removal is not supported.
- **Maintenance:** Inspect startup plist definitions from user LaunchAgents and local LaunchAgents/LaunchDaemons. Open Apple's Login Items, Storage, Software Update, Activity Monitor and Disk Utility tools. Definitions do not indicate current running/enabled state and are not an exhaustive login-item inventory.
- **History:** Review future Trash attempts, their stored destinations, failures and unresolved pending entries. Restore using Finder Trash; older operations are not backfilled.
- **Settings:** Show or hide the menu bar monitor. Readings refresh every three seconds while the app runs.

Quick Scan is separate from storage analysis. It publishes candidates and stage/path progress as work proceeds, with a cooperative budget of 20 seconds or 25,000 examined entries. Deep and other scans allow 300 seconds or 1,000,000 entries. A blocked filesystem call can delay these cooperative limits. An independent 25-second Quick Scan / 305-second file-scan watchdog ends the busy display, retains partial results and explains the pending access wait. Further scans wait until that operation returns. Respond to any macOS folder-access prompt, then retry. Application inventory has a 20-second/25,000-entry budget and independent 25-second timeout; related-file scans have a 305-second watchdog. Limits, cancellation and read errors are reported; incomplete cleanup folders are omitted and partially measured storage roots are labeled.

## Cleanup behavior

Scans never remove files. All candidates start unselected. Each cleanup has a confirmation, uses Finder Trash and reports skipped targets. You can restore items from Trash in Finder. System roots, sensitive user libraries, cloud-storage paths, symbolic links and recently modified cleanup files are protected. A directory containing protected/recent content can be shown for review but is rejected at cleanup time. Internal framework links that resolve inside a selected app bundle are permitted when moving that bundle as a unit; selected links and links outside the bundle remain blocked. Explicit app-support cleanup does not use the recent-file exclusion.

Nested selections are counted once. Duplicate groups are matched by logical size and SHA-256, and retain one copy across all categories. The retained copy is rechecked before moving duplicates. Cancellation stops cooperative scanner work and prevents old results from replacing a newer scan. Cleanup candidates now carry device/inode and timestamp snapshots; changed or unverifiable targets are refused at cleanup. This first foundation increment checks target metadata, not a complete directory-descendant snapshot. App uninstall/support paths still use their existing validators. Files can still change between a filesystem check and a Trash operation, so results should be reviewed.

macOS controls access to Documents, Desktop, Downloads and other protected locations. Denied or inaccessible locations can reduce scan coverage; use **Activity** to see scan details. No privileged helper, malware detection, forced process termination or automatic “optimization” is included.

Cleanup history is stored locally under `~/Library/Application Support/MacSweep/History`, with private permissions. An intent must be saved before a move; if that fails, the move is skipped. A pending record can mean the app stopped between moving the file and saving the outcome, so it is never automatically retried. History and folders containing it are protected from cleanup. This first journal supports 10,000 records; storage migration/archival and in-app restore remain development work.

## Build and run

```sh
./script/build_and_run.sh
```

This builds a release app, stages `build/MacSweep.app`, signs it locally with an ad-hoc signature, and opens it. Other modes: `--verify`, `--debug`, `--logs`, `--telemetry`. The existing `./scripts/build-app.sh` command builds the bundle without opening it. `CONFIGURATION=debug` can be used for faster iteration.

```sh
swift test
```

Tests exercise cleanup protection/selection, identity replacement, scan budgets, incremental results, permission errors, cancellation, native metric calculations, startup plist parsing, and layout of all main destinations. Cleanup tests use temporary fixtures and do not move user data to Trash.

To capture the test app's own windows while running the layout smoke test:

```sh
MACSWEEP_PREVIEW_DIR="$PWD/build/previews" swift test --filter InterfaceSmokeTests
```

That optional capture requires macOS screen-capture access for the test process; ordinary tests do not capture the screen.

Explicit read-only diagnostics:

```sh
MACSWEEP_REAL_SCAN=1 swift test --filter ScanResponsivenessTests/testRealQuickScanWhenExplicitlyRequested
open -n build/MacSweep.app --args --quick-scan
open -n build/MacSweep.app --args --scan-apps
```

The first prints local Quick Scan measurements without deleting files. The second opens the app and starts Quick Scan; all candidates remain unselected.

Development status: [full roadmap](docs/plans/2026-09-12-macsweep-full-development-plan.md), [capability matrix](docs/product/capability-matrix.md), and [scan recovery evidence](docs/implementation/2026-09-12-scan-recovery.md).

## Local build and distribution

This build is for local use. Sharing it broadly requires your Developer ID signing and Apple notarization. MacSweep uses its own name and interface; it does not include CleanMyMac's proprietary technology.

## Free download build (unnotarized)

`./scripts/build-app.sh` builds a universal (arm64 + x86_64), ad-hoc-signed `build/MacSweep.app`
(requires macOS 13 Ventura or later). `./scripts/package-release.sh build/MacSweep.app <version>`
then writes `build/release/MacSweep-<version>-macOS.zip` and `.dmg` (with an Applications shortcut)
and prints their SHA-256s.

Installing on macOS 15/26: move MacSweep to Applications and open it. When macOS says it can't
verify the app, click Done, open System Settings > Privacy & Security, scroll to Security, click
**Open Anyway** next to MacSweep and confirm with your password. Fallback in Terminal:
`xattr -dr com.apple.quarantine /Applications/MacSweep.app`.

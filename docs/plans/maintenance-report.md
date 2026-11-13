# Maintenance feature report

Implemented a standalone native SwiftUI `MaintenanceView` backed by `MaintenanceStore` and `StartupScanner`.

The feature reads plist definitions from `~/Library/LaunchAgents`, `/Library/LaunchAgents`, and `/Library/LaunchDaemons` on a cancellable background task. Cancellation is forwarded to the detached filesystem worker, and a scan generation token prevents cancelled or superseded scans from publishing stale results. Missing folders are valid empty locations. Partial directory-read and malformed-plist failures are returned alongside usable results and displayed as accessible warnings. The list supports search, identifies the definition source, displays label, program, launch-at-load, and keep-running details when present, and reveals the selected plist in Finder.

The interface explicitly describes this as a read-only inventory of launchd definitions rather than an exhaustive login-item list or a report of enabled/running state. Empty, loading, search-empty, and accessible error states are included.

Tool cards open native Login Items, Storage, Software Update, Activity Monitor, and Disk Utility destinations. Failures surface in an in-app alert. The feature does not execute maintenance shell commands or automatically open external apps during verification.

Files:

- `Sources/MacSweep/Services/StartupScanner.swift`
- `Sources/MacSweep/Stores/MaintenanceStore.swift`
- `Sources/MacSweep/Views/MaintenanceView.swift`
- `Tests/MacSweepTests/StartupScannerTests.swift`

Validation: `swift test --filter StartupScannerTests` passed all five fixture tests covering field parsing, valid missing folders, malformed plist warnings with partial results, unreadable locations with partial results, and cancellation. The command also completed the MacSweep debug build successfully. No external apps or settings panes were opened during verification.

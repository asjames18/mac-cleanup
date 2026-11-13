# MacSweep Suite Implementation Plan

**Goal:** Deliver a working native Mac maintenance suite by extending MacSweep.

**Architecture:** Shared app model and monitoring store drive native sidebar destinations and a menu bar panel. Background services own scanning and measurements; view files own presentation.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Foundation, Darwin; SwiftPM.

**Spec:** [MacSweep suite design](../specs/2026-09-12-macsweep-suite-design.md)

## Global Constraints

- macOS 13 or newer; Swift 6; no third-party dependencies.
- No automatic cleanup at launch or during verification.
- All candidates start unselected; use Trash with confirmation.
- No fake monitoring readings or malware protection claims.
- No edits to unrelated workspace projects.

### Task 1: Scan and cleanup correctness

Files: AppModel.swift, Models.swift, Services/CleanerScanner.swift, Services/AppScanner.swift, Services/ProtectionRules.swift, Services/CleanupSafety.swift, Tests/MacSweepTests/CleanupSafetyTests.swift, Package.swift.

Interface: retain existing AppModel methods; add `uninstallSelectedApp()` and `lastScanDate: Date?`. Maintain `MainViewMode` externally owned by UI work.

- [x] Split scanner services from the model.
- [x] Add fixtures for protected roots/ancestors, nested selections and duplicate groups; run `swift test`.
- [x] Implement cooperative cancellation and stale-result protection for all scans.
- [x] Make candidates unselected, count unique non-nested targets and retain a duplicate copy.
- [x] Add guarded app uninstall and revalidate Trash targets; test only temporary fixtures.

### Task 2: Native system monitor

Files: Stores/SystemMonitor.swift, Services/SystemMetrics.swift, Tests/MacSweepTests/SystemMetricsTests.swift.

Interface: `@MainActor final class SystemMonitor: ObservableObject`, `@Published var snapshot: SystemSnapshot`, `start()`, `refresh()`. Snapshot exposes optional `cpuUsage: Double?` (0...1), `memoryUsed: Int64?`, `memoryTotal: Int64`, `memoryPressure: String`, `diskFree: Int64?`, `diskTotal: Int64?`, `uptime: TimeInterval`, `updatedAt: Date?`. Monitor initializer starts a single cancellable update loop.

- [x] Implement real native measurements and safe delta math with fixture tests.
- [x] Handle unavailable samples, resets and first CPU sample without invented zeroes.
- [x] Sample off the main actor every three seconds and publish one shared snapshot.

### Task 3: Suite UI and maintenance

Files: ContentView.swift, Views/*.swift, Stores/MaintenanceStore.swift, Services/StartupScanner.swift, MacSweepApp.swift, Models.swift.

- [x] Replace crowded header with a native sidebar and feature-specific toolbar.
- [x] Extract existing cleanup/storage/app surfaces into focused files.
- [x] Build Overview from `AppModel` and `SystemMonitor`; show empty/busy/results states accurately.
- [x] Build Maintenance with launch-definition inventory and working native system-tool links.
- [x] Add app uninstall confirmation entry point, menu bar monitor and Settings.
- [x] Compile and resolve integration errors, verify accessibility labels and keyboard actions.

### Task 4: Package, review and launch

Files: scripts/build-app.sh, script/build_and_run.sh, README.md.

- [x] Package the app with bundle metadata and a local app icon; preserve existing build command.
- [x] Add Run action with build, launch and verify modes.
- [x] Run `swift test` and `./script/build_and_run.sh --verify`.
- [x] Review the completed implementation for concrete functional or data-loss bugs and resolve them.
- [x] Record delivered features, verification evidence and local distribution limits.

## Delivery verification

- `swift test`: 28 tests, zero failures on September 12, 2026.
- Review: both duplicate findings fixed and accepted in `review-report.md`.
- Native window previews captured from the test process and visually inspected; layout test covers every main destination.
- System Settings link identifiers checked against installed Apple extension bundle metadata.
- App bundle staged at `build/MacSweep.app`; Run action invokes the project build/launch script.
- No user files were moved to Trash during development or verification.
- Scope decisions: keep maintenance actions in Apple's own tools, retain conservative protected-path checks, and deliver an ad-hoc signed local build. Distribution signing/notarization and malware detection remain outside this build.

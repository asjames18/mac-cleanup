# MacSweep suite

Approved in conversation on September 12, 2026: expand the existing MacSweep into a native maintenance suite. Keep the MacSweep identity and the existing SwiftPM project.

## Experience

Native sidebar navigation: Overview, Smart Scan, Storage, Applications, and Maintenance. Overview shows real disk, CPU and memory readings, scan results, and feature entry points. Smart Scan retains Quick, Deep, Developer and Duplicates Only presets, category filtering, file detail, custom folders, and explicit selection. Storage displays measured folder usage. Applications supports moving an app and explicitly selected associated files to Trash. Maintenance lists launch-agent definitions with an honest distinction from running/login state and opens Apple's management tools. A menu bar panel shares live system readings and can reopen the main window. Settings controls menu bar visibility.

## Architecture

macOS 13 or newer; Swift 6; SwiftUI and AppKit; no third-party dependencies. App-wide AppModel owns scan state and selection; separate SystemMonitor owns live snapshots. Scan workers run off the main actor and cooperate with cancellation. Services handle measurement, launch-item inventory, and guarded Trash operations. Views are separated by feature. Existing user files outside MacSweep are untouched by implementation.

## Cleanup contract

No automatic cleanup at launch or during verification. All candidates start unselected. Destructive actions require a preview/confirmation in the app. Use Finder Trash only. Block protected roots and sensitive libraries including their ancestors; do not follow symlinks. Remove nested/duplicate selections before calculating totals or moving files. A duplicate group must retain a copy. Recheck file eligibility at action time. App support matching is advisory and must be selected explicitly; running apps cannot be uninstalled. Cancellation cannot publish stale scan results.

## Monitoring and maintenance

Read live host CPU ticks, virtual-memory statistics and volume capacity using native APIs. Missing readings are unavailable, never simulated. Avoid claims of performance improvement from deleting caches. Maintenance opens Login Items, Storage, Software Update, Activity Monitor and Disk Utility; inventory launch definitions read-only. Do not pretend to offer malware scanning or privileged optimization.

## Verification and delivery

Tests exercise nested selection, duplicate preservation, protected paths, cancellation and monitoring math with fixtures. Build a Finder-launchable local app, configure the Codex Run action, and verify process launch. Document that signing/notarization for distribution and a malware engine are outside this local build.

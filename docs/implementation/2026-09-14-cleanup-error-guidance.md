# Cleanup error guidance

Trash failures now retain their original localized message and add advice based on Cocoa/POSIX error domains and codes, including nested underlying errors. Permission errors for app bundles suggest checking App Management and Finder permissions. Other permission errors suggest Finder ownership/access and Files and Folders or Full Disk Access where applicable. These are possible checks, not a diagnosis of which macOS policy denied the operation. System and managed protections remain in place.

Read-only volume, insufficient-space and cancellation errors receive separate advice. A read-only or canceled operation does not recommend broad privacy grants. Unknown errors retain their original description. Classification never searches localized messages for keywords; nested-error inspection has a fixed depth limit. Guidance and the original top-level error domain/code are saved to the cleanup journal as well as the result dialog. Zero successful moves now show a warning titled “No items were moved to Trash.”

The [Apple Privacy & Security guide](https://support.apple.com/guide/mac-help/mchl211c911f/mac), inspected during the preceding access-check work, documents App Management as controlling app updates/deletion. This change does not grant that permission or establish that a specific refusal was caused by it.

Validation: four new formatter tests and six cleanup-journal integration tests passed, with zero skips/failures. They cover app/folder advice, underlying errors, read-only and space failures, cancellation, localized-text isolation, and durable failure guidance. Generated fixtures and injected failed movers were used; no personal files were deleted. Core move outcome semantics are unchanged by this messaging increment.

Release verification: `./script/build_and_run.sh --verify` built and reopened MacSweep; strict deep codesign verification passed for the local ad-hoc bundle. Remaining audit item: generic Trash movers that throw after a partial operation need uncertainty classification, just as restore already distinguishes known no-move failures from pending outcomes. Full suite acceptance remains open.

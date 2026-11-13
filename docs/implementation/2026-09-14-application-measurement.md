# On-demand application measurement

Applications previously showed “Not measured” after metadata-only inventory, with no direct sizing action. The detail panel now offers Measure App. This preserves fast discovery while letting the user measure the selected bundle separately. The app row and detail panel display recorded allocated bytes; details also show logical bytes, file count, skipped entries and partial coverage.

The operation uses the existing bounded storage measurer (20-second/25,000-entry budget, same-volume traversal, depth limit, no symlink following, hard-link deduplication within the measurement). Internal framework links can therefore produce partial totals. Shared blocks are not represented as guaranteed reclaimable space. Root scan evidence must match before and after measurement; a changed or unverifiable app requires another inventory scan. Descendant contents remain live metadata observations rather than a complete immutable bundle snapshot.

AppModel runs measurement in a detached task using its existing scan generation, cancellation and watchdog lifecycle. Only a current result for the selected app may publish. Cancellation/timeout preserves the filesystem worker gate until that worker actually returns. Measurement does not update removal identity evidence, grant permissions or invoke cleanup. Fresh measurement clears the previous size, and inventory refresh or exclusion changes clear cached measurements.

Generated fixture tests verify logical totals and partial reporting for a bundle containing a symbolic link, exclusion invalidation, changed-app rejection, cancellation and timeout gates, and rejection of late size results. The full suite passed: **193 discovered, 186 passed, seven optional checks skipped, zero failures**, 12.3 seconds. Logs: `build/diagnostics/app-measurement-tests.txt` and `build/diagnostics/app-measurement-full-tests.txt`. No personal application was deleted or modified. The optional real Finder Trash integration remains unverified.

This advances the application inventory experience but does not finish P4.1 or the full product: architecture/team identity, ownership evidence, supported updater catalogs, batch/reset workflows and broader real-app benchmarks remain open.

Release build/relaunch succeeded in 54.34 seconds through `./script/build_and_run.sh --verify`; strict deep signature verification passed. Build log: `build/diagnostics/app-measurement-build.txt`.

## Follow-up: scanned metadata validation

A generated fixture demonstrated that changing `Contents/Info.plist` can leave the app root snapshot unchanged. The previous root-only check accepted sizes even though the metadata evidence from inventory was stale. The new regression failed before the fix for both a preexisting metadata change and a change made during measurement.

Measurement now validates any recorded Info.plist snapshot before and after traversal, in addition to the required root snapshot. Either mismatch discards the size and requests another inventory scan. This does not turn metadata-only inventory into signature verification, and applications without recorded metadata evidence still have root-only measurement checks.

Final application measurement/inventory/scanner checks: 12 discovered, 11 passed, one optional real inventory check skipped, zero failures (`build/diagnostics/app-metadata-measurement-tests.txt`). All writes in the regression used generated temporary bundles. Full product and real-world app coverage remain incomplete.

Follow-up release rebuild and launch passed in 52.48 seconds, with strict deep signature verification passing (`build/diagnostics/app-metadata-measurement-build.txt`).

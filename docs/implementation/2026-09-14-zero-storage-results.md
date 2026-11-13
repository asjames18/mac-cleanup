# Preserve zero-byte storage results

Storage analysis previously discarded any root with zero measured allocated bytes. That hid successfully read empty folders and also hid partial roots when a budget expired before any file bytes were counted. Both appeared indistinguishable from an unscanned folder.

Analysis now retains roots when the traversal observed files/folders or recorded read errors, even if measured bytes are zero. Existing partial labeling and coverage reporting remain in force. The folder-usage UI calls the amount “readable” and renders a zero-width bar for zero bytes instead of the previous artificial six-pixel minimum. Bar scaling uses the actual maximum returned size rather than relying on array ordering.

Generated fixtures reproduced both missing-result cases before the change. Final ScanResponsivenessTests: 13 discovered, 12 passed, one optional real Quick Scan check skipped, zero failures (`build/diagnostics/storage-zero-tests.txt`). Existing checks for published folder totals and partial budget reporting also passed. Missing/protected roots are still excluded by the existing policy; this does not establish complete filesystem, APFS or cloud accounting. Interactive layout certification and the full storage roadmap remain open.

Release rebuild/relaunch passed in 52.20 seconds; strict deep signature verification passed (`build/diagnostics/storage-zero-build.txt`).

## Explain unavailable roots

Root analysis previously used fileExists to silently skip missing or inaccessible paths. It now separates policy exclusions from metadata read failures. Excluded paths are listed in Activity as excluded by policy; unsuccessful root metadata reads produce an unavailable-path message and contribute to the existing read-error count. Overall and storage-specific summaries label those failures as partial coverage. No zero-size measurement is invented for a root that could not be read.

A missing custom-root fixture reproduced the silent omission before the change. Final scan/exclusion checks: 17 discovered, 16 passed, one optional real Quick Scan check skipped, zero failures (`build/diagnostics/storage-unavailable-tests.txt`). This does not grant access or certify every macOS permission failure; absent standard roots now also count as incomplete requested coverage.

Unavailable-root follow-up release build/relaunch passed in 52.11 seconds with strict deep signature verification passing (`build/diagnostics/storage-unavailable-build.txt`).

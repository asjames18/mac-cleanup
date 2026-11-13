# Downloaded app cleanup correction

The user could not move Downloads/OnVUE.app and Downloads/OnVUE 2.app to Trash. Both were rejected as a protected location or symbolic link.

Read-only inspection confirmed the selected roots are real app directories. Both contain normal Electron framework aliases (Resources, Libraries, Helpers, Electron Framework and Versions/Current) whose resolved targets stay inside their respective bundles. The recursive cleanup validator rejected every symlink, including those internal aliases.

The correction permits internal links only while validating a selected app bundle with a readable, non-symlinked Info.plist and bundle identifier. Links are resolved with POSIX realpath for containment checking, never traversed or selected as deletion targets. Case-sensitive containment keeps sibling paths outside the allowed bundle. Selected symlink roots, outward links, dangling links, ordinary-folder links, protected/recent content, Apple apps, MacSweep and running apps remain rejected. Production cleanup callers pass current running-app and self locations into validation. Snapshot and duplicate revalidation remain in place.

Regression: the internal-framework fixture failed before the fix with the same protected rejection. The first implementation exposed Foundation's /private/var to /var alias normalization in temporary fixtures; POSIX realpath preserves the physical path used by the trusted fixture root. Both actual OnVUE bundles pass the final read-only validator with the default recent-file protection enabled. No user files were moved or deleted during verification.

Verification command: `MACSWEEP_VALIDATE_ONVUE=1 swift test`. Fixtures cover internal, external, dangling and selected-root links, ordinary-folder behavior, and running/self protection. The optional current-machine scan benchmark is outside this change and remains skipped.

Final result: 56 tests passed, zero failures, one unrelated opt-in scan benchmark skipped. The actual OnVUE validation test passed for both apps. Release build and launch verification succeeded; ad-hoc signature verification passed. The app was reopened for the user to rescan and retry the reviewed Trash operation.

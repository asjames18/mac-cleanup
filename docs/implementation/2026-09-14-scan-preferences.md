# Persisted scan preferences

MacSweep now injects a UserDefaults-backed scan preference store at the app entry point. Added folder paths and the selected preset survive model recreation and normal subsequent launches. Adding folders normalizes and deduplicates paths; removing a folder persists the new list. Settings describes the behavior.

Stored paths do not grant access, resolve bookmarks, follow moved folders, or bypass cleanup validation. No filesystem probing occurs during preference loading. Missing folders remain saved so temporarily unavailable volumes are not silently forgotten. Unknown presets fall back to Quick Scan; malformed folder values, relative paths, NUL paths and non-file URLs are ignored. Test-created models remain isolated unless explicitly given a preference store. The explicit `--quick-scan` launch action selects Quick Scan even when another preset was saved.

Validation: `swift test` discovered 144 tests, with 138 passed, six optional integration tests skipped, and zero failures. Two new tests cover persistence through model recreation, removal, duplicate normalization, malformed preferences, remote URLs and busy-state rejection. Tests use disposable UserDefaults suites and do not alter personal scan settings. The initial test build was interrupted by an overlapping source edit; the subsequent full build and test run completed successfully.

This is a foundation increment, not completion of the suite or the permissions/settings milestone. Persistent exclusions with action-time enforcement, permission onboarding, stable signing, moved-folder bookmarks and larger-scale acceptance testing remain open. Real Finder Trash restore remains subject to the previously recorded host access limitation.

Release verification: `./script/build_and_run.sh --verify` completed the production build and reopened MacSweep successfully. `codesign --verify --deep --strict build/MacSweep.app` passed for the local ad-hoc bundle; this is not Developer ID/notarization evidence.

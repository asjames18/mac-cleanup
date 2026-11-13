# Duplicate scan coverage reporting

Duplicate scanning only considers eligible regular files of at least 1,000,000 logical bytes and hashes files that share a logical size. Its previous “finished” message omitted that scope and did not distinguish hash read failures from complete comparisons.

The duplicate completion message now reports matching files, successful hashes, incomplete hash attempts, read errors and roots unavailable or excluded. It marks coverage partial after a limit, read failure, incomplete hash or unavailable root. Read errors also make the overall ScanSession summary explicitly partial. The duplicate category/preset screen explains the 1 MB minimum and existing hidden/package/protected exclusions, with Activity providing the detailed counts. This does not expand scan coverage or change which files are eligible for cleanup.

The new regression first reproduced the missing minimum-size/hash counts and overall partial-coverage label. All fifteen cleanup safety tests then passed. The full suite passed with 195 discovered, 188 passed, seven optional checks skipped and zero failures (15.0 seconds), `build/diagnostics/duplicate-coverage-full-tests.txt`. The optional real Finder Trash check remains unverified. Full duplicate scanning, hash caching and large-volume acceptance remain open.

Release build/relaunch passed in 50.71 seconds and strict deep signature verification passed (`build/diagnostics/duplicate-coverage-build.txt`).

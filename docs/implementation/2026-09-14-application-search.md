# Application search and refresh

The Applications screen now keeps an accessible Refresh Applications control next to search after inventory results appear. It invokes the existing scan action and remains disabled during active or waiting filesystem work.

Search matches app names, bundle identifiers and paths, ignoring case and surrounding whitespace. The header shows matching/total counts. A no-match state offers Clear Search rather than a blank panel. If the currently selected app is filtered out, its details remain visible with an explicit notice and Clear Search action, so filtering does not silently discard a related-file review.

This is a view-only change. Validation consists of reviewing the view branches, SwiftUI release compilation and app launch; no new tests were added for this reversible presentation change. Interactive accessibility and unusually large application-list profiling remain open. This increment does not complete the full application-management or product roadmap.

Release build and launch passed in 53.69 seconds with `./script/build_and_run.sh --verify`; strict deep signature verification passed. Log: `build/diagnostics/app-search-build.txt`.

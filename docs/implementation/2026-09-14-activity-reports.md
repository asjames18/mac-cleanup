# Activity diagnostic snapshots

Activity now offers Copy Report and Save Report alongside the existing selectable log. Reports contain capture time, app version/build, macOS version, current view, currently selected preset, AppModel status, filesystem waiting state, progress, coverage summary and current activity text. The report labels the preset as currently selected rather than asserting it was used for the preceding scan.

Saving captures immutable text before presenting NSSavePanel, then writes UTF-8 plain text atomically in a detached task to the user-selected destination. The UI shows saving, success or failure feedback. Copy uses the system clipboard only when the user clicks Copy Report. Reports include paths, explicitly stated in Activity. Nothing is uploaded or sent automatically.

The report is a snapshot of AppModel's current in-memory scan/cleanup activity, not a persistent log archive or a complete record of independent Maintenance/History operations. This does not complete the planned telemetry/support infrastructure. Validation for this reversible UI feature consists of source review and release compilation/launch; clipboard/save-panel interaction and slow-volume integration are not certified by automated tests in this increment.

Release build/relaunch passed in 62.23 seconds and strict deep signature verification passed (`build/diagnostics/activity-report-build.txt`).

## Bounded on-screen preview

Activity no longer lays out the complete diagnostic string. AppModel prepares a tail preview whenever logText changes, retaining at most 16,384 Unicode scalars. Preparation examines only the bounded tail rather than counting the entire report. Scalar boundaries avoid splitting UTF-8 code units; a truncated preview can begin within a grapheme cluster. The pane clearly says when only the end is shown. Copy and Save continue to use unmodified logText.

Tests cover empty/short/boundary text, a generated long report containing Unicode paths, full export-source preservation and reset to a new short log. Both targeted tests passed. Full suite: 197 discovered, 190 passed, seven optional checks skipped, zero failures, 13.4 seconds (`build/diagnostics/activity-preview-full-tests.txt`). This bounds preview work; it is not a measured frame-time guarantee, a limit on full log memory, or complete clipboard/save integration certification.

Preview follow-up release rebuild/relaunch passed in 55.59 seconds; strict deep signature verification passed (`build/diagnostics/activity-preview-build.txt`).

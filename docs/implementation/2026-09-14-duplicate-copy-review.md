# Duplicate-copy review panel

The focused duplicate's detail panel previously showed only a shortened hash-group identifier. It now lists the scanned matching copies, including copies outside the current category/search, with full-path tooltips, selectable path text, Finder reveal and selection status. The group summary counts copies kept and selected. Groups initially render twenty entries and offer Show More Copies; switching groups resets that count.

The required retained copy is identified using the existing CleanupSafety retention rule and its selection control is disabled. Other entries reuse AppModel.toggleItem, including the existing busy/waiting guard and retention enforcement. Keeping an additional copy simply deselects it. This UI does not change keeper policy, automatically select duplicate files, bypass cross-category ancestor protection or replace pre-removal hash/identity checks. Choosing a different mandatory keeper is not implemented by this increment.

Validation: all fourteen CleanupSafetyTests passed with no failures, including retained-copy ancestor/category protection, changed retained/selected duplicate evidence, sparse/allocated duplicate fixtures and initial unselected state. Log: `build/diagnostics/duplicate-review-tests.txt`. The final presentation change is release-compiled; interactive layout/accessibility review remains open. These checks do not certify real Finder Trash behavior or the full P3 duplicate roadmap.

Release rebuild/relaunch passed in 49.52 seconds and strict deep signature verification passed (`build/diagnostics/duplicate-review-build.txt`).

## Main-list selection feedback

The main cleanup list now applies the existing retained-copy ancestor rule to checkbox availability and displays “Protected: retains a duplicate copy.” This includes the mandatory duplicate itself, aliases represented in other categories and candidate folders containing that retained path. Finder/detail access remains available. The UI no longer invites a selection that the model immediately rejects.

Select Category, Clear and Move to Trash also disable while waiting for a canceled/timed-out filesystem worker, matching their existing action guards. This follow-up changes presentation only; the backend retention and cleanup validators are unchanged. Validation is release compilation/launch and review of those guard conditions; no additional tests were added for the presentation change. Full duplicate/cleanup acceptance and interactive accessibility validation remain open.

Main-list follow-up release build/relaunch passed in 50.60 seconds, with strict deep signature verification passing (`build/diagnostics/retained-copy-feedback-build.txt`).

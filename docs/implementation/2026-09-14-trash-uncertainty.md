# Uncertain Trash outcomes

A generic Trash mover may throw after a partial or completed filesystem operation. MacSweep now distinguishes read-only preflight failures from exceptions after the mover starts. Preflight rejection records a failed operation; any mover exception retains pending intent and adds its diagnostic without claiming the source is unchanged. The UI reports an unknown outcome, provides Finder inspection guidance, and labels zero confirmed moves without claiming no movement occurred. History includes Reveal Original Location even when no Trash destination was returned.

New cleanup intent is blocked when its target overlaps the original, Trash or restore location of an existing pending cleanup or pending restore. This check runs under the journal's process/cross-process lock. Unrelated paths remain usable. Comparisons normalize lexical components and conservatively fold case without asking Foundation to standardize against the live filesystem: a regression found that Foundation rewrote an existing /private/var ancestor to /var while keeping a missing source under /private/var, defeating an ancestor comparison.

Tests exercise an injected mover that moves only a generated fixture and then throws. The source disappears, the fixture contents survive at the simulated Trash destination, the reloaded journal remains pending with its error, overlapping retries reject, and an unrelated intent succeeds. An injected error with the source still present also remains pending: existence alone cannot prove no partial changes occurred. Existing preflight-failure tests remain definite failures.

Validation: the full suite passed 155 tests with six optional integration checks skipped (161 discovered), zero failures after fixing the lexical comparison. An additional assertion checks cleanup rejection around a pending restore. Real Finder Trash integration remains unverified under the previously recorded host access restriction.

This change intentionally does not auto-reconcile or erase old pending operations. A reviewed reconciliation workflow, broader identity/alias coverage, richer recovery UX, release permissions and the remaining full-suite roadmap are still open. Filesystem alias paths are not universally equivalent to lexical paths; cleanup's existing link protections remain necessary.

Final verification: the pending-restore overlap regression passed. `./script/build_and_run.sh --verify` rebuilt and reopened MacSweep; strict deep signature verification passed for the local ad-hoc bundle.

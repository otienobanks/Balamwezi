# FLASH EA — INTEGRATED DEVELOPMENT BUILD FREEZE MANIFEST

**Build:** FlashEA_P3_REC02
**Build ID:** P3-REC02-SAFETYREV-20260922-01 (Safety Revision)
**Freeze date:** 2026-09-22
**EX5 SHA-256:** 30749b80a2ebf03534a478acaa3d03f98a4d1eb7ad54aeffe3a2729add756561

## Freeze declaration (verbatim, as authorized)

FLASH EA — INTEGRATED DEVELOPMENT BUILD FROZEN. The current source and EX5 are preserved unchanged. Compilation, 182/182 self-tests, two 16-day backtests, and the observed trailing-request correction are accepted as evidence for the specific behaviors they exercised. Final unattended-trading acceptance remains pending targeted recovery fault injection, a broker-request-path audit, and completion of the affected lifecycle regression. No new strategy features or general development work are authorized.

## What this freeze is, and is not

This is the completed development baseline for the three-defect safety revision (recovery deadlock, trailing-request spam, continuous operation). It is explicitly not a declaration that FlashEA_P3_REC02 is fully verified for unattended real-money trading. Three items remain open before that further acceptance step can be considered, listed below under "Not yet verified."

## Archive contents

- source/ — full mirrored source tree (Core, Entry, Execution, Market, Reconciliation, Recovery, Reversal, Risk, Trailing folders, plus the main FlashEA_P3_REC02.mq5), copied from the live project folder at freeze time.
- FlashEA_P3_REC02.ex5 — the compiled binary at freeze time.
- source_hashes.txt — SHA-256 of the ex5 and every source file in the archive.
- evidence/ — reserved for supporting evidence records (log excerpts, self-test output) to be added as referenced below.

## Integrity verification performed at freeze time

- diff -rq between the live project source tree and the terminal (compile-target) source tree: clean, no differences.
- diff -rq between the newly archived source/ and the live project source tree (excluding the ex5): clean, no differences.
- SHA-256 of the ex5 confirmed identical across three copies at freeze time: the archived copy, the live project copy, and the live terminal copy. All three: 30749b80a2ebf03534a478acaa3d03f98a4d1eb7ad54aeffe3a2729add756561.

## Evidence accepted for this freeze

1. Compilation — final compile of build P3-REC02-SAFETYREV-20260922-01: 0 errors, 0 warnings, 6068 ms, producing ex5 hash 30749b80a2ebf03534a478acaa3d03f98a4d1eb7ad54aeffe3a2729add756561.
2. Self-tests — 182/182 passing (up from 160 pre-revision), including 11 new tests covering every branch of ClassifyLivenessCause and 11 new tests covering every ENUM_FLASH_RECON_STATUS to ENUM_FLASH_RECOVERY_ROUTE mapping in ClassifyRecoveryRepairRoute.
3. Trailing-request correction (Defect 2) — confirmed across two independent 16-day backtests: rejected trailing SL modification requests fell from a baseline of 4,638 to 6, with the final account balance identical across both reruns ($104,395.45), confirming zero change to strategy behavior.
4. Continuity and liveness visibility (Defect 3) — the liveness watchdog ran cleanly across both 16-day reruns, 2,024 combined watchdog ticks, zero unexplained (UNKNOWN_DEADLOCK) classifications.
5. Incidental fix — a market-wait gate clear-on-success bug in CFlashTrailing::UpdateSetup was found from the first rerun's log evidence (MKTWAIT ENTERED=2 vs CLEARED=1 asymmetry) and corrected; the fix is included in this frozen build and re-verified clean in the second rerun.

## Not yet verified (explicitly outstanding, per the authorizing instruction)

1. Recovery-repair engine (Defect 1) — not yet executed end-to-end against a real induced fault. TryReconcileFromRecovery() and its dispatch routes compile clean and are fully covered by pure unit self-tests (11/11 ENUM_FLASH_RECON_STATUS routing mappings pass), but no partial-placement failure occurred naturally in either 16-day backtest window (0 such events in both runs), so the actual repair/exit and resume-to-scanning behavior has never been observed running against a genuine fault. This is the item the user has explicitly stated must not be waived.
2. Broker-request call-site audit table — not yet produced as a formal table (retry budget, waiting behavior, persistent intent, and confirmation method per broker-writing call site).
3. Full lifecycle regression, scoped to what remains unverified — not yet mapped; which state transitions the two completed 16-day backtests already exercise versus which remain unverified (principally the recovery-repair paths) has not yet been documented.

## Next steps authorized

Build a safe, isolated demo fault-injection fixture reproducing the failed second-leg placement plus failed unwind sequence, confirm the resulting broker inventory, demonstrate that Flash actually protects or exits the resulting position and returns to scanning once clean, and include a restart during that recovery window. If this passes, together with a clean call-site audit and satisfied remaining acceptance criteria, the exact tested build may then be frozen as the final release candidate. If testing uncovers a defect, this baseline is preserved and one separately identified correction is made, following the same archive-before-edit discipline used for this freeze.

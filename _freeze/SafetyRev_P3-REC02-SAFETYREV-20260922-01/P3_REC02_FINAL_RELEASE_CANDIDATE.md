# FLASH EA — FINAL RELEASE-CANDIDATE ACCEPTANCE RECORD

**Build:** FlashEA_P3_REC02
**Build ID:** P3-REC02-SAFETYREV-20260922-01
**EX5 SHA-256:** 30749b80a2ebf03534a478acaa3d03f98a4d1eb7ad54aeffe3a2729add756561
**Status:** FINAL RELEASE CANDIDATE - ACCEPTED AND FROZEN
**Acceptance date:** 2026-09-22

This record supersedes the earlier "Integrated Development Build" freeze status (see P3_REC02_FREEZE_MANIFEST.md in this same archive) for the identical, unmodified source and EX5. No code changed between the development-build freeze and this final acceptance - only external fixture testing was performed. Both manifests describe the same artifact at two acceptance milestones.

## Approval (verbatim)

APPROVED - FINAL RELEASE-CANDIDATE FREEZE

Accept P3-REC02-SAFETYREV-20260922-01 as the final Flash EA release candidate, subject to the evidence and limitations recorded in the report.

File the final freeze record against the exact EX5 SHA-256: 30749b80a2ebf03534a478acaa3d03f98a4d1eb7ad54aeffe3a2729add756561

Record the 182/182 self-tests, two 16-day backtests, trailing-request correction, 20-site broker-request audit, and repeated recovery fault-injection results. Preserve the Journal evidence showing actual broker-confirmed repair, return to scanning, subsequent setup activity, and recovery across restarts.

Identify the remaining unexercised transition variants as coverage limitations, not as completed tests. Preserve the exact source, EX5, hashes, acceptance matrix, and rollback archive. Do not make further code changes under this freeze.

Final status: FINAL RELEASE CANDIDATE - ACCEPTED AND FROZEN.

This approval does not authorize unattended live-money trading. Keep the build frozen and await a separate controlled-deployment authorization.

## Acceptance matrix (evidence accepted for this status)

1. Compilation - 0 errors, 0 warnings, 6068 ms, ex5 hash 30749b80a2ebf03534a478acaa3d03f98a4d1eb7ad54aeffe3a2729add756561.
2. Self-tests - 182/182 passing, including full branch coverage of ClassifyLivenessCause and ClassifyRecoveryRepairRoute.
3. Two independent 16-day backtests - identical final balance ($104,395.45) both runs, confirming determinism.
4. Trailing-request correction (Defect 2) - rejected SL modification requests reduced from a baseline of 4,638 to 6, across both reruns, zero change to strategy behavior.
5. Continuity/liveness watchdog (Defect 3) - clean across 2,024 combined watchdog ticks, zero unexplained deadlock classifications.
6. Broker-request call-site audit - 20 call sites reviewed (placement, cancellation, SL modification, price modification, market close); every site is either bounded by an explicit retry budget or naturally limited to one attempt per tick with no automatic resubmission of an unchanged request; no additional defect found.
7. Recovery fault-injection fixture (Defect 1 - the specific evidence required, not waived) - reproduced with real Journal log evidence, twice plus a restart-interrupted run:
   - Fault correctly identified at startup (ACTIVE_UNPROTECTED / UNPROTECTED_EXPOSURE classification against real broker state).
   - Repair actually executed: risk-reducing market close, broker-confirmed verified flat (not merely classified).
   - State returned to WAITING_FOR_ENTRY and resumed genuine live scanning - confirmed by Flash going on to arm, fill, and manage a real subsequent setup on the same attach.
   - Survived a restart mid-recovery: parked in RECOVERY_REQUIRED across two offline detach/reattach cycles with no corruption or duplication of classification, then completed the identical repair once ticks resumed.
   - Journal timestamps on file in FlashEA.md (runs at 20:32, 20:33, and the restart-spanning run 20:45-20:47 on 2026-09-22).
8. Lifecycle transition map - 15 of 27 legal state transitions backtest-verified with real counts prior to the fixture; the fixture directly closes the previously-unverified recovery-repair group (entry into and exit from RECOVERY_REQUIRED, real risk-reducing exit and resume-to-scanning).

## Coverage limitations (explicitly not waived, recorded as open, not as completed tests)

- 12 of 27 legal state transitions remain not backtest-verified in total; the fixture closes the recovery-repair subset specifically, but the following market-wait resolution variants remain unexercised: REVERSAL_RECONCILING <-> WAITING_FOR_MARKET, three of four WAITING_FOR_MARKET exit variants (resume outstanding reversal close, reconcile fully flat, reconcile with new leg standing), and the PLACING_ORDERS unwind-success-after-partial-failure edge. These reuse already-proven primitives (CancelGroup, ClosePositionMarketEx) but have not themselves been directly observed.
- RepairOrphanedOrderFromRecovery's live reachability in this build remains narrower than RepairOrExitUnprotectedFromRecovery's - proven via 11/11 self-tested routing and shared primitives already verified elsewhere live, but not itself exercised by a live fixture run, because the older startup classifier intercepts and resolves the incomplete-pending-order case before the new engine can act on it in most real scenarios.
- Two 16-day backtests establish behavioral consistency and determinism only. They do not establish, and are not represented as establishing, future profitability.
- This acceptance is a release-candidate freeze, not unattended live-money trading authorization. A separate, explicit controlled-deployment decision is required before real-money use.

## Standing instruction under this freeze

No further code changes are authorized against this build. Any future correction must be made against this preserved baseline as one separately identified, archived-first change, per the discipline already established this project. Further work beyond this point is scoped as a controlled deployment and observation exercise, not further open-ended development.

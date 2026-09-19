# Test 6 Handoff — Same-Tick Reversal Race

Status: DEFERRED — MARKET CLOSED — MANDATORY BEFORE LIVE-TRADING RELEASE.

## What this test verifies

The reversal-detection reordering fix in `ManageActiveSetup()` (`source/FlashEA.mq5`): the check for "has the armed reversal order executed" was moved to the top of the function, ahead of the old-position early-return, because live evidence on 2026-09-17 (22:03:20) showed a same-tick SL hit and reversal fill being swallowed by the old branch, leaving a real position briefly untracked and unprotected. This has never been exercised live since the fix was compiled. It remains the single outstanding critical safety item blocking release.

## Fixture

`test-archive/FlashReversalRaceFixture.mq5` / `.ex5`, compiled clean (0 errors, 0 warnings, 1114 ms) under this same frozen build's source tree. Archived copies only — see cleanup note at the end of this document for what happens to the live-folder copies after testing.

Input: `TargetMagic` (default 260917) — the magic of the Flash instance to force the race on.

What it does, in one synchronous script run: finds the open position and the armed pending reversal order under that magic on the current chart's symbol, force-closes the position at market (simulating the SL hit), then cancels the pending order and immediately places an equivalent market fill in the same direction and volume. Both steps complete before Flash's own next `OnTick`, so `ManageActiveSetup()` sees the old position gone and the reversal ticket gone at the same time — the input state the reordering fix targets.

## Honest limitation — read before running

**The fixture as currently written always executes the position close before the pending-order cancel-and-refill, in that fixed order, within the script itself.** This means the broker-side transaction sequence it produces is deterministic and always the same shape: the position-close transaction is submitted and completes first, then the pending-order removal and new-deal transactions follow. This reliably exercises **Sequence A** (old position closes before the reversal fill is processed) at the level of state the code reacts to. It does **not**, as currently designed, independently exercise **Sequence B** (reversal fill processed before the old position's closure is processed) as its own distinct broker-observable ordering — the script never submits the reversal fill ahead of the close. If only Sequence A is demonstrated using this fixture, that limitation must be reported explicitly in the pass/fail write-up. The fixture reproducing the same end-state (both gone before Flash's next tick) is not itself proof that both live broker transaction orderings were tested — the simulated event ordering inside the script is not proof of both live broker outcomes.

To genuinely attempt Sequence B, the fixture would need to be modified (or a second fixture built) to submit the reversal fill request before the close request, and even then MT5/the broker's own internal transaction sequencing is not fully controllable from script code — this is a known constraint of testing broker-side event ordering from a client script, not a gap that can be fully closed without broker-side tooling this project does not have. Whoever runs Test 6 should decide, before running it, whether to accept Sequence-A-only coverage with this limitation disclosed, or to first modify the fixture to attempt a Sequence-B ordering and disclose whatever the actual result shows.

## Prerequisites — verify before running

1. Confirm the frozen build is what is actually attached: check the Journal for `build=P2-SAFETYFIX-20260918-02` at the most recent `OnInit` on the target chart.
2. Confirm account: demo only (the fixture itself refuses to run on anything else).
3. Confirm symbol: XAUUSD, matching the chart the script will be run on.
4. Confirm magic: the chart's `Flash Trade Identification Number` input matches the fixture's `TargetMagic` input exactly.
5. Confirm state: the chart must show `POSITION_ACTIVE` with a genuinely armed reversal — wait for the Journal line `[FLASH][REVERSAL] Reversal order armed` before running. If the target has already resolved naturally (Flash's own reversal fired on its own) before the fixture is run, the fixture aborts safely on its own (no open position or no pending order found under that magic) rather than acting on unrelated exposure — this has already been observed multiple times this session and is expected, correct behavior, not a fixture defect.

## Execution procedure

1. Attach Flash to a chart with the frozen `.ex5`, confirm the build ID in the Journal.
2. Wait for a setup to reach `POSITION_ACTIVE` with trailing activated and a reversal armed (Journal: `Reversal order armed`).
3. Drag `FlashReversalRaceFixture.ex5` onto the same chart from Navigator > Scripts, set `TargetMagic` to match, run once.
4. Read the script's own Journal output (`[RACEFIXTURE]` lines) to confirm it found and acted on the position and pending order, or aborted safely with a stated reason.
5. Immediately re-access the Journal (per standing project practice) for Flash's own `[FLASH][REVERSAL]` reconciliation lines following the forced state.

## Acceptance criteria — all required for PASS

- The reversal fill is detected and attributed correctly (Flash transitions into `REVERSAL_RECONCILING` and logs the detection, not a "setup fully closed, no reversal pending" line).
- The resulting position has a valid, non-zero protective SL, or is otherwise safely resolved (no unprotected exposure left standing).
- No duplicate position and no unintended additional exposure exists afterward.
- No orphaned reversal order remains (the original pending ticket is fully resolved, not left dangling).
- Flash's internal state (as logged) matches the actual broker state (Trade tab position count, volume, SL) at the end of the sequence.

Capture and record for the ledger: both order tickets involved, the resulting position ticket, exact timestamps, the SL value assigned to the new leg, and a final inventory check against the Trade tab.

## If Test 6 passes

Update `EVIDENCE_LEDGER.md` with the result (including which sequence(s) were actually demonstrated and the Sequence-B limitation disclosure if applicable), then proceed to the post-pass release review and the 7-item cleanup checklist recorded in the project tracker and repeated below.

## If Test 6 fails

Keep the release gate closed. Any corrective change produces a new build with a new build ID and a new archive; this frozen archive (`Phase2_P2-SAFETYFIX-20260918-02`) is not modified. Affected regression tests (1 through 5, 7) are rerun against the corrected build before it can be considered for release.

## If Test 6 cannot be completed

Leave it UNVERIFIED. The release gate stays closed. No further release-track work proceeds until it either passes or the outstanding limitation is explicitly accepted in writing by OtienoBanks as a documented, knowing exception — which this handoff does not do on its own.

## Post-pass cleanup checklist (only after Test 6 passes, not before)

1. Remove `FlashRecoveryFixture.mq5`/`.ex5` and `FlashReversalRaceFixture.mq5`/`.ex5` from the live `MQL5/Scripts/` folder in the terminal data folder (both files, that folder only) — archived copies here are retained regardless.
2. Restore `Flash Trade Identification Number` to 260917 on every chart currently running a test magic (999001/999002/999003 observed this session).
3. Detach any leftover test-magic charts.
4. Inspect the Trade tab for any stray test-magic pending orders or positions before calling the account clean.
5. Verify sole ownership of the production magic 260917 (single Journal owner claim, no conflict lines).
6. Confirm the exact deployed `.ex5` and its `FLASH_BUILD_ID` match what is intended for release.
7. Confirm every remaining position is protected (non-zero SL) and every remaining pending order is intentional. **Do not indiscriminately close positions or delete orders during cleanup — identify each item and verify its ownership (magic number, and whether it is a known test fixture or real exposure) before touching it.**

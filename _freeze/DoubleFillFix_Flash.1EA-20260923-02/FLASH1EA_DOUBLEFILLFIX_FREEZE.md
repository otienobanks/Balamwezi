# FLASH.1EA — DOUBLE-FILL RECOVERY CORRECTION — FROZEN RELEASE CANDIDATE

**Build:** Flash.1EA
**Build ID:** FLASH1EA-DOUBLEFILLFIX-20260923-02 (Clean release candidate)
**Freeze date:** 2026-09-23
**EX5 SHA-256:** d65b0889b22a708b8d9e5981cb025a7ec109f740d361556f061c51b35d235409

**Previous accepted build ID:** FLASH1EA-NAMEONLY-20260922-01
**Previous accepted EX5 SHA-256:** a55024fae0cb2bc270b08b9f1f6ed43b659e15210d6a554220128f57808ab0da

## Freeze declaration

FLASH.1EA — DOUBLE-FILL RECOVERY CORRECTION, VERIFIED, FROZEN RELEASE CANDIDATE. This build adds one narrowly-scoped automated repair path for a CONFIRMED initial-bracket double-fill, plus a truncation-tolerance fix to that same correction's setup-id comparison discovered during its own verification. No other trading logic changed from the previous accepted build (FLASH1EA-NAMEONLY-20260922-01, itself logic-identical to FlashEA_P3_REC02).

## What this correction addresses

Confirmed live 2026-09-23 01:37:20 (tickets 58580621119/58580621140, 47ms apart): both legs of an initial BUY_STOP/SELL_STOP bracket filled in a near-simultaneous race before cancellation of the opposite leg completed, leaving two Flash-owned opposite-direction positions under one setup. The existing reconciliation engine correctly classified this as EXPOSURE_DISCREPANCY but had no reachable repair route, leaving Flash in RECOVERY_REQUIRED indefinitely.

Detection (`ClassifyConfirmedDoubleFill` / `GatherDoubleFillEvidence`) requires, all nine: exactly two Flash-owned positions, no leftover pending order, opposite directions, both carrying the identical `FLASH|<setupId>` placement tag (never `FLASHREV|`, so a reversal-produced pair is never matched), matching volume, opened within 15 seconds of each other, and no reversal recorded for the setup. Any other EXPOSURE_DISCREPANCY cause is unaffected and still resolves exactly as before.

Repair (`RepairConfirmedDoubleFillFromRecovery`) never adopts either leg as a directional trade; it closes both as a risk-reducing unwind, one at a time, reusing the existing bounded retry budget, close-intent tracking, and market-closed no-spam gate unchanged, then returns to `WAITING_FOR_ENTRY` only once reconciliation independently confirms `NO_EXPOSURE`. A persisted, restart-safe unwind-active flag (`EnforceDoubleFillUnwindOverride`, called after `HandleStartupRecovery` at both its existing call sites) keeps the unwind from being interrupted by a partial resolution or a restart mid-unwind.

Truncation fix (found during verification, not part of the original authorization, but a genuine defect that would have silently blocked this correction, including on the original live incident): MT5 truncates a market-execution position's comment (observed: 31 characters), so `SetupIdConsistentWithInternalRecord` inside `GatherDoubleFillEvidence` now also accepts a truncated setup tag that is an exact prefix of the untruncated internal record, in addition to exact equality. Touches only that one comparison.

## Source-difference report

`diff -rq` of the entire archived source tree against the frozen `NameOnly_Flash.1EA-20260922` baseline: only `Flash.1EA.mq5` and `Execution/FlashOrders.mqh` differ. `FlashOrders.mqh` is byte-identical to the baseline after removing the temporary test-only injection helper used for verification (hash `31ddc1665766d0b94b6b3e2300632c6d4c2d696f44c99b1d2cf5187286401629`, matches baseline exactly). The `Flash.1EA.mq5` diff is confined to new, self-contained additions: the double-fill evidence struct and pure classifier, the recovery repair function, the routing wrapper, the persisted unwind-flag helpers, the restart-override function, their self-tests, one new switch case in the recovery dispatch, two new call sites at existing hook points, the truncation-tolerance fix, and the build-id string. No line inside entry, exit, sizing, trailing, reversal, profit-target, sessions, daily-limits, ownership, or persistence-key logic was touched, confirmed by their complete absence from the diff. Every other module folder (Core, Entry, Market, Reconciliation, Recovery, Reversal, Risk, Trailing) is byte-identical to the baseline.

## Frozen-baseline integrity check performed at freeze time

Every file in `_freeze/NameOnly_Flash.1EA-20260922/`, `_freeze/SafetyRev_P3-REC02-SAFETYREV-20260922-01/`, and `_freeze/Phase3_P3-DEV-20260919-01/` was re-hashed against its recorded `source_hashes.txt` (or the equivalent recorded hash). All match exactly, nothing in those archives has been modified. This freeze does not alter or supersede any of them; they remain the rollback references.

## Compiler output

MetaEditor, same environment as prior accepted builds. Final compile: 0 errors, 0 warnings.

## Self-test results

195/195 passing on both smoke-test runs below (`FLASH PHASE 1 + PHASE 2 + PHASE 3 SELF-TEST SUITE COMPLETE | TOTAL: 195 | PASSED: 195 | FAILED: 0`), including new coverage: 3 self-tests for `ClassifyRecoveryRepairRouteWithDoubleFill` and 9 self-tests covering every branch of `ClassifyConfirmedDoubleFill` (each evidence criterion individually falsified, one at a time, confirmed to block classification).

## Evidence accepted for this freeze

1. **Focused Strategy Tester verification (authorized, injection-based, revision 4)** — wall-clock 2026-09-23 21:21:48. A temporary, Tester-only, flag-gated injection forced both bracket legs to fill on the first armed setup, reproducing the confirmed live double-fill shape against genuine broker state. Result: both legs filled, EXPOSURE_DISCREPANCY correctly raised, all 9 evidence criteria confirmed true in a diagnostic log, "Confirmed initial-bracket double-fill" logged, both legs closed via two real market deals one second apart, account back to flat, state transitioned RECOVERY_REQUIRED to WAITING_FOR_ENTRY, and Flash immediately armed a new setup and resumed scanning. Full pass on the authorized evidence bar (actual orders/deals/positions and state transitions, not a log message alone). The injection, its guard globals, its diagnostic logging, and its supporting helper were fully removed after this pass; none are present in this frozen build.
2. **Smoke test 1 (normal, non-injection)** — wall-clock 21:51:25 to 21:54:03, XAUUSD H1, 2026.09.15 to 2026.09.23. Clean build tag confirmed at init. 195/195 self-tests passed. Zero occurrences of any injection fire or diagnostic message. 5,174 setups armed and traded normally across the full window with zero real RECOVERY_REQUIRED escalations during live trading (the only 6 RECOVERY_REQUIRED transitions logged are self-test state-machine probes at init, not runtime events). Zero double-fill confirmations, as expected with nothing forcing one. Test ended normally via Tester's own end-of-test cleanup, final balance 102,116.59 USD.
3. **Smoke test 2 (normal, non-injection, exact final binary)** — wall-clock 22:09:58 to 22:12:31, identical window and inputs. Same build tag, 195/195 self-tests, zero injection residue, identical final balance (102,116.59 USD), confirming deterministic, repeatable behavior on the exact frozen `.ex5`.

## Integrity verification performed at freeze time

- `diff -rq` between this freeze's `source/` and the live project source tree (excluding the ex5): clean, no differences.
- `diff -rq` between the live project source tree and the live terminal (compile-target) source tree: clean, no differences.
- SHA-256 of the ex5 confirmed identical across three copies at freeze time: this archive, the live project copy, and the live terminal copy. All three: `d65b0889b22a708b8d9e5981cb025a7ec109f740d361556f061c51b35d235409`.

## Known limitations

1. This freeze does not authorize any new strategy features, further code changes, or additional trading logic. Any future correction remains a separately identified, archived-first change.
2. Not a claim of future profitability, and does not constitute a guarantee of behavior under live broker conditions beyond what the backtest and self-test evidence above have shown.
3. This build is not deployed to the live account. Deployment requires a separate, explicit authorization.

## Unrelated, still-open item (explicitly not part of this freeze)

A pre-existing, unrelated defect (`SetPositionSL failed, retcode=10016, Invalid Stops` in the reversal SL-attach logic, first observed 2026-09-21) remains open and untouched by this correction. Flash's escalation to RECOVERY_REQUIRED on that failure, and the startup-recovery unprotected-exposure safety net, both worked as designed when this occurred live on 2026-09-23. This is tracked separately and deferred at the user's explicit instruction; it is not addressed by this freeze.

## Rollback instructions

If a defect is ever attributed to this build that is not present in FLASH1EA-NAMEONLY-20260922-01: detach Flash.1EA, confirm the account is flat or in a safe state under magic 260917, then attach the original frozen `Flash.1EA.ex5` (SHA-256 `a55024fae0cb2bc270b08b9f1f6ed43b659e15210d6a554220128f57808ab0da`) from its unmodified freeze archive `_freeze/NameOnly_Flash.1EA-20260922/`. No code changes are needed to roll back, the prior binary was never touched or superseded, only copied from.

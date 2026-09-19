# Flash EA — Phase 2 Frozen Implementation Specification

Build ID: P2-SAFETYFIX-20260918-02. This is a description of what the source in `source/` actually does, read directly from that code. Where the implementation differs from what an earlier informal description of Phase 2 may have said, that discrepancy is called out rather than silently smoothed over. No strategy rule is introduced here that is not already in the code.

## Stage 2.1 — Trailing

Module: `Trailing/FlashTrailing.mqh` (`CFlashTrailing`), invoked from `ManageActiveSetup()` in `FlashEA.mq5`.

Inputs: `TrailingActivationDistance` (default 1.00, gold price units), `TrailingStopDistance` (default 1.00), `MinimumTrailingUpdate` (default 0.20).

Formulas, exactly as implemented:
- Favorable movement, BUY: `currentBid - actualEntryPrice`. SELL: `actualEntryPrice - currentAsk`.
- Activation: favorable movement must exceed `TrailingActivationDistance` before trailing begins.
- Candidate SL, BUY: `currentBid - TrailingStopDistance`. SELL: `currentAsk + TrailingStopDistance`.
- New SL only ever tightens: BUY takes `max(currentSL, candidate)`, SELL takes `min(currentSL, candidate)`.
- An update is only sent to the broker if the improvement over the last broker-confirmed SL exceeds `MinimumTrailingUpdate`.
- The proposed SL is normalized to the symbol's tick size before being sent (`FlashBrokerRules::NormalizeToTick`).

State transitions: `LastConfirmedSL` and `LastConfirmedTrailingReference` are updated only from a broker-confirmed modification, never from a value merely requested. This confirmed value is what gates Stage 2.2 eligibility (below) and is persisted after every update (`FlashPersistence::SaveLastConfirmedSL` / `SaveTrailingReference`) so a restart recovers the correct reference rather than re-deriving it.

Dependencies: `Execution/FlashBrokerRules.mqh` for tick normalization and the underlying `SetPositionSL` order send.

## Stage 2.2 — Reversal

Module: `Reversal/FlashReversal.mqh` (`CFlashReversal`, pure decision functions) plus orchestration in `FlashEA.mq5` (`ArmReversalOrder`, the reversal-detection branch of `ManageActiveSetup()`, and `ReconcileReversal()`). Reversal execution is implemented and validated only on a hedging account; on a netting account Flash never arms a reversal order, and a flattening transaction there is never treated as a completed reversal.

Arming eligibility (`EligibleToArm`), all five conditions required: initial fill confirmed, the initial opposite pending order cancelled, the initial SL verified present, trailing activated, and the trailing SL modification itself broker-confirmed (not merely requested). The reversal order's reference price is exactly the confirmed trailing SL of the direction being reversed away from (`ReversalReferencePrice`) — never a separately invented level.

Detection ordering (the corrected sequence, this build): `ManageActiveSetup()` checks first, before anything else, whether `g_setup.ReversalPendingTicket != 0` and that ticket is no longer selectable (`!OrderSelect(...)`) — meaning it filled or was broker-removed. If so, it immediately transitions to `FLASH_STATE_REVERSAL_RECONCILING` and returns, before the function ever reaches the "no open positions, setup fully closed" branch below it. This ordering is the fix for the live defect observed 2026-09-17 22:03:20: a same-tick SL hit plus reversal fill was previously being swallowed by the old-position-closed branch, leaving the new position briefly untracked. This reordering is explicitly still subject to Test 6 and is not to be treated as proven by this description alone (see Acceptance Ledger).

Reconciliation (`ReconcileReversal`, invoked from the `FLASH_STATE_REVERSAL_RECONCILING` state): closes any remaining old-direction exposure, verifies the account is flat in the old direction (`OldExposureFullyClosed`: remaining volume `<= 0.0000001`), verifies the new-direction volume matches the intended target within half a volume step (`NewExposureMatchesTarget`), and assigns a protective stop to the new leg. The new leg's volume is the setup's currently permitted volume under the active sizing policy (`IntendedReversalVolume`) — never the old exposure doubled, never accumulated across legs. The new leg's protective stop is `actualNewFillPrice ∓ TrailingStopDistance` (`ProtectiveStopForNewDirection`) — a fresh distance-based stop, not a reused Phase 1 level, giving every reversal leg a defined non-zero initial stop.

## Stage 2.3 — Risk / Setup Target

Modules: `Risk/FlashProfitTarget.mqh` (`CFlashProfitTarget`), `Core/FlashDailyLimits.mqh` (`CFlashDailyLimits`), `Risk/FlashSizing.mqh`.

Inputs: `EnableSetupProfitTarget` (default true), `SetupProfitTargetCurrency` (default 3.00), `EnableDailyProfitLimit` / `DailyProfitLimitCurrency` (default false / 30.00), `EnableDailyLossLimit` / `DailyLossLimitCurrency` (default false / 20.00), `PositionSizingMethod` (`FLASH_SIZING_FIXED_LOT` default), `EquityRiskPerSetupPercent` (default 0.50).

Setup profit target: `CombinedPL = realizedPL + floatingPL`, evaluated every tick in `ManageActiveSetup()` before trailing/reversal updates run. When `CombinedPL` reaches `SetupProfitTargetCurrency` (and the feature is enabled), the state machine transitions to `FLASH_STATE_SETUP_EXIT`, which drives `HandleSetupExit()` — a controlled exit, not an immediate market dump, and this is the function the retry-throttle correction (Stage 2.4/2.5 boundary, see below) applies to.

Daily limits: `NewExposurePermitted` gates whether new exposure (a fresh entry or a reversal arm) is allowed at all, combining both the profit-limit and loss-limit checks against `ComputeTodayRealizedPL` for the symbol/magic pair, offset by `BrokerServerUTCOffsetHours` so the day boundary matches Kenya time context rather than raw server time.

## Stage 2.4 — Trading Controls

Modules: `Core/FlashSessions.mqh` (session windows), `Core/FlashOwnership.mqh` (single-instance lock, detailed below), `FlashEA.mq5` inputs `MaximumAllowedSpread`, `FlashMagicNumber`.

Session control (`EnableTradingSessions`, default false): three named windows, Early (default 04:00-05:00), Midday (10:00-11:00), Evening (17:00-18:00), each independently enabled, all stated in Kenya time and converted using `BrokerServerUTCOffsetHours`.

Ownership lock (`CFlashOwnership`), the mechanism behind one of the four preserved safety corrections: each `(symbol, magic)` pair has a terminal-wide GlobalVariable owner slot and a heartbeat slot. `TryClaim` is called every tick and resolves to one of four pure decisions (`Decide`): `CLAIM_NEW` (no real owner yet — a sentinel of `0.0` counts as unowned even though the variable technically exists), `ALREADY_OWNER`, `TAKEOVER_STALE` (the recorded owner's heartbeat has exceeded `FLASH_OWNERSHIP_HEARTBEAT_TIMEOUT_SECONDS`), or `BLOCKED_CONFLICT` (another chart actively owns it and its heartbeat is current). The corrected claim/takeover paths use `GlobalVariableSetOnCondition(ownerVar, myChartId, expectedPriorValue)` — an atomic compare-and-set — rather than a separate read then write, closing the race where two charts both observing "unowned" in the same tick could previously both believe they had won (live evidence 2026-09-17: charts 46923012826300 and 46944538470998 both logged a successful claim within the same second under the pre-fix code). A lost race is logged and retried the following tick rather than retried inline. `Release` runs on clean `OnDeinit` so a legitimate restart does not have to wait out the staleness timeout.

## Stage 2.5 — Integration / Recovery

Modules: `Recovery/FlashRecovery.mqh` (`CFlashRecovery`), `Core/FlashPersistence.mqh`, `Core/FlashState.mqh`.

State machine (`ENUM_FLASH_STATE`): `INITIALIZING → WAITING_FOR_ENTRY → PLACING_ORDERS → ORDERS_ARMED → ENTRY_DETECTED → CANCELLING_OPPOSITE → POSITION_ACTIVE`, with Phase 2 adding `REVERSAL_RECONCILING` and `SETUP_EXIT` as branches out of `POSITION_ACTIVE`, and `RECOVERY_REQUIRED` / `TRADING_BLOCKED` as fault states reachable from multiple points (e.g. an unprotected position whose emergency SL repair fails, or an unverifiable reversal-order cancellation).

Recovery classification (`CFlashRecovery::Inspect` + `Classify`), run at `OnInit` against live broker state for the configured `(symbol, magic)`: builds a full snapshot (pending buy-stop/sell-stop tickets, open position tickets, inferred active direction, whether any open position lacks a protective SL) and classifies it into one of six scenarios — `NONE`, `VALID_PENDING_PAIR`, `INCOMPLETE_PENDING`, `ACTIVE_PROTECTED`, `ACTIVE_UNPROTECTED`, `UNEXPECTED_OPPOSITE`. `Classify` is a pure function, independently exercised by the self-test suite against synthetic snapshots, not only live state.

Broker order execution (`Execution/FlashOrders.mqh`), the mechanism behind two more of the four preserved safety corrections:
- `ResolveFillingMode(symbol)` reads the symbol's actual `SYMBOL_FILLING_MODE` flags and prefers FOK, then IOC, falling back to RETURN only if neither is supported — replacing a prior hardcoded `ORDER_FILLING_RETURN` that this broker/account rejected outright (retcode 10030) on every market close attempt for XAUUSD.
- `SendMarketDealWithFillingFallback` sends a market deal with the resolved mode and, specifically on a `TRADE_RETCODE_INVALID_FILL` (10030) response only, retries with each other supported mode in turn before giving up; any other rejection reason is returned immediately and is never masked by trying another filling mode. This is used by `ClosePositionMarket` and the test-only close path; `SendPendingOrder` uses `ResolveFillingMode` directly.
- `HandleSetupExit()` (the controlled-exit driver for Stage 2.3's profit target) now enforces a 2-second cooldown between attempts via a static last-attempt timestamp, replacing unconditional per-tick re-entry. This stops the specific runaway observed live 2026-09-18 (1,418 consecutive close attempts against the same rejected filling mode in under a minute). **This cooldown bounds retry frequency only. It is not evidence that every possible exit-failure mode is now safely resolved** — that broader claim is not made anywhere in this specification or the evidence ledger, per explicit instruction.

Persistence (`Core/FlashPersistence.mqh`): active direction, trailing-active flag, last confirmed SL, trailing reference, reversal ticket, and SetupId are all written on every relevant state change and read back at `OnInit`, so a restart recovers mid-setup state rather than starting blind. The blank-`SetupId` defect (a restart previously recovering into a setup with an empty identifier, breaking downstream logging/matching) was corrected so a recovered setup is assigned a valid `SetupId` immediately.

## Discrepancies between this specification and any earlier informal description

None identified in this pass beyond what is already flagged inline above (the reversal-detection reordering and the retry-throttle scope). If a future review finds the code diverges from an intended design that was never written into source, that divergence will be recorded here rather than corrected silently.

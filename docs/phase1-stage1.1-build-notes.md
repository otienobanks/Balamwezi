# Flash EA - Phase 1, Stage 1.1 Build Notes

## Status: CODED AND COMPILED. Awaiting live/demo verification and explicit user freeze.

## Scope of this stage

Project foundation only, per Flash EA Phase 1 build specification (2026-09-17):
project structure, module boundaries, input declarations and validation,
phase-tagged logging, the explicit state machine, chart symbol and
timeframe identification, a read-only startup exposure inspection, and
MT5 event-handler wiring (OnInit/OnTick/OnTradeTransaction/OnDeinit).

Explicitly out of scope for this stage (per the build boundary in the
spec and the required build sequence): broker validation/legality
checks (Stage 1.2), entry price calculation (Stage 1.3), and all order
placement, fill detection, and cancellation (Stage 1.4). No order is
sent anywhere in this stage's code. `FlashOrders.mqh` and
`FlashBrokerRules.mqh` exist only as placeholder classes so the module
boundaries are real from the start; their real logic is not written yet.

## Files delivered

```
MQL5/Experts/FlashEA/
├── FlashEA.mq5                    (main file: inputs, event handlers, self-test runner)
├── Core/
│   ├── FlashConfig.mqh            (input struct + validation)
│   ├── FlashState.mqh             (state machine + SFlashSetup identity struct)
│   └── FlashLogger.mqh            (shared phase-tagged logging)
├── Market/
│   ├── FlashSymbol.mqh            (symbol/quote access, basic tradeability check)
│   └── FlashTimeframe.mqh         (attached-timeframe detection, new-bar edge detector)
├── Execution/
│   ├── FlashOrders.mqh            (placeholder - Stage 1.4 owns this)
│   └── FlashBrokerRules.mqh       (placeholder - Stage 1.2 owns this)
└── Recovery/
    └── FlashRecovery.mqh          (read-only startup exposure snapshot only)
```

## Inputs implemented (per spec Section 3)

EntryMode, EntryDistance, CandleEntryBuffer, FixedLotSize, PositionsPerSetup,
MaximumSpread, MagicNumber, EnableDetailedLogging - all present, all validated
in `CFlashConfig::Validate()`. Added one build-methodology input not in the
original spec table, per the ea-builder skill's dry-run-before-trust
convention: `EnablePhase1SelfTest` (default true), which runs an in-EA
self-test suite against the real CFlashConfig/CFlashState code paths at
OnInit, before any live logic runs.

## State machine

Implemented exactly the 9 states from the spec (INITIALIZING,
WAITING_FOR_ENTRY, PLACING_ORDERS, ORDERS_ARMED, ENTRY_DETECTED,
CANCELLING_OPPOSITE, POSITION_ACTIVE, RECOVERY_REQUIRED, TRADING_BLOCKED)
with an explicit legal-transition table. An illegal transition is rejected
and logged rather than silently applied. RECOVERY_REQUIRED and
TRADING_BLOCKED are reachable from any state, matching their role as
safety states.

## Compile verification (real, checked result)

Compiled in MetaEditor via File > Open > FlashEA.mq5 > Compile (F7), on the
user's own desktop, 2026-09-17.

```
FlashEA.mq5
FlashConfig.mqh
FlashLogger.mqh
FlashState.mqh
FlashSymbol.mqh
FlashTimeframe.mqh
FlashOrders.mqh
FlashBrokerRules.mqh
FlashRecovery.mqh
code generated
0 errors, 0 warnings, 1801 ms elapsed, cpu='AVX2 + FMA3'
```

FlashEA.ex5 confirmed produced (29,416 bytes) in
MQL5/Experts/FlashEA/FlashEA.ex5 immediately after this compile.

## What is NOT yet verified

Compilation is proven; live/demo behavior is not yet proven. Claude's
desktop access to the MetaTrader 5 terminal itself is read-only in this
session (view/screenshot only, no click or type), so attaching FlashEA to
an XAUUSD chart, running the self-test suite live, and confirming the
Journal shows the expected PASS lines and OnInit summary needs to be done
by OtienoBanks directly, or via a session where MT5 interaction is
explicitly granted.

Expected Journal output on attach (EnablePhase1SelfTest=true, default):
a `[FLASH][SELFTEST] ... PASS` line per test, ending with a line shaped
like `FLASH PHASE 1 STAGE 1.1 SELF-TEST SUITE COMPLETE | TOTAL: N | PASSED: N | FAILED: 0`,
followed by `[FLASH][INIT] ...` lines confirming symbol, timeframe, magic
number, and final state (WAITING_FOR_ENTRY on a clean account, or
RECOVERY_REQUIRED if the account already has orders/positions under this
magic number).

## Acceptance criteria (Stage 1.5-style gate, applied to this stage only)

| Criterion | Status |
|---|---|
| Compiles with zero errors and zero warnings | PASS (verified above) |
| Correct chart-timeframe detection | Implemented (CFlashTimeframe, single source of truth = _Period); not yet observed live |
| Valid input handling | Implemented (CFlashConfig::Validate, covered by self-test); not yet observed live |
| Safe rejection of unsupported symbols | Implemented (CFlashSymbol::IsBasicallyTradeable -> TRADING_BLOCKED); not yet observed live |
| No trading orders placed | Guaranteed by construction - FlashOrders.mqh has no OrderSend call in this stage |

## Freeze status

NOT FROZEN. Per the ea-builder skill's standing rule, freezing this stage is
OtienoBanks's own explicit act, never Claude's. This stage is ready for
review: attach FlashEA.mq5 (or the compiled .ex5) to an XAUUSD chart on a
demo account, confirm the self-test suite passes and the OnInit log lines
look correct, then say explicitly whether Stage 1.1 is frozen or needs
changes before Stage 1.2 (Broker Validation Engine) begins.

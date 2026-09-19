# Flash EA — Complete Strategy and Three-Phase Build Documentation

Status: Strategy specification frozen
Version: 1.0
Platform: MetaTrader 5
Instrument: Gold (XAUUSD)
Timeframe: Universal (uses attached chart timeframe)
Development structure: 3 phases, 15 stages, mandatory testing and approval gates at the end of each phase.

Purpose: Build an automated trading system that reacts to price movement in either direction, manages positions using trailing stops and reversal orders, and aims to capture repeated trading opportunities without predicting market direction.

## Final frozen decisions (supersede earlier provisional rules)

1. Trailing activates after price moves a configurable distance in the trade's favor.
2. The initial stop loss is placed at the original opposite pending-order level.
3. When a reversal triggers, Flash closes the existing position and opens a position in the opposite direction.

---

## PART 1 — Project Objectives

### 1.1 What Flash EA is designed to do

Flash is a direction-neutral trading system that uses pending stop orders to respond to price movement. It does not use indicators to predict market direction. Instead, it prepares two possible entries and allows the market to determine which direction is activated.

Strategy cycle:

1. **Prepare the market** — check symbol, trading permissions, spread, account risk, and permitted trading session.
2. **Place two pending orders** — Buy Stop above the market, Sell Stop below it.
3. **Enter the first direction** — when one order executes, cancel the opposite initial order and begin managing the position.
4. **Activate trailing** — once price moves the configured distance in Flash's favor, activate trailing and maintain an opposite reversal order.
5. **Exit or reverse** — close the setup at its monetary profit target, exit at the protective stop, or reverse direction when the reversal order executes.
6. **Re-arm** — record the result, check daily limits and trading session, prepare another setup when permitted.

Flash aims to capture relatively small profits, such as $1 to $3 per setup, while allowing larger configured targets. Profitability must be established through testing; frequent small winning trades alone do not demonstrate a positive trading edge.

### 1.2 Frozen strategy requirements

| Component | Specification |
|---|---|
| Platform | MetaTrader 5 |
| Instrument | Gold (XAUUSD) |
| Directional bias | None |
| Technical indicators | None |
| Initial entry orders | Buy Stop and Sell Stop |
| Entry modes | Fixed distance or previous candle |
| Entry refresh | Every new candle |
| Initial SL | Original opposite entry level |
| Trailing activation | Configurable favorable price movement |
| Trailing distance | Configurable |
| Reversal | Close existing position and open opposite |
| Position count | Configurable |
| Position sizing | Fixed lot or percentage risk |
| Setup profit target | Combined profit of all positions |
| Daily profit target | Configurable |
| Daily loss limit | Configurable |
| Session filter | Optional |
| Timeframe | Automatically detected from chart |

The EA operates independently of other trading robots and manual positions.

---

## PART 2 — Universal Timeframe Architecture

### 2.1 One EA for all chart timeframes

Flash uses the timeframe of the chart it is attached to. There is no separate trading-timeframe input.

| Attached chart | Entry reference | Pending-order refresh |
|---|---|---|
| M1 | Previous M1 candle | Every new M1 candle |
| M5 | Previous M5 candle | Every new M5 candle |
| M15 | Previous M15 candle | Every new M15 candle |
| M30 | Previous M30 candle | Every new M30 candle |
| H1 | Previous H1 candle | Every new H1 candle |
| H4 | Previous H4 candle | Every new H4 candle |
| D1 | Previous daily candle | Every new daily candle |

Other standard MT5 timeframes use the same architecture. The EA obtains its timeframe directly from the chart using PERIOD_CURRENT or _Period.

### 2.2 What changes with the timeframe

The attached timeframe controls: which completed candle is used for previous-candle entries, when the EA refreshes its initial pending orders, and which candle's high and low are used for entry calculations.

The timeframe does not automatically change the user's fixed price distances, lot sizes, monetary targets, or risk limits. For example, if the entry distance is set to $1.00, the EA uses that distance on M1 and H4 unless the user changes the input.

### 2.3 Tick-driven position management

All active-position management operates on every available tick, including: profit-target checks, trailing activation, stop-loss modifications, reversal-order updates, daily risk checks, and session-end order cancellation. A position opened on H4 must not wait for the next four-hour candle before Flash manages its risk.

---

## PART 3 — Entry Engine

### 3.1 Entry Mode A: Fixed distance

Flash places two pending orders at a configurable distance from the current market.

Buy Stop = Ask + EntryDistance
Sell Stop = Bid - EntryDistance

Example: Bid $3,000.00, Ask $3,000.20, spread $0.20, entry distance $1.00 gives Buy Stop $3,001.20 and Sell Stop $2,999.00. This accounts for spread by measuring each entry from the relevant side of the quote.

The EA must validate the broker's minimum pending-order distance and normalize prices to the symbol's actual tick size. The $1.00 distance is a provisional testing value, not a proven optimal gold setting.

### 3.2 Entry Mode B: Previous candle

Flash reads the high and low of the most recently completed candle on the attached timeframe.

Buy Stop = PreviousHigh + Buffer
Sell Stop = PreviousLow - Buffer

Example: previous M5 candle high $3,005.00, low $3,001.00, entry buffer $0.20 gives Buy Stop $3,005.20 and Sell Stop $3,000.80. Both orders must still be legal relative to current Bid and Ask.

If a calculated level is no longer valid because price has already passed it, Flash must not place an illegal pending order. Proposed default: skip that entry cycle and recalculate on the next candle rather than silently changing the strategy's intended entry level.

### 3.3 Pending-order refresh

Confirmed rule: untriggered orders refresh on every new candle.

1. Detect a new candle.
2. Check whether an active position or unresolved trade transaction exists.
3. If Flash is waiting for entry, calculate new Buy Stop and Sell Stop levels.
4. Modify or replace the existing pending orders where necessary.
5. Verify the broker's actual order state.

Flash must not create a second pair of orders before the previous pair has been safely cancelled or reconciled. If one order triggers during the refresh process, the execution event takes priority.

### 3.4 Initial entry execution

If the Buy Stop triggers first, Flash must confirm the BUY fill, record the actual entry price and filled volume, identify all orders belonging to that setup, cancel the remaining initial Sell Stop orders, verify those cancellations succeeded, and begin managing the BUY position. The opposite process applies when a Sell Stop triggers first.

If both directions fill during a rapid market movement, Flash must reconcile the actual exposure. It cannot assume that cancelling an order guarantees it was not already executed.

---

## PART 4 — Initial Stop Loss

### 4.1 Confirmed rule

The initial stop loss uses the original opposite pending-order level. This replaces the previously proposed fixed-distance initial stop loss. The EA must preserve the original opposite entry price before cancelling the opposite pending order; that saved price becomes the protective stop-loss reference for the active position.

BUY example: Buy Stop $3,001.00, Sell Stop $2,999.00, Buy Stop executes. Flash records BUY entry $3,001.00, original opposite entry $2,999.00, initial BUY SL $2,999.00. Initial stop distance $2.00.

SELL example: same orders, Sell Stop executes. Flash records SELL entry $2,999.00, original opposite entry $3,001.00, initial SELL SL $3,001.00. Initial stop distance $2.00.

### 4.2 Important implications

The initial stop distance is not necessarily fixed. In fixed-distance entry mode it depends on both entry distances and the spread. In previous-candle mode it depends on the candle's range, entry buffers, and any difference between requested and actual fill prices.

This matters for percentage-risk sizing. Flash must calculate the expected loss using the actual proposed entry and initial SL prices before placing the orders. If the resulting position size is below the broker's minimum permitted volume, the EA must skip the setup rather than exceed the configured risk budget.

### 4.3 Initial SL and spread

The EA must distinguish between the original opposite pending-order price and the actual price at which the protective SL may execute. For a BUY, the SL is triggered using Bid. For a SELL, the SL is triggered using Ask. An initial SL at the original opposite entry level does not guarantee the realized loss equals the theoretical price difference; spread changes, gaps, slippage, and execution costs can affect the result. The EA must record both the intended risk and the actual realized loss.

---

## PART 5 — Trailing-Stop Engine

### 5.1 Confirmed activation rule

Trailing does not begin immediately. Flash waits until price moves a configurable distance in the position's favor (TrailingActivationDistance).

Example: BUY entry $3,000.00, trailing activation $1.00, trailing distance $1.00. Trailing becomes eligible when Bid reaches $3,001.00. Same principle in reverse for SELL positions, using Ask. The activation threshold is based on favorable price movement, not an indicator.

### 5.2 Trailing calculations

BUY: CandidateSL = Bid - TrailingDistance
SELL: CandidateSL = Ask + TrailingDistance

The EA only applies a candidate SL if it improves the existing stop and satisfies broker restrictions. A BUY stop can move upward but never downward. A SELL stop can move downward but never upward.

### 5.3 Example of BUY trailing sequence

| Bid price | Stop-loss action |
|---|---|
| $3,000.00 | Initial SL at $2,998.00 |
| $3,000.50 | Trailing not active |
| $3,001.00 | Trailing activates; candidate SL $3,000.00 |
| $3,002.00 | SL advances to $3,001.00 |
| $3,003.00 | SL advances to $3,002.00 |
| $3,002.50 | SL remains at $3,002.00 |

(Illustrative; assumes broker stop restrictions permit these levels.)

### 5.4 Minimum trailing step

Flash has a configurable minimum trailing step. For example, if the minimum step is $0.20, the EA should not send a stop-modification request for every $0.01 price movement; it waits until the proposed SL improves the current SL by at least $0.20. This reduces unnecessary broker requests and order-modification failures. The trailing engine must always prioritize a valid protective stop over maintaining an exact reversal-order distance.

---

## PART 6 — Reversal Engine

### 6.1 Confirmed reversal behavior

When an opposite reversal order executes, Flash closes the existing position and establishes a new position in the opposite direction (BUY to SELL to BUY to SELL). The EA must not maintain a permanent directional bias. Reversals are permitted only when session and daily trading controls allow new entries.

### 6.2 Reversal order placement

After the first entry, Flash cancels the original opposite pending order, then creates a new opposite pending order associated with the active position's trailing-stop system. For a BUY, the reversal order is a Sell Stop. For a SELL, the reversal order is a Buy Stop. The reversal order follows the trailing SL as closely as the broker's rules permit. The protective SL and reversal order are separate broker instructions and cannot be guaranteed to execute simultaneously.

### 6.3 Reversal example

Active BUY: entry $3,000.00, initial SL $2,998.00, trailing activates $3,001.00, price advances to $3,003.00, trailing SL $3,002.00. Flash attempts to maintain a Sell Stop near the trailing SL, subject to broker restrictions. If price reverses and the Sell Stop executes, the EA reconciles the BUY closure and SELL entry; SELL becomes the active direction, and Flash starts managing its protective stop and prepares the next reversal opportunity.

### 6.4 Reversal before trailing activation

Before trailing activates, the original opposite entry level remains the initial protective SL. Proposed behavior:

- Cancel the original opposite pending order after the first entry.
- Keep the original opposite price as the protective SL.
- Do not create a new reversal order until trailing activates.
- If the initial SL is hit before activation, close the setup and wait for a new opportunity.

This avoids automatically reversing every initial losing trade before trailing has activated, and prevents the original opposite order from remaining active alongside a new reversal order.

### 6.5 Reversal position sizing

When a reversal occurs, Flash must not blindly duplicate the existing exposure. Proposed rule: calculate the new position size using the configured sizing mode and the new trade's protective SL. Fixed-lot mode uses the configured lot size and position count; percentage-risk mode calculates a new risk-based volume. If the broker cannot accommodate the intended reversal without exceeding the risk budget, Flash must reject the new exposure and safely manage or close the existing position. A reversal must never increase the number of active positions beyond the configured maximum.

### 6.6 Reversal failure handling

The EA must explicitly handle: reversal order rejected, reversal order partially filled, existing position fails to close, opposite position opens before the original closes, internet connection lost during reversal, broker rejects a stop modification, session ends during reversal, daily limit reached during reversal. The EA must reconcile actual broker positions and orders before returning to normal operation. A reversal cannot be considered successful merely because the order-submission function returned successfully.

---

## PART 7 — Profit and Risk Management

### 7.1 Combined setup profit target

The profit target applies to the combined profit of all positions in the active setup. Example: three BUY positions with floating profits $1.20, $0.90, $1.10 totaling $3.20 against a $3 target triggers Flash to attempt closing the entire setup. The EA must calculate the combined net result using available profit, commission, swap, and fee information. Final realized profit may differ from the target because of slippage and closing costs. The target must be configurable ($1, $3, $10, $100, $1,000, or another positive amount).

### 7.2 Daily profit target

Optional. Example: DailyProfitTarget = 30. When Flash's realized daily net profit reaches or exceeds $30, it stops initiating new setups, cancels pending orders capable of creating new exposure, and continues managing existing positions normally.

### 7.3 Daily loss limit

Optional. Example: DailyLossLimit = 20. When realized daily net P/L reaches -$20 or below, Flash stops initiating new setups; existing positions continue to be managed. The daily loss limit is a new-entry cutoff, not a guaranteed maximum loss.

### 7.4 Daily accounting

The EA must calculate daily results using its own trading history, excluding unrelated manual trades or trades from other EAs. The accounting engine must: use Kenyan calendar days, include realized trading costs, avoid double-counting partial closes, recover the current day's result after a restart, handle positions opened before midnight and closed after midnight, and reset entry permissions at the next Kenyan midnight. The daily result must be reconstructed from broker history rather than relying solely on an in-memory counter.

### 7.5 Fixed-lot sizing

Inputs: FixedLotSize and PositionsPerSetup. Example: fixed lot 0.01, positions per setup 3, so Flash attempts to open three positions of 0.01 lots each. The broker's volume limits and margin requirements must be validated before placing the orders.

### 7.6 Percentage-risk sizing

Example: account equity $1,000, risk 0.5%, total intended setup risk $5. The EA calculates the position volume using the distance between the intended entry and the initial SL. Because the initial SL uses the opposite pending-order level, the risk calculation must use that exact level. The configured risk percentage applies to the combined setup, not separately to each position. If the minimum broker lot would exceed the risk budget, Flash must skip the setup.

---

## PART 8 — Trading Sessions

### 8.1 Confirmed Kenyan-time windows

| Window | Time (EAT) |
|---|---|
| Asia | 04:00 to 05:00 |
| London | 10:00 to 11:00 |
| New York | 17:00 to 18:00 |

These are fixed Kenyan-time trading windows, not automatically adjusted exchange-opening times. The session filter has a master ON/OFF input; each session has its own enable switch and configurable start and end time.

### 8.2 Session-end behavior

Confirmed rule: when a session ends, cancel reversal orders and prevent new entries, but continue managing existing positions. Example: Flash opens a BUY at 10:55 AM; at 11:00 AM the session ends, Flash cancels its pending reversal order, the BUY remains open, the trailing SL continues operating, the profit target remains active, and no new position may open until trading is permitted again. If the position closes outside the session, Flash waits until the next permitted session before placing a fresh pair of orders.

### 8.3 Broker time conversion

Flash must use EAT (UTC+3) for all session and daily-reset decisions. The live time engine must determine the broker's server-time relationship to GMT and handle changes in that relationship. Historical backtesting requires special treatment because MT5 Strategy Tester time functions do not necessarily reproduce historical broker timezone offsets, so the EA includes a configurable historical broker UTC offset for backtesting. The session engine must never silently assume broker time is Kenyan time.

---

## PART 9 — Complete EA Inputs

Monetary targets are in the account's deposit currency. Price distances are in XAUUSD price units, not raw MT5 points.

| Input | Proposed default | Purpose |
|---|---|---|
| EntryMode | FixedDistance | Select entry method |
| EntryDistance | 1.00 | Fixed entry distance |
| CandleEntryBuffer | 0.00 | Previous-candle entry buffer |
| TrailingActivationDistance | 1.00 | Favorable movement before trailing |
| TrailingDistance | 1.00 | Distance between price and trailing SL |
| MinimumTrailingStep | 0.20 | Minimum SL improvement |
| PositionSizingMode | FixedLot | Select sizing method |
| FixedLotSize | 0.01 | Lot size per position |
| RiskPercent | 0.5 | Total setup equity risk percentage |
| PositionsPerSetup | 1 | Requested number of positions |
| SetupProfitTarget | 3.00 | Combined setup profit target |
| EnableDailyProfitTarget | false | Enable daily profit cutoff |
| DailyProfitTarget | 30.00 | Daily profit threshold |
| EnableDailyLossLimit | false | Enable daily loss cutoff |
| DailyLossLimit | 20.00 | Daily loss threshold |
| EnableSessionFilter | false | Enable trading windows |
| EnableAsiaSession | true | Enable Asia window |
| AsiaStart | 04:00 | EAT start |
| AsiaEnd | 05:00 | EAT end |
| EnableLondonSession | true | Enable London window |
| LondonStart | 10:00 | EAT start |
| LondonEnd | 11:00 | EAT end |
| EnableNewYorkSession | true | Enable New York window |
| NewYorkStart | 17:00 | EAT start |
| NewYorkEnd | 18:00 | EAT end |
| MaximumSpread | 0.30 | Maximum spread for new entries |
| MagicNumber | Configurable | Identify Flash trades |
| EnableDetailedLogging | true | Enable diagnostic logging |

The initial SL distance is deliberately absent as an independent input because its level is determined by the original opposite pending order. The proposed numerical defaults are starting values for testing, not verified optimal gold settings.

---

## PART 10 — Three-Phase Development Program

Exactly three phases, five stages each, with an acceptance gate at the end of every phase.

### PHASE 1 — Foundation and Entry Engine

Objective: build a reliable MT5 EA that can calculate, place, refresh, and reconcile its initial Buy Stop and Sell Stop orders, protecting executed positions using the initial SL even though trailing and reversal are not yet implemented.

**Stage 1.1 — Project foundation**

Proposed structure:

```
MQL5/
└── Experts/
    └── FlashEA/
        ├── FlashEA.mq5
        ├── Core/
        │   ├── FlashConfig.mqh
        │   ├── FlashState.mqh
        │   └── FlashLogger.mqh
        ├── Market/
        │   ├── FlashSymbol.mqh
        │   └── FlashTimeframe.mqh
        ├── Execution/
        │   ├── FlashOrders.mqh
        │   └── FlashBrokerRules.mqh
        ├── Management/
        │   ├── FlashTrailing.mqh
        │   ├── FlashReversal.mqh
        │   └── FlashRisk.mqh
        └── Recovery/
            └── FlashRecovery.mqh
```

Implement OnInit(), OnTick(), OnTradeTransaction(), OnDeinit(). Define unique setup identifiers and a magic-number system.

Acceptance criteria: zero compilation errors and warnings, correct chart-timeframe detection, valid input handling, safe rejection of unsupported symbols.

**Stage 1.2 — Broker validation engine**

Retrieve Bid, Ask, spread, tick size, point size, min/max lot sizes, volume step, minimum stop distance, freeze level, available margin, account margin mode, permitted order types and execution policies. Validate prices and volumes before submitting orders.

Acceptance criteria: illegal prices, invalid volumes, insufficient margin, and unsupported trading conditions detected and handled without uncontrolled exposure.

**Stage 1.3 — Universal entry calculation**

Implement fixed-distance and previous-candle entry modes using the attached chart timeframe, with reliable new-candle detection. Calculate the initial SL from the original opposite pending-order level and the intended monetary risk before order placement.

Acceptance criteria: both entry modes produce valid prices across M1, M5, M15, M30, H1, H4, D1, with no candle generating duplicate refresh events.

**Stage 1.4 — Pending-order execution**

Calculate both entry prices, calculate corresponding initial stop losses, validate setup risk and margin, submit pending orders, verify broker acceptance, detect first fill, cancel remaining initial opposite orders, verify resulting position and protective SL. Handle partial fills and simultaneous execution attempts. Trailing and reversal remain disabled in Phase 1; positions are protected by initial SL and managed under a defined test-only exit procedure.

Acceptance criteria: BUY-first and SELL-first scenarios work correctly, no known duplicate-entry or unprotected-position defect.

**Stage 1.5 — Phase 1 integration gate**

| Test | Expected result |
|---|---|
| Buy Stop triggers first | BUY opens correctly |
| Sell Stop triggers first | SELL opens correctly |
| Neither order triggers | Orders refresh on new candle |
| Spread exceeds limit | New entry blocked |
| Broker rejects an order | State reconciled safely |
| Both directions fill | Actual exposure reconciled |
| Terminal restarts | Existing trades identified |
| Invalid symbol | Trading blocked |
| Insufficient margin | Setup rejected |

Phase 1 is complete only after all required tests pass and the user approves progression to Phase 2.

### PHASE 2 — Trailing, Reversal and Risk Engine

Objective: transform the working entry engine into the complete Flash trading system.

**Stage 2.1 — Trailing-stop engine**

Configurable trailing activation and distance, minimum trailing step, BUY and SELL trailing calculations, broker-safe stop modifications, trailing-state persistence. Operates on every tick. A BUY stop must never move downward; a SELL stop must never move upward. A rejected stop modification must not be recorded as successful.

Acceptance criteria: trailing activation, ratcheting, broker validation, and restart recovery pass in both directions.

**Stage 2.2 — Reversal engine**

Reversal-order creation, modification, cancellation, detection of actual reversal fills, closure of the previous position, confirmation of the new position, recovery from partial or failed reversals. Must respect session permissions and daily limits, and must not create uncontrolled overlapping positions.

Acceptance criteria: BUY-to-SELL and SELL-to-BUY reversals execute and reconcile correctly, including broker rejection, partial fills, and disconnection scenarios.

**Stage 2.3 — Position sizing and profit targets**

Fixed-lot and percentage-risk modes, configurable positions per setup, combined setup profit target. Profit calculated from actual broker position data and trading costs. On target, cancel associated pending orders and attempt to close the complete setup; reconcile partial closures before returning to waiting state.

Acceptance criteria: correct position sizing, combined risk calculation, target detection, and setup closure across single- and multiple-position configurations.

**Stage 2.4 — Daily limits and session engine**

Daily profit target, daily loss limit, Kenyan calendar-day accounting, three configurable trading windows, broker-time conversion, session-end order cancellation, daily-limit entry blocking, recovery of daily results after restart. Existing positions remain managed when new entries are blocked.

Acceptance criteria: session transitions, midnight resets, daily thresholds, and restart recovery work correctly without permitting unauthorized new exposure.

**Stage 2.5 — Phase 2 integration gate**

Full cycle: place Buy Stop and Sell Stop, first order executes, protect position with initial SL, activate trailing after favorable movement, manage trailing and reversal order, close at target/stop/reverse, reconcile and re-arm when permitted.

Must verify interaction between all engines, not merely test each module independently. Must correctly distinguish a normal profit-target exit, an initial SL exit, a trailing SL exit, and a reversal.

Phase 2 is complete only when the entire strategy operates reliably and all required integration tests pass.

### PHASE 3 — Integration, Research and Release

Objective: validate Flash under realistic trading conditions, evaluate the proposed gold parameters, and prepare a release candidate.

**Stage 3.1 — Automated regression testing**

Covers entry calculations, pending-order refresh, initial SL placement, trailing activation, trailing ratcheting, reversal synchronization, position sizing, combined profit targets, daily limits, session transitions, restart recovery, broker rejection and partial fills. Previously passing tests must continue to pass after later changes.

Acceptance criteria: all required regression tests pass, no unresolved critical execution or risk-control defects.

**Stage 3.2 — Historical backtesting**

Run Flash using reliable historical tick data where available, across supported timeframes. Record: total trades, win rate, average win, average loss, net expectancy, profit factor, maximum drawdown, trading costs (spread/commission/swap), reversal frequency, session performance. Backtests must use realistic broker specifications and trading costs.

Acceptance criteria: complete, reproducible reports for tested configurations, with documented data quality and limitations.

**Stage 3.3 — Gold parameter research**

Evaluate proposed entry, trailing, and spread settings by comparing reasonable parameter ranges rather than assuming initial defaults are optimal. Separate data into development and validation periods; use out-of-sample and walk-forward testing. Final configuration documented with broker, symbol, timeframe, test period, costs, and observed limitations.

Acceptance criteria: parameter-selection evidence documented, release configuration not chosen solely because it produced the highest historical profit.

**Stage 3.4 — Forward testing**

Run Flash on a demo account with the intended broker. Validate actual broker behavior: pending-order placement and cancellation, stop-loss execution, trailing modifications, reversal execution, spread changes, partial fills, connection loss, terminal restart, EA removal and reattachment, recovery with existing positions and orders. The EA must not initiate a new setup until existing exposure has been reconciled.

Acceptance criteria: forward-test evidence confirms correct execution and recovery behavior, with no unresolved critical defects.

**Stage 3.5 — Release acceptance gate**

Final release package must include: Flash EA source code, compiled EA, input documentation, strategy specification, test results, known limitations, recovery instructions, approved release configuration. Release must not proceed solely because the EA compiles or produces a profitable backtest.

Phase 3 is complete only after the release criteria are satisfied and the user authorizes deployment.

---

## PART 11 — Final Acceptance Checklist

- [ ] Phase 1: Foundation and entry engine verified
- [ ] Phase 2: Trailing and reversal engine verified
- [ ] Phase 2: Profit and risk controls verified
- [ ] Phase 3: Regression tests passed
- [ ] Phase 3: Historical tests documented
- [ ] Phase 3: Forward tests completed
- [ ] Restart and recovery behavior verified
- [ ] No unresolved critical execution defects
- [ ] Release configuration approved

No implementation or tests have been completed as of the freezing of this specification.

---

## Implementation details that still require validation

The strategy decisions above are frozen. The following are technical matters to resolve during development, not changes to the trading concept:

1. A reversal order cannot always occupy exactly the same price as a trailing SL because of broker stop restrictions. Flash must preserve the protective SL and use a valid reversal price, or disable the reversal if it cannot be placed safely.
2. The initial protective SL and the opposite pending order are two different instructions. Flash must reconcile them using actual broker fills, especially on hedging accounts.
3. The proposed behavior before trailing activates is to use the original opposite price as a protective SL without an active reversal order. This is an implementation assumption to confirm before Stage 2.2.
4. The proposed gold distances are starting configurations for testing, not statistically established optimal settings. Final defaults depend on the intended broker's specifications and Phase 3 research results.

## Final project status (as of freezing)

- Strategy specification: Frozen
- Development program: Defined
- Phase 1: Not started
- Phase 2: Not started
- Phase 3: Not started

Next development activity: Phase 1, Stage 1.1 — Project Foundation. Awaiting further instructions before starting.

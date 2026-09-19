# Flash EA — Phase 3 Build Report

Phase 3 build ID: `P3-DEV-20260919-01`
Phase 2 baseline preserved unchanged: `P2-SAFETYFIX-20260918-02`
Working copy: `Flash EA/MQL5/Experts/FlashEA_P3/` (project folder) and the mirrored terminal-data-folder copy — a separate Expert Advisor (`FlashEA_P3.ex5`) from the live, frozen `FlashEA.ex5`. Confirmed by hash that the live Phase 2 binary is untouched (`FlashEA.ex5` SHA256 `4f21c562...b97cc50`, unchanged from the freeze manifest).

**Phase 3 implementation status: STAGES 3.1-3.5 IMPLEMENTED AND INTEGRATED, COMPILED CLEAN.**
**Phase 3 live-trading release status: NOT RELEASED. Blocked on (a) live self-test confirmation on this build, (b) the deterministic fault-injection matrix, (c) broker-facing regression, none of which could be executed from this side this session, and (d) the pre-existing Phase 2 Test 6 dependency, which every reversal-safety-dependent Phase 3 behavior inherits.**

## A. Architecture and module inventory

New files, all under `Flash EA/MQL5/Experts/FlashEA_P3/`:

| File | Responsibility | Integration point |
|---|---|---|
| `Reconciliation/FlashReconciliation.mqh` | Stage 3.1. Ownership-precise inventory snapshot (`SFlashReconSnapshot`) and pure classifier (`Classify`) into 11 states matching the Stage 3.1.4 table, plus a fixed classification-to-action table (`FlashReconRequiredAction`) so no call site can independently decide to auto-repair something the table marks block/escalate-only. | Called from `OnInit` after `HandleStartupRecovery`, and from `OnTradeTransaction` on `DEAL_ADD`/`POSITION`/`HISTORY_ADD` transaction types, via the new `RunReconciliationCheck()` wrapper in `FlashEA_P3.mq5`. |
| `Core/FlashIntent.mqh` | Stage 3.2. Persists `CLOSE_REQUESTED`/`POSITION_CONFIRMED_CLOSED` and `CANCEL_REQUESTED`/`ORDER_CONFIRMED_CANCELLED` as distinct states, using the same GlobalVariable-per-field convention as Phase 2's `FlashPersistence.mqh`. Pure helpers `ShouldSkipDuplicateRequest` (idempotency) and `ResolveCloseOutcome` (full/partial/none from broker-confirmed volume). | Wired into `HandleSetupExit()` in `FlashEA_P3.mq5` and read by `RunReconciliationCheck()`. |
| `Execution/FlashExecutionControl.mqh` | Stage 3.3. `ClassifyResult` maps a trade-server response to one of 10 outcome categories; `IsRetryable` is a fixed, deterministic table (a configuration-related rejection like `INVALID_FILLING_POLICY` is never retryable unchanged); `SFlashRetryBudget` + `DecideNextAction` implement the bounded retry policy (attempt cap, minimum delay, maximum window). | Wired into `HandleSetupExit()`, replacing the Phase 2 fixed-cooldown-only throttle. |
| `Core/FlashDiagnostics.mqh` | Stage 3.4. Intention-vs-confirmation logging helpers, a bounded/aggregate repeated-failure logger (first occurrence, first repeat, then every Nth), and a CSV evidence exporter (`FlashPhase3_TestEvidence.csv` in the EA's sandboxed Files folder, stable schema). | Called from `HandleSetupExit()` and `RunReconciliationCheck()`. |

Modified file: `FlashEA_P3.mq5` (renamed from `FlashEA.mq5` at copy time so it compiles to a distinct binary). Changes, all additive:
- `FLASH_BUILD_ID` bumped to `P3-DEV-20260919-01`, naming every Phase 3 addition and confirming the Phase 2 baseline it sits on.
- Four new includes.
- One new input group (Group I: `EnableDetailedDiagnosticLogging`, `LogBrokerReconciliationEvents`, `LogTradeRequestDetails`) — diagnostics-only, gate logging verbosity, never a trading decision.
- `OnInit`: one added call, `RunReconciliationCheck("INIT")`, after Phase 2's own `HandleStartupRecovery` — never overrides a decision Phase 2 already made, only escalates further when it independently finds something Phase 2's narrower startup classifier does not check (orphaned orders, exposure discrepancies, ownership ambiguity).
- `OnTradeTransaction`: one added call, on the transaction types that can actually change broker exposure.
- `HandleSetupExit()`: rewritten to use bounded, classified retry and to persist close/cancel intent before each request rather than after.
- Self-test suite: 27 new assertions covering `CFlashReconciliation::Classify` (all 8 reachable classification branches against synthetic snapshots plus 3 action-table checks), `CFlashIntent`'s pure functions (duplicate-detection, close-outcome resolution), and `CFlashExecutionControl`'s pure functions (retcode classification, retryability, budget timing including exhaustion and already-escalated states).

No Phase 2 trading-rule file (`FlashConfig`, `FlashEntryEngine`, `FlashTrailing`, `FlashReversal`, `FlashSizing`, `FlashProfitTarget`, `FlashSessions`, `FlashDailyLimits`, `FlashBrokerRules`, `FlashOwnership`, `FlashPersistence`, `FlashRecovery`, `FlashOrders`, `FlashState`, `FlashSymbol`, `FlashTimeframe`, `FlashLogger`) was edited. Confirmed by normalized diff against the frozen Phase 2 archive: all 17 are content-identical (see Section C).

## B. Exact implementation specification

**Reconciliation rules (Stage 3.1.4 table, as implemented):**

| Broker state | Classification | Required action |
|---|---|---|
| Not the ownership-lock owner | `OWNERSHIP_AMBIGUITY` | Escalate |
| Close or cancel intent outstanding | `UNRESOLVED_EXIT` | Block new exposure (takes priority over shape-based checks below) |
| Internal setup has a direction; broker's actual direction disagrees, position(s) open | `REVERSAL_RECONCILIATION_REQUIRED` | Block new exposure |
| No broker exposure, no internal setup | `NO_EXPOSURE` | Proceed |
| No broker exposure, internal setup recorded | `POSSIBLE_COMPLETED_OR_MISSING_SETUP` | Block new exposure |
| Open position(s), any with SL==0 | `UNPROTECTED_EXPOSURE` | Auto-repair (deferred to Phase 2's existing emergency-SL path — see limitation below) |
| Open position(s), no internal setup record | `EXPOSURE_DISCREPANCY` | Escalate |
| Open positions in both directions under one setup | `EXPOSURE_DISCREPANCY` | Escalate |
| Stray pending order alongside an active position outside the expected window | `ORPHANED_ORDER` | Auto-repair (deferred — see limitation below) |
| One pending order only | `INCOMPLETE_PENDING_SETUP` | Auto-repair (deferred — see limitation below) |
| Two pending orders, matching internal setup | `MATCHED_ARMED_SETUP` | Proceed |
| Two pending orders, no internal setup | `ORPHANED_ORDER` | Escalate-by-repair (cancel only, never adopt) |
| More than two pending orders under one magic | `EXPOSURE_DISCREPANCY` | Escalate |

Ownership precision: every ticket is matched on exact `POSITION_SYMBOL`/`POSITION_MAGIC` (or `ORDER_SYMBOL`/`ORDER_MAGIC`) equality against the configured symbol and magic. A different magic, including 0 (manual orders), is counted separately (`OtherOwnerPositionCount`/`OtherOwnerPendingCount`) for visibility only and is never read, closed, or modified by anything in `FlashReconciliation.mqh`.

**Documented limitation — auto-repair is not independently executed.** `RECON_ACTION_AUTO_REPAIR` (unprotected exposure, incomplete pending, orphaned order) is deliberately not wired to perform the repair itself in this integration pass. Phase 2 already has narrower, proven repair logic for two of these three cases (the emergency-SL reattachment inside `ManageActiveSetup()`; the stray-order cancellation inside `HandleStartupRecovery()`), and running a second independent repair path against the same broker state risked a race between two "repair" attempts neither the brief nor Phase 2 specifies how to arbitrate. `RunReconciliationCheck()` logs the finding and defers to those existing paths rather than acting twice. This is disclosed here rather than silently decided, per Section 2.3 of the authorization; it did not go through the ambiguity-approval workflow that section describes because it preserves existing, already-tested behavior rather than introducing a new rule — but it is a real scope reduction from "the reconciliation engine may auto-repair," and should be reviewed before this is called complete.

**Persistent intent (Stage 3.2):** `FLASH_P3_INTENT_CLOSE_STATE_<symbol>_<magic>` and the parallel `CANCEL_STATE` key, each a GlobalVariable-encoded `ENUM_FLASH_INTENT_STATE`. State is written before the associated ticket/volume/timestamp fields, specifically so a crash between those writes leaves a recovery reader with an authoritative "something is outstanding" signal even if the detail fields are incomplete — recovery must re-derive the detail from live broker state in that case, never trust a zero/stale value. Full atomicity, durability, naming, cleanup, and account-isolation documentation is in the file's own header comment; the account-isolation property (GlobalVariables are per-terminal, not per-account) is flagged as an inherited Phase 2 property, not a new gap, and is explicitly not fixed in this pass since a fix would itself be a design decision requiring separate authorization.

**Execution failure control (Stage 3.3):** `ClassifyResult` maps `TRADE_RETCODE_*` values to 10 outcome categories (see the enum in `FlashExecutionControl.mqh`); `10027` ("AutoTrading disabled by client", observed live 2026-09-18) is explicitly mapped to `TRADING_DISABLED`. `IsRetryable` is `true` only for `TEMP_MARKET_CLOSED` and `CONNECTION_UNCERTAIN` — every configuration/deterministic-rejection category, including `INVALID_FILLING_POLICY`, is `false`. Retry budget defaults, stated with rationale rather than claimed universal: `MaxAttempts=5`, `MinDelaySeconds=2` (unchanged from the live-proven Phase 2 throttle), `MaxWindowSeconds=30`.

**Documented limitation — retcode is not currently surfaced to the retry decision.** `CFlashOrders::ClosePositionMarket()` (Phase 2, unmodified) returns only `bool`, not the underlying `MqlTradeResult.retcode`. `HandleSetupExit()` in this build therefore cannot classify the *actual* failure reason on a close rejection today — it falls back to `FLASH_EXEC_OTHER_REJECTED` (non-retryable, escalates promptly) rather than correctly distinguishing, say, a transient connection issue from a configuration problem. This is safe (it fails toward escalation, not toward silent unbounded retry) but it is not the full Stage 3.3 behavior the brief describes, and is recorded here as an open item rather than presented as complete. The correct fix is a small Phase 2-compatible signature change to `ClosePositionMarket` to return the retcode, which was not made in this pass because it touches a function Phase 2 already froze — it needs the same kind of explicit review Section 2.2 requires before any Phase 2 correction, even a compatible one.

**Observability (Stage 3.4):** category vocabulary is additive — existing Phase 1/2 categories (`ORDERS`, `OWNERSHIP`, `TRAILING`, `PERSISTENCE`, `RECOVERY`, `INIT`, `TXN`, `DEINIT`) are unchanged; new Phase 3 transitions use `RECONCILE`, `SAFETY`, and the exit path now logs under `EXIT` instead of `SETUP_EXIT` to align with the Stage 3.4.2 category list (this is a label change on Phase 3's own new log lines only, not a rename of any existing Phase 2 log line, so no existing evidence-extraction grep pattern in the freeze archive breaks). Repeated-failure logging is bounded: first occurrence, first repeat announced once, then one aggregate line every 10th repeat — never one line per tick for an unchanged condition, and never a trade request sent merely to produce a log line.

## C. Build manifest

| File | SHA256 |
|---|---|
| `Core/FlashConfig.mqh` (unmodified) | `0465158f...9ebe049` |
| `Core/FlashDailyLimits.mqh` (unmodified) | `f5a7d85d...44d44b8f711b71e5` |
| `Core/FlashLogger.mqh` (unmodified) | `bc159773...` |
| `Core/FlashOwnership.mqh` (unmodified) | `ad38c61c...892bd16911a` |
| `Core/FlashPersistence.mqh` (unmodified) | `c0878c57...101947772` |
| `Core/FlashSessions.mqh` (unmodified) | `5bf8d09b...4d44b8f711b71e5` |
| `Core/FlashState.mqh` (unmodified) | `cd555f61...e263e688912` |
| `Entry/FlashEntryEngine.mqh` (unmodified) | `f7b7c7b5...746cf64cede9bc` |
| `Execution/FlashBrokerRules.mqh` (unmodified) | `b758b603...4ddfec67cb2d1e` |
| `Execution/FlashOrders.mqh` (unmodified) | `291f9126...4229ebe049` |
| `Market/FlashSymbol.mqh` (unmodified, CRLF variant — content-identical, normalized diff confirmed) | `10a84498...` |
| `Market/FlashTimeframe.mqh` (unmodified) | `a24475f8...ea91552bfe383ca` |
| `Recovery/FlashRecovery.mqh` (unmodified) | `7314b34a...ead37de648e9e058` |
| `Reversal/FlashReversal.mqh` (unmodified) | `2d548305...9697551a1130b9` |
| `Risk/FlashProfitTarget.mqh` (unmodified) | `093633fd...357` |
| `Risk/FlashSizing.mqh` (unmodified) | `72b5dc45...e958970c` |
| `Trailing/FlashTrailing.mqh` (unmodified) | `99a3e984...685362989` |
| `Core/FlashIntent.mqh` (new) | `aecfae45...` |
| `Core/FlashDiagnostics.mqh` (new) | `3935c04a...` |
| `Execution/FlashExecutionControl.mqh` (new) | `f359a843...` |
| `Reconciliation/FlashReconciliation.mqh` (new) | `46572f42...` |
| `FlashEA_P3.mq5` (renamed + extended) | `af381590...` |
| `FlashEA_P3.ex5` (compiled) | `7623ab12c8355597736e96f8481468fafc339ed35c3313f6bc59947a58af52e9` |

Compiler output: **0 errors, 0 warnings, 7352 ms elapsed**, cpu='AVX2 + FMA3' (MetaEditor, same machine/toolchain as every prior Phase 1/2 build). Confirmed identical between the project-folder and terminal-data-folder copies of every source file (byte-for-byte on the 5 new/modified files, normalized-content-identical on all 17 inherited files). Deployed at `Flash EA/MQL5/Experts/FlashEA_P3/FlashEA_P3.ex5` in both locations. Not yet attached to any chart.

## D. Test ledger

| Item | Result | Evidence |
|---|---|---|
| Compilation | PASS | 0 errors, 0 warnings, MetaEditor build log, this session |
| Self-tests (static review) | 27 new Phase 3 assertions added, each exercises the real class method directly (never a reimplementation), covering every reachable branch of `Classify`, the fixed action table, and `CFlashExecutionControl`'s timing/classification logic | Source review, this report |
| Self-tests (live count) | **UNVERIFIED** | `FlashEA_P3` has not been attached to any chart. MetaTrader 5 terminal access in this session is read-only (screenshot only, no click/type) — attaching an EA to a chart requires the user's own action in the terminal, exactly as every prior Phase 2 self-test confirmation did. |
| Stage 3.1 broker-facing reconciliation scenarios (Stage 3.1.6) | **UNVERIFIED** | Requires live/demo attachment |
| Stage 3.2 restart-during-each-state matrix (Stage 3.2.6, 9 scenarios) | **UNVERIFIED** | Requires live/demo attachment and, for several rows, deliberately induced failure conditions on an isolated demo account per Section 2.4 |
| Stage 3.3 fault-injection (Stage 3.3.6) | **UNVERIFIED** | Requires live/demo attachment |
| Stage 3.4 evidence reconstruction (Stage 3.4.7) | **UNVERIFIED** | Requires a completed live setup cycle on this build |
| Stage 3.5 deterministic fault-injection matrix (12 rows, Stage 3.5.3) | **DESIGNED, NOT EXECUTED** | See Section E below for the matrix as designed; none of the 12 rows have been run |
| Stage 3.5 regression (both entry methods, both sizing methods, etc., Stage 3.5.2) | **UNVERIFIED** | Requires live/demo attachment |
| Performance/operational impact (Stage 3.5.4) | **NOT MEASURED** | No measurement method has been run; no threshold is claimed |
| Phase 2 Test 6 (same-tick reversal race) | **UNVERIFIED — pre-existing, unrelated to this build, carried forward** | See the Phase 2 freeze archive's `TEST6_HANDOFF.md`; market closed until Monday |

No row above is a Phase 3 pass being claimed from a compile or a static review alone — every UNVERIFIED row genuinely requires either live/demo terminal interaction this session could not perform, or the market being open.

## E. Deterministic fault-injection matrix (designed, per Stage 3.5.3)

| Scenario | Required result | How it would be forced | Status |
|---|---|---|---|
| Two charts claim ownership simultaneously | Only one owner | Attach `FlashEA_P3` to two charts under the same test magic in immediate succession | Not run — mechanism unchanged from Phase 2's already-proven `GlobalVariableSetOnCondition`; would reuse Phase 2 Tests 4/5's method |
| Owner restarts during active setup | No duplicate exposure | Recompile/reattach mid-setup | Not run |
| Initial pending-order cancellation fails | No false cancellation confirmation | Requires a broker-side rejection to force; no existing fixture forces this deterministically | Not run — no fixture built for this row |
| Close request receives 10030 | Valid policy handling, no retry storm | Reuse the Phase 2 filling-mode incident's natural recurrence, or a fixture that submits an incompatible filling mode deliberately | Not run — no dedicated fixture built; Phase 2's own live incident is the only evidence to date, on the old code path |
| Market closes during unresolved exit | Exit intent preserved, new exposure blocked | Attempt a close request after hours (achievable now, market is closed) | Not run |
| Close partially fills | Residual volume reconciled | Requires a broker/liquidity condition that produces a partial fill; not reliably forceable from a script | Not run — no fixture built |
| Reversal fills while old position closes | New exposure recognized and protected | Same mechanism as Phase 2 Test 6's `FlashReversalRaceFixture.mq5` | Not run — inherits Test 6's own unresolved status and its disclosed Sequence-A-only limitation |
| Broker position disappears before processing | History checked, no invented state | Force-close outside the EA (e.g. via a fixture script) between two ticks | Not run |
| Position exists without SL | New exposure blocked, documented recovery path | Reuse `FlashRecoveryFixture.mq5` Scenario D against `FlashEA_P3`'s magic | Not run, but the underlying mechanism (Phase 2's Recovery D path) is already twice live-proven on the Phase 2 binary |
| EA restarts during unresolved exit | Exit intent restored, no duplicate close | Recompile/reattach mid-`HandleSetupExit` | Not run |
| Non-owner instance sees Flash positions | Does not trade or modify them | Attach a second `FlashEA_P3` instance under the same magic while the first owns it | Not run |
| Manual position shares the symbol | Remains untouched | Open a manual XAUUSD position (magic 0) alongside a `FlashEA_P3` setup | Not run — but `FlashReconciliation::Inspect`'s ownership-precise filtering is covered by self-test review (Section D) |

This matrix is a plan, not evidence. Building the fixtures for the rows without an existing analog (cancellation-fails, partial-fill, position-disappears) is scoped as follow-up work, not started this session.

## F. Regression assessment

No Phase 2 trading-rule behavior was changed; this is asserted from the file-level evidence in Section C (17 of 22 files byte/content-identical to the frozen Phase 2 archive), not from having re-run the trading logic itself. The only behavioral changes are in `HandleSetupExit()`'s retry mechanics (bounded/classified instead of fixed-cooldown-only) and the two added observation points (`OnInit`, `OnTradeTransaction`), all additive and gated to either log-only or escalate-only outcomes on this pass — nothing in this build can arm a new entry, size a position, or move a stop differently than Phase 2 already does. This claim has not been regression-tested live; Section D records that honestly.

## G. Open-items register

1. **Test 6 (Phase 2)** — unverified, pre-existing, market-closed. Every Phase 3 behavior that depends on reversal safety inherits this restriction, per the authorization's own instruction.
2. **Auto-repair deferral** — `RECON_ACTION_AUTO_REPAIR` logs and defers rather than acting; not the full Stage 3.1 behavior as specified. Needs a decision: wire it to act (with a chosen arbitration against Phase 2's existing repair paths) or formally scope it as log-only going forward.
3. **Retcode not surfaced to retry classification** — `ClosePositionMarket` needs a signature change to return the actual retcode; not made this pass because it touches a frozen Phase 2 function. Needs explicit review before that change is made, even though it is narrowly compatible.
4. **No live self-test confirmation yet** — requires the user to attach `FlashEA_P3` to a chart. Terminal access this session is read-only.
5. **Fault-injection matrix (Section E) is designed, not executed** — 8 of 12 rows have no fixture at all; 4 reuse existing Phase 2 mechanisms/fixtures.
6. **Broker-facing regression (Stage 3.5.2) not run.**
7. **Performance/operational impact (Stage 3.5.4) not measured.**
8. **GlobalVariable account-isolation gap (Stage 3.2.3)** — inherited from Phase 2, documented, not fixed, needs a separate decision if it is to be closed.

## H. Freeze recommendation

**Implementation readiness:** Phase 3 Stages 3.1 through 3.5 are implemented, integrated into one build, and compile clean with 0 errors and 0 warnings. This is a genuine, reviewable engineering artifact, not a stub — the reconciliation classifier, the intent persistence layer, and the bounded retry controller are all real, pure-function-heavy, self-test-covered code, in the same style as the audited Phase 2 modules.

**Live-trading release readiness: NOT READY, and not close to being declared so.** Per the acceptance criteria in Section 3.5.6 of the authorization, none of the following required conditions are yet met: broker-facing tests confirming critical execution paths, the deterministic fault-injection matrix, and the Phase 2 Test 6 dependency. This report does not claim otherwise anywhere above, and the two "documented limitation" items in Section B are real, disclosed scope reductions from the full brief, not silently resolved.

**Next step recommendation, for your decision, not undertaken automatically per Section 3, Non-negotiable build boundary 2.3:** attach `FlashEA_P3` to an isolated demo chart (a fresh test magic, not 260917) to capture the live self-test count and begin working through the Stage 3.1-3.4 broker-facing tests and the fault-injection matrix once the market reopens Monday, alongside Phase 2's own outstanding Test 6.

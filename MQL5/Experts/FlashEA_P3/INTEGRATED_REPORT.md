# FLASH EA — INTEGRATED PHASE 1–3 BUILD AND ACCEPTANCE STATUS

Implementation: **PHASES 1–3 INTEGRATED — BUILD VERIFICATION IN PROGRESS**
Release: **NOT RELEASED — MANDATORY SAFETY AND BROKER-FACING TESTS PENDING**

Current integrated development build: `P3-DEV-20260919-01`
Frozen rollback baseline: `P2-SAFETYFIX-20260918-02` (unchanged, archived, currently deployed live — not touched by anything below)

Flash EA is one EA, one strategy, one codebase. The numbers below name development milestones, not products. This report inspects the actual source that exists today rather than restating the earlier Phase 3 announcement.

## 1. Canonical source verification

Inspected the actual tree at `Flash EA/MQL5/Experts/FlashEA_P3/` (both the project-folder copy and the terminal-data-folder copy, confirmed identical by hash) rather than assuming the earlier report's description still held.

**Confirmed: this tree already contains the complete Phase 1 + Phase 2 + Phase 3 implementation — one entry point, no duplicates.**

- One `.mq5` entry point: `FlashEA_P3.mq5`, defining `OnInit` (line 1520), `OnTick` (1677), `OnTradeTransaction` (1770), `OnDeinit` (1799) — each exactly once.
- 21 `.mqh` module files: the 17 inherited Phase 1/2 modules plus the 4 new Phase 3 modules (`FlashReconciliation.mqh`, `FlashIntent.mqh`, `FlashExecutionControl.mqh`, `FlashDiagnostics.mqh`).
- Checked every class name defined across the tree (`grep "^class C"`): every class appears exactly once. No duplicate or shadow implementation of any trading function exists.
- No leftover dead code from the pre-Phase-3 retry mechanism: the old fixed-cooldown-only static guard (`s_lastSetupExitAttempt`) no longer appears anywhere in the file; it was fully replaced, not left alongside the new controller.

**This working copy is, as of today, the one authoritative current development version of Flash EA.** It is not a second product and nothing about its trading logic diverges from Phase 2's. It remains physically separate from the live-deployed `FlashEA/FlashEA.ex5` for one reason only: that binary is the frozen Phase 2 baseline Test 6 must still be run against, and Section 6 below requires that exact binary to stay reachable and unmodified until Test 6 is resolved. The "_P3" suffix on the working-copy folder and binary name is a leftover of the safe build process (so it could never collide with the live deployment while being built), not a claim that it is a separate EA — I'm not proposing to operate two Flash products, and the acceptance matrix in Section 4 already treats this as one project.

## 2. Runtime integration — verified by call-site inspection, not by compile success alone

Per your instruction, a clean compile only proves the new modules exist and type-check; it does not prove they are on the execution path. I greped the actual call sites.

**Confirmed genuinely wired into the live execution path:**
- `RunReconciliationCheck()` (Stage 3.1) is called from `OnInit` (after Phase 2's own `HandleStartupRecovery`) and from `OnTradeTransaction` on `DEAL_ADD`/`POSITION`/`HISTORY_ADD` transactions — not just declared, actually invoked at both points.
- `HandleSetupExit()` — the function directly responsible for the original 1,418-retry incident — now calls `CFlashIntent::RequestClose/ConfirmClosed/ResolveCloseOutcome`, `CFlashExecutionControl::RecordAttempt/DecideNextAction/IsRetryable/LogDecision`, and `CFlashDiagnostics::LogActionRequested/LogReconciledVolume/LogRepeatedFailure/LogFinalConfirmation`. This is a real behavioral change on a real, previously-incident-causing path, confirmed at source lines 1229-1333, not merely present in the file.

**Confirmed NOT yet wired — genuine integration gap, disclosed rather than hidden:**
- `ReconcileReversal()` (the function that closes remaining old-direction exposure during a reversal) still calls `CFlashOrders::ClosePositionMarket()` directly, on every tick while in `REVERSAL_RECONCILING`, with **no retry budget or throttle of any kind** — this is unmodified Phase 2 behavior, and it is the same class of risk that caused the original incident, on a different call site. Stage 3.3's brief requires a bounded retry policy for "each operation type"; this operation type does not have one yet.
- `ArmReversalOrder()` is called every tick from `ManageActiveSetup()` whenever `ReversalPendingTicket == 0` and eligibility conditions hold. If `CFlashOrders::SendPendingOrder()` fails there, it is retried again next tick with no budget, no backoff, and no escalation path — the ticket simply stays 0 and it tries again. Also unmodified Phase 2 behavior, also in Stage 3.3's stated scope, also not yet covered.
- The two-sided initial entry (`SendPendingOrder` for the Buy Stop / Sell Stop pair) is a one-shot call on a state transition, not re-entered every tick the way the two paths above are — lower risk, but also not wrapped by the new controller.

**I did not extend the wiring to these three paths in this pass.** Doing so under the current time pressure, on a live-money-adjacent EA, without first getting your explicit go-ahead on scope, is exactly the kind of unilateral change Section 2.3 of your authorization tells me not to make. I'm reporting the gap precisely so you can decide whether to authorize extending the same bounded-retry pattern to these two tick-looped call sites before this build is regarded as safety-complete, rather than quietly patching it myself or quietly leaving it out of the report.

## 3. Preserved trading rules

No formula, threshold, or decision rule changed. All 17 inherited Phase 1/2 files are confirmed content-identical to the frozen Phase 2 archive (hash-matched, with the one known CRLF-only line-ending variant on two files re-confirmed normalized-identical this session). Entry distances, the previous-candle calculation, the protective-stop formula, trailing activation/ratchet, reversal eligibility and the protective-stop-for-new-direction formula, lot sizing, the setup profit target, session windows, and daily limits are all byte-for-byte the same code Phase 2 froze.

The only behavioral change anywhere in this build is `HandleSetupExit()`'s retry mechanics (Section 2), plus the two new observation-only hooks (`OnInit`, `OnTradeTransaction`) which log and can escalate to `RECOVERY_REQUIRED` but cannot open, size, or arm anything. This is an infrastructure correction, not a trading-rule change — it changes *how persistently and how observably* a close is retried, never *what* gets traded or *when* an entry/exit signal fires.

## 4. Consolidated acceptance matrix

One matrix, Phase 2 history preserved, Phase 3 rows added, no result transferred automatically across builds.

| # | Feature / scenario | Tested build | Evidence type | Expected | Actual | Result |
|---|---|---|---|---|---|---|
| 1 | Compilation | P3-DEV-20260919-01 | Build log | 0 errors/0 warnings | 0 errors/0 warnings, 7352ms | PASS |
| 2 | Self-test suite (static source review) | P3-DEV-20260919-01 | Source review | All 27 new assertions logically sound against pure functions | Confirmed by review | PASS (review only) |
| 3 | Self-test suite (live Journal count) | P3-DEV-20260919-01 | Broker-facing (attach) | Live TOTAL/PASSED/FAILED line | Not yet attached | **UNVERIFIED** |
| 4 | Recovery A (valid pending pair) | P2-SAFETYFIX-20260918-02 | Broker-facing fixture | Adopt without duplicating | PASS (magic 999002) | PASS on P2; not yet regressed on integrated build |
| 5 | Recovery C (incomplete pending) | P2-SAFETYFIX-20260918-02 | Broker-facing fixture | Cancel stray order | PASS (magic 999003) | PASS on P2; not yet regressed on integrated build |
| 6 | Recovery D (unprotected position) | P2-SAFETYFIX-20260918-02 | Broker-facing fixture | Block entries, no invented SL | PASS x2 (magic 999001/999002) | PASS on P2; not yet regressed on integrated build; **also independently reconfirmed live today (2026-09-19) on the real magic 260917 on the deployed P2 binary** |
| 7 | Ownership conflict (later arrival blocked) | P2-SAFETYFIX-20260918-02 | Broker-facing | Single owner enforced | PASS, with same-tick-race caveat | PASS on P2; not yet regressed on integrated build |
| 8 | Ownership shutdown/restart/handoff | P2-SAFETYFIX-20260918-02 | Broker-facing | Clean handoff, no double-claim | PASS, with stale-timeout caveat | PASS on P2; not yet regressed on integrated build |
| 9 | Filling-mode correction (retcode 10030) | P2-SAFETYFIX-20260918-02 | Broker-facing | No retry storm, resolves via fallback | PASS, confirmed live under original failure condition | PASS on P2; carried into the integrated build unmodified (same `FlashOrders.mqh`), not yet independently regressed |
| 10 | Entry engine / trailing regression | P2-SAFETYFIX-20260918-02 | Incidental live evidence | No defects across 6 setup cycles | PASS (incidental, not isolated) | PASS on P2; not yet regressed on integrated build |
| 11 | Test 6 — same-tick reversal race, ORIGINAL frozen Phase 2 build | P2-SAFETYFIX-20260918-02 | Broker-facing, deterministic fixture | Reversal detected/attributed/protected correctly under both transaction orderings | Not run | **UNVERIFIED — MANDATORY, run this build FIRST, exactly as frozen** |
| 12 | Test 6 — corresponding regression on integrated build | P3-DEV-20260919-01 | Broker-facing, deterministic fixture | Same acceptance criteria, on the integrated binary | Not run | **UNVERIFIED — run only after #11**, per Section 6 |
| 13 | Stage 3.1 reconciliation classification (synthetic) | P3-DEV-20260919-01 | Self-test (deterministic, no broker) | All 8 classification branches + 3 action-table checks correct | Confirmed by source review; not yet run live | PASS (review only) — needs live self-test count (#3) to become PASS (executed) |
| 14 | Stage 3.1 reconciliation vs real broker inventory | P3-DEV-20260919-01 | Broker-facing | Correct classification against live positions/orders, ownership-precise (never adopts a different-magic or magic-0 position) | Not run | **UNVERIFIED** |
| 15 | Stage 3.2 persistent intent — 9-scenario restart matrix | P3-DEV-20260919-01 | Broker-facing, isolated demo | Idempotent recovery, no duplicate requests, correct partial-close reconciliation | Not run | **UNVERIFIED** |
| 16 | Stage 3.3 bounded retry — `HandleSetupExit` path | P3-DEV-20260919-01 | Deterministic fault injection | Bounded attempts, no storm, correct escalation | Not run | **UNVERIFIED** |
| 17 | Stage 3.3 bounded retry — `ReconcileReversal` / `ArmReversalOrder` paths | — | — | Not applicable yet | Not wired (Section 2) | **BLOCKED — pending your decision on wiring scope** |
| 18 | Stage 3.4 evidence reconstruction | P3-DEV-20260919-01 | Broker-facing, one full setup cycle | Reconstructable from logs, intention vs confirmation distinguished | Not run | **UNVERIFIED** |
| 19 | Stage 3.5 fault-injection matrix (12 scenarios) | P3-DEV-20260919-01 | Mixed, deterministic where possible | See the earlier Phase 3 report's Section E | 4 of 12 have a reusable existing mechanism; 8 need a new fixture, none built | **UNVERIFIED / NOT STARTED** |
| 20 | Full lifecycle regression (Section 8 of your instruction) | P3-DEV-20260919-01 | Broker-facing, one coordinated run | Entry through next-eligible-setup, no defects | Not run | **UNVERIFIED** |
| 21 | No-simultaneous-exposure procedure (Section 7) | — | Procedural | Documented and to be followed when testing resumes | See Section 6/7 below | Procedure defined; not yet exercised |

## 5. What was completed now, offline, while the market is closed

- Canonical source-tree verification (Section 1).
- Integration and call-path inspection (Section 2) — this is the substantive finding of this pass, not a formality.
- Build-manifest re-verification: same hashes as the earlier Phase 3 report, since no source changed this session; restated in Section 1's referenced files, not duplicated here.
- Static review of every trading-request call site in `FlashEA_P3.mq5` (Section 2's grep-verified list).
- Trading-rule preservation check (Section 3) — content-identity re-confirmed, not merely asserted.
- Test-fixture safety review: `FlashRecoveryFixture.mq5` and `FlashReversalRaceFixture.mq5` were re-read against their existing safety guards (demo-only check, symbol/magic match required, refuses if a position/order already exists under the test magic) — unchanged since the freeze archive, still sound, no new fixture was built this pass.
- This consolidated acceptance matrix and report (Section 4).

Nothing above required MT5 attachment, and nothing above is claimed as more than what it is — several rows explicitly say "review only," not "executed."

## 6. Test 6 sequencing — done correctly this time

Per your instruction, Test 6 will be run in this exact order, not skipped or substituted:

1. **First**, attach the exact frozen `P2-SAFETYFIX-20260918-02` binary (the currently deployed one) and run `FlashReversalRaceFixture.mq5` against it per `TEST6_HANDOFF.md` in the freeze archive. This answers "was the original Phase 2 correction actually verified" — and only this run may be recorded as Phase 2's Test 6 result.
2. **Afterward**, run the corresponding reversal/reconciliation regression against the integrated `P3-DEV-20260919-01` binary. This answers "does the integrated EA preserve and strengthen that behavior" — recorded separately, row #12 above, never merged into row #11's result.
3. If step 1 exposes a defect, the correction is made in the canonical integrated tree (this one), gets a new build ID, and the original frozen Phase 2 archive is preserved unmodified with its accurate (failing) Test 6 result recorded — never silently revised.

## 7. Exact steps for you to perform in MT5 (I cannot do these — read-only terminal access)

**Step A — resolve the open safety item first, at your discretion (already accepted as-is per your last message, no action required unless you change your mind).**

**Step B — when you are ready to get the first live signal on the integrated build (self-test count, Section 4 row #3), and only on an isolated demo setup:**
1. Use a chart and magic number that is **not** 260917, to avoid any collision with the live Phase 2 instance's persisted GlobalVariables and ownership lock (Stage 3.2's own account/key-isolation caveat applies here directly — reusing 260917 would let the two builds read and write the same persisted keys). Suggested: a fresh test magic, e.g. `999010`.
2. Do not have any Phase 2 (`FlashEA`) chart attached under that same test magic at the same time — Section 7 of your instruction; sequential, not simultaneous, on the same symbol/magic.
3. Open a new XAUUSD chart (any timeframe), drag `FlashEA_P3.ex5` from Navigator onto it.
4. In the Inputs tab, set `Flash Trade Identification Number` to the test magic from step 1 (999010 or your choice), leave every other input at default, and confirm `Enable Phase 1 and Phase 2 Self-Test Suite` is on.
5. Expected initial behavior on attach: a Journal `[FLASH][INIT]` line showing `build=P3-DEV-20260919-01`, a self-test completion line reading `FLASH PHASE 1 + PHASE 2 + PHASE 3 SELF-TEST SUITE COMPLETE | TOTAL: ... | PASSED: ... | FAILED: 0`, a `[FLASH][RECOVERY] Snapshot` showing no exposure under the test magic (assuming none exists there), and the EA settling into `WAITING_FOR_ENTRY`.
6. Do not remove this chart until I've re-accessed the logs and confirmed the count — tell me once it's attached and I'll pull the Journal.

Nothing else needs your action right now. Test 6 and the rest of the broker-facing matrix wait for XAUUSD to reopen.

## 8. Open items carried forward

1. Wiring decision needed: extend Stage 3.3's bounded retry to `ReconcileReversal()` and `ArmReversalOrder()` (Section 2) before this build is called safety-complete, or explicitly accept the gap for now — your call, not mine to make unilaterally.
2. Live self-test confirmation on the integrated build (Section 7, Step B).
3. Test 6 on the frozen Phase 2 build, then the integrated build, in that order (Section 6).
4. The remaining Stage 3.1-3.5 broker-facing tests and fault-injection matrix (Section 4, rows 14-20).
5. The accepted, deferred, unprotected-position item on magic 260917 — separate from this build, status unchanged (risk accepted by you, no reminders).

## Final status restated

Implementation: **PHASES 1–3 INTEGRATED — BUILD VERIFICATION IN PROGRESS**
Release: **NOT RELEASED — MANDATORY SAFETY AND BROKER-FACING TESTS PENDING**

This build has never been attached to MT5. Nothing above claims otherwise.

# Flash EA — Phase 3 Baseline Freeze Manifest

Build ID: P3-DEV-20260919-01
Freeze date: 2026-09-19
Archive location: `Flash EA/_freeze/Phase3_P3-DEV-20260919-01/` (inside the user's connected OneDrive project folder)

Development status: IMPLEMENTATION FROZEN — FINAL VERIFICATION PENDING
Release status: NOT RELEASED — MANDATORY SAFETY TESTS OUTSTANDING

## 1. What this archive is

This is the current integrated Flash EA source and compiled binary, frozen as the go-forward baseline per explicit instruction. It contains Phases 1, 2, and 3 in one codebase, one entry point (`FlashEA_P3.mq5`), one deployable EX5. It is not a separate product from Phase 2; Phase 2's own archive (`Phase2_P2-SAFETYFIX-20260918-02/`) is retained separately, solely for its own historical Test 6 obligation and evidence, and is not modified by this freeze.

No further feature development, module additions, architecture changes, or trading-parameter changes are authorized against this baseline while tests remain outstanding. Any correction found necessary during remaining verification requires a new build ID and a new archive, per Section 6 of the freeze directive — not a silent edit here.

## 2. Source-produced-this-EX5 verification

The `.ex5` in this archive (`FlashEA_P3.ex5`, SHA256 `7623ab12c8355597736e96f8481468fafc339ed35c3313f6bc59947a58af52e9`) and the 22-file source tree were copied directly from the terminal data folder's `MQL5/Experts/FlashEA_P3/` on 2026-09-19, the same tree that produced the compile event recorded in `PHASE3_BUILD_REPORT.md` (0 errors, 0 warnings, 7352 ms) and the live self-test run captured in this session's Journal (`TOTAL: 131 | PASSED: 131 | FAILED: 0`, 18:56:14.459). Hashes were re-verified against the terminal-data-folder copy at freeze time and match the earlier build-report hashes exactly — no source drift since compile.

## 3. Source inventory and hashes (SHA256)

See `source_hashes.txt` in this archive folder for the full 22-file listing (21 `.mqh` + 1 `.mq5`) plus the compiled `.ex5`. Two files, `Core/FlashLogger.mqh` and `Market/FlashSymbol.mqh`, hash differently from the Phase 2 archive's canonical copies; re-verified this session via `diff` after CRLF normalization (`tr -d '\r'`) against the live Phase 2 `FlashEA/` tree and confirmed normalized-identical — this is the same disclosed line-ending artifact recorded in the Phase 2 `MANIFEST.md`, not a functional divergence.

## 4. Compiler output and self-test result preserved

- Compilation: 0 errors, 0 warnings, 7352 ms (MetaEditor build event, `PHASE3_BUILD_REPORT.md`).
- Self-test suite: **131/131 passed, 0 failed** — live Journal line, `20260919.log`, 18:56:14.459, chart 50247044578520, captured verbatim in `evidence/attach_20260919_key_lines.txt` in this archive.
- Initial reconciliation execution (observed case): classified the existing exposure `UNPROTECTED_EXPOSURE`, action `RECON_ACTION_AUTO_REPAIR`, and correctly deferred to the existing Phase 2 repair path rather than acting twice — logged verbatim in the same evidence extract.
- Entry blocking on the detected unprotected exposure: state transitioned `INITIALIZING -> RECOVERY_REQUIRED`, new entries blocked — confirmed in the same extract.

These four items are the only rows in the consolidated acceptance matrix currently supported by live evidence against this exact build. Every other row remains PENDING or BLOCKED per Section 3 below — no result is transferred from Phase 2 without its own regression on this build, and no PENDING row is being reported as passed.

## 5. Known, unresolved safety limitation — carried forward, not closed by the 131/131 result

`ReconcileReversal()` and `ArmReversalOrder()` in `FlashEA_P3.mq5` were re-inspected directly against the frozen source at freeze time (not re-asserted from memory):

- `ReconcileReversal()` still calls `CFlashOrders::ClosePositionMarket()` directly, on every tick while in `REVERSAL_RECONCILING`, with no retry budget, no throttle, and no `CFlashExecutionControl`/`CFlashIntent` involvement.
- `ArmReversalOrder()` still calls `CFlashOrders::SendPendingOrder()` directly on every eligible tick, same absence of bounded retry.

**This is confirmed still present in the exact frozen build.** The 131/131 self-test pass does not exercise either call site's retry behavior under a live rejection — the self-tests validate `CFlashExecutionControl`'s classification and decision logic as pure functions, not whether these two functions actually call it, and they do not. This remains an open, disclosed safety limitation, not a resolved item, and full release readiness cannot be claimed while it stands. Resolving it is explicitly out of scope for this freeze (Section 6 of the freeze directive: correction requires separate authorization, a new build ID, and targeted regression — not a silent patch here).

## 6. Archive contents

```
Phase3_P3-DEV-20260919-01/
  FlashEA_P3.ex5                    compiled binary, canonical
  P3_FREEZE_MANIFEST.md             this file
  source_hashes.txt                 SHA256 for all 22 source files + ex5
  source/                           22 source files, terminal-data-folder canonical copies
  evidence/
    attach_20260919_key_lines.txt   build-ID, self-test completion, and reconciliation lines from today's live attach
```

## 7. Immutability declaration

Same practical caveat as the Phase 2 archive: this lives on a OneDrive-synced Windows filesystem with no OS-level write-lock applied. Immutability here is a procedural commitment recorded in this manifest and the project tracker, not a technical guarantee.

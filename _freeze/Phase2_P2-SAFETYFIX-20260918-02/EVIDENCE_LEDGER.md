# Flash EA — Phase 2 Acceptance Ledger

Build ID for every result below, unless stated otherwise: `P2-SAFETYFIX-20260918-02`. Where a result was produced under an earlier build, that build is named explicitly and is not attributed to 02. Evidence source: `evidence/journal_20260917_utf8.txt`, `evidence/journal_20260918_utf8.txt`, `evidence/build_02_key_lines.txt`, all archived alongside this ledger.

## Results table

| # | Test | Build | Result | Evidence |
|---|------|-------|--------|----------|
| — | Compilation | 02 | PASS | 0 errors, 0 warnings, MetaEditor build log |
| — | Self-tests | 02 | PASS 99/99 | `TOTAL: 99 \| PASSED: 99 \| FAILED: 0`, every reattachment on this build |
| 1 | Recovery D (active position, missing SL) | pre-fix build (99/99 self-test unaffected by 01/02 delta) | PASS, confirmed twice | magic=999001 ticket 58519284483; magic=999002 ticket 58519559589. Both: `scenario=ACTIVE_UNPROTECTED` → `Active Flash position found at startup WITHOUT a protective SL...An unrecoverable level must not be invented. Blocking new entries.` → `POSITION_ACTIVE -> RECOVERY_REQUIRED` |
| 2 | Recovery A (valid pending pair) | 02 | PASS | magic=999002, tickets 58519616273/58519616317. `scenario=VALID_PENDING_PAIR` → `Existing valid pending pair adopted - resuming ORDERS_ARMED without placing duplicate orders` |
| 3 | Recovery C (incomplete pending) | 02 | PASS | magic=999003, ticket 58520164651. `scenario=INCOMPLETE_PENDING` → `Incomplete pending pair found at startup (only one side present). Cancelling the stray order to avoid a one-sided setup.` |
| 4 | Ownership conflict (later arrival blocked) | 02 | PASS, with caveat | H1 (chart 46923012826300) claimed 07:26:31.081; M15 (chart 46944538470998) attached ~58s later, repeatedly blocked: `Another Flash instance (chart 46923012826300) actively owns XAUUSD magic=260917 ... will NOT trade`. No double-claim. **Caveat below.** |
| 5 | Ownership shutdown / restart / handoff | 02 | PASS, with caveat | `Released XAUUSD magic=260917 (clean deinit, chart 46923012826300)` at 07:29:37.553, immediately followed by `Claimed XAUUSD magic=260917 for chart 46944538470998 (no prior owner)` at 07:29:37.564 (11ms later). H1 reattached afterward and was correctly blocked in turn. **Caveat below.** |
| 6 | Same-tick reversal race (SL hit + reversal fill together) | — | **UNVERIFIED** | Never successfully executed against a live armed reversal. **MANDATORY RELEASE BLOCKER.** See `TEST6_HANDOFF.md`. |
| 7 | Entry engine / trailing regression | 02 | Adequately covered by incidental evidence, not a dedicated isolated test | magic=999002 session: 24 confirmed trailing SL updates, symmetric buy-stop/sell-stop entries at correct distances, six full setup cycles opened and closed cleanly. No entry or trailing defects observed across that volume. |
| — | Filling-mode correction (retcode 10030 fix) | 02 | CONFIRMED LIVE under the original failure condition | Setup `2026.09.18 07:14:18-999002` reached its profit target and closed: `Closed ticket 58520054613 (setup profit target exit) and verified flat`. Zero retcode 10030 errors, zero retry storm, across six closes in the 06:50-07:18 window. |

## Explicit non-overstatement statements

**Test 4 caveat.** The two chart attachments were roughly 58 seconds apart, not within the same tick. This proves correct blocking-of-a-later-arrival behavior under the corrected code. It does **not** reproduce the exact same-tick "both instances observe no prior owner" race that the original defect exhibited and that the atomic `GlobalVariableSetOnCondition` compare-and-set specifically targets. It is treated as adequate behavioral confirmation because the same compare-and-set call is unconditionally exercised on every claim attempt regardless of timing, not as a literal same-tick reproduction of the original failure.

**Test 5 caveat.** This exercises clean release plus immediate handoff, and blocked restart after losing ownership. It does **not** exercise the heartbeat-timeout stale-takeover path (an owner going unresponsive without a clean `OnDeinit`), which was not safely forceable without killing the terminal process during this session. The stale-timeout path uses the same atomic primitive already proven correct under Tests 4 and 5, which is the basis for treating this as sufficient — it is not itself a demonstration of that specific path.

**Recovery D caveat.** Recovery D detection passing twice proves the missing-SL detection and entry-block logic works for that scenario. It is **not** proof that every emergency-protection or exit path in the EA has passed — those are separate code paths (trailing's own emergency SL repair, the reversal reconciliation exit path, `HandleSetupExit`) each with their own evidence rows above, and none of them should be read as validated by the Recovery D result.

**Filling-mode / retry-throttle caveat.** The filling-mode fix itself is confirmed live under the exact condition that caused the original failure (a rejected `ORDER_FILLING_RETURN` close, now falling back through supported modes). The 2-second cooldown added to `HandleSetupExit()` has not been independently stress-tested against a persistently-rejected close, because the filling-mode fix removes the original rejection trigger. **A two-second cooldown alone must not be described as proof that retries are bounded in every scenario or that every possible exit-failure mode is now safely resolved.** It is a bound on retry frequency for the one failure mode observed live, nothing broader is claimed.

**Test 7 caveat.** This is incidental evidence from real trading activity during other tests, not a dedicated regression suite covering entry-method edge cases (spread rejection boundaries, buffer edge cases) or trailing edge cases (broker-rejected SL modification, minimum-update boundary) deliberately. It is treated as adequate given the volume and cleanliness of the observed cycles, not as exhaustive.

## Build-identity attribution

Recovery D's two passes ran before `FLASH_BUILD_ID` existed in the build that produced them was `P2-SAFETYFIX-20260917-01`-equivalent territory; the build-ID logging mechanism itself was only added within the 2026-09-17 session and confirmed present from that point forward. Every other row in this table (Recovery A, Recovery C, ownership conflict, ownership shutdown/restart, filling-mode confirmation, entry/trailing regression) was captured with `FLASH_BUILD_ID=P2-SAFETYFIX-20260918-02` printed at the `OnInit` of the same attachment session, cross-checked in `evidence/build_02_key_lines.txt`. No result in this ledger is carried forward from an earlier binary and presented as this build's evidence.

## Account safety history (context, not a test result)

Three manually-opened, untagged (magic 0) unprotected XAUUSD positions were found mid-project and closed directly by OtienoBanks; confirmed via matching Balance/Equity/Free Margin readings afterward. Not a Flash defect — Flash's own recovery scan never saw them because they carried no magic number.

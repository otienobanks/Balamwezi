# Flash EA — Phase 2 Freeze Manifest

Build ID: P2-SAFETYFIX-20260918-02
Freeze date: 2026-09-19
Archive location: `Flash EA/_freeze/Phase2_P2-SAFETYFIX-20260918-02/` (inside the user's connected OneDrive project folder)

Development status: PHASE 2 IMPLEMENTATION FROZEN
Live-trading release status: NOT YET RELEASED — TEST 6 PENDING

## 1. What this archive is

This is an immutable snapshot of the exact source tree that produced the compiled `FlashEA.ex5` currently deployed on the demo account (5052807620, MetaQuotes-Demo, Hedge). The canonical source, for hashing purposes, is the copy that lived in the real MT5 terminal data folder (`D0E8209F77C8CF37AD8BF550E51FF075/MQL5/Experts/FlashEA/`) at the moment of freeze, because that is the copy MetaEditor actually compiled. Nothing in this archive is to be edited after this point. Any correction or next-phase change is a new build with a new build ID and a new archive.

## 2. Source-produced-this-EX5 verification

The `.ex5` in this archive (`FlashEA.ex5`, SHA256 `4f21c5623ea20bae85007370144caac8d9b23482f5d753369e1f24824b97cc50`) was copied directly from the terminal data folder's `MQL5/Experts/FlashEA/FlashEA.ex5` after the live recompile that followed the filling-mode and retry-throttle fix. That recompile's build event was confirmed by the terminal auto-detaching and reattaching the EA, re-running the 99/99 self-test suite, and logging `build=P2-SAFETYFIX-20260918-02` on `OnInit`, all captured in `evidence/build_02_key_lines.txt`. The `.mq5`/`.mqh` files in `source/` are the same terminal-data-folder files, copied at the same time, and their hashes are cross-checked below. This is direct file-copy provenance (same folder, same timestamp window), not a rebuild-and-compare — a rebuild-and-compare was not performed and is not claimed here.

## 3. Source inventory and hashes (SHA256)

Canonical hashes, terminal-data-folder copy (this is what compiled):

```
0465158fb7f80a348075940b349cab8ce6b4c7b7e203e0d653e43a63b7dfe06f  source/Core/FlashConfig.mqh
f5a7d85d3e2ba1027d8499a591b05a4cadd6ca9248fe05910625597bc4560bab  source/Core/FlashDailyLimits.mqh
7f70cc88a862f35905eb25b92f10d6fb49a7bddf4b5aaf39697dc2498020734e  source/Core/FlashLogger.mqh
ad38c61cdec966949b1833b74944845671f8be5577ec18c91e40d892bd16911a  source/Core/FlashOwnership.mqh
c0878c579d9b569b1c91fd7f4baab1db69cc981e6c7bf8c328ea5c0101947772  source/Core/FlashPersistence.mqh
5bf8d09bbd7c30e21de8bf7dc944becc015a97f8b8e24fb534d44b8f711b71e5  source/Core/FlashSessions.mqh
cd555f6116238642748ac893c8394b70b1a13390efb57a7e45380e263e688912  source/Core/FlashState.mqh
f7b7c7b5484b229c64f7bceb7e03ca617b5515f08f74d2de71746cf64cede9bc  source/Entry/FlashEntryEngine.mqh
b758b6033ebc901d23225d0b88ad0855b6018e5a1d014bbaab4ddfec67cb2d1e  source/Execution/FlashBrokerRules.mqh
291f9126ce7c4b24f35e220425fbeb0c3ff3a2394f1a3c67ab4ff04229ebe049  source/Execution/FlashOrders.mqh
6de2adef09dd04a91a5acdf7a634dc9aa49d8debfef2af67cb96952d431abe57  source/FlashEA.mq5
6b6e48967ed32c6db890aff0945336da92f610423f4f919947006c5af010e858  source/Market/FlashSymbol.mqh
a24475f80a0fed242019d04861757b41fb46e75dc835abab2ea91552bfe383ca  source/Market/FlashTimeframe.mqh
7314b34a2a32feef5381c8ed6e853ac0aee8302eed2f3032ead37de648e9e058  source/Recovery/FlashRecovery.mqh
2d548305ede5f29ff9d6c1f72f51aa4c37a9a7939fb3005b8e9697551a1130b9  source/Reversal/FlashReversal.mqh
093633fd6693d35401a4325ae03f9fe5dcc499e27a7ee6c597789100fdf0e357  source/Risk/FlashProfitTarget.mqh
72b5dc45edc6bb98d1816a05ab7937c597d873632bb8c0b378444a26e958970c  source/Risk/FlashSizing.mqh
99a3e984866735b7e1d040ac47fdc9f40654ae2268cf63df57fecd3685362989  source/Trailing/FlashTrailing.mqh
4f21c5623ea20bae85007370144caac8d9b23482f5d753369e1f24824b97cc50  FlashEA.ex5
```

18 source files (17 `.mqh` + 1 `.mq5`) plus the compiled `.ex5`. This is every Phase 1 dependency and every Phase 2 module required to reproduce the build; no module was left out of the archive.

## 4. Known discrepancy — disclosed, not silently resolved

While cross-checking the terminal-data-folder copy against the synced OneDrive project-folder copy (the two places this project's source exists on the user's machine), two files hashed differently between the two copies:

- `Core/FlashLogger.mqh`
- `Market/FlashSymbol.mqh`

Investigated directly rather than assumed identical, per instruction. `file` showed the terminal copy has CRLF line terminators and the project copy does not. Running `diff` on both copies after stripping `\r` with `tr -d '\r'` returned exit code 0 (byte-identical once line endings are normalized). Conclusion: this is a line-ending artifact from how the two folders were synced/edited, not a functional code divergence — the two copies compile to the same logic. The hashes recorded above and used as canonical are the terminal-data-folder copy's hashes, since that is the literal file MetaEditor compiled; the project-folder copy's differing hashes are not used anywhere in this manifest or the evidence ledger.

## 5. Compiler output and self-test result preserved

- Compilation: 0 errors, 0 warnings (confirmed at the build event captured in `evidence/build_02_key_lines.txt`).
- Self-test suite (`EnablePhase1SelfTest`): 99/99 passed at that same `OnInit`, logged and captured in the same evidence extract.

## 6. Archive contents

```
Phase2_P2-SAFETYFIX-20260918-02/
  FlashEA.ex5                              compiled binary, canonical
  MANIFEST.md                              this file
  SPECIFICATION.md                         Stage 2.1-2.5 spec, from source
  EVIDENCE_LEDGER.md                       test-by-test acceptance record
  TEST6_HANDOFF.md                         deferred-test procedure
  source/                                  18 source files, terminal-data-folder canonical copies
  test-archive/
    FlashRecoveryFixture.mq5 / .ex5        Recovery A/C/D forcing fixture
    FlashReversalRaceFixture.mq5 / .ex5    Test 6 forcing fixture
  evidence/
    journal_20260917_utf8.txt              full UTF-8 Journal, 2026-09-17 (69,302 lines)
    journal_20260918_utf8.txt              full UTF-8 Journal, 2026-09-18 (23,450 lines)
    build_02_key_lines.txt                 filtered extract: build-ID lines, self-test completion, RACEFIXTURE lines, every ticket referenced in testing
```

## 7. Immutability declaration and its practical limits

This archive is designated immutable as of 2026-09-19: no file inside it is to be overwritten, and any future correction or next-phase change produces a new build ID and a new sibling archive folder rather than a modification here. Practical caveat, stated honestly rather than assumed: this folder lives on a OneDrive-synced Windows filesystem reached through a device bridge, and no filesystem-level write-lock or permission restriction has been applied to it — nothing in this environment can force-enforce immutability at the OS level. Immutability here is a procedural commitment (recorded in this manifest and in the project tracker) rather than a technical guarantee. If the user wants a harder guarantee, a read-only attribute or a zipped/checksummed copy stored outside the working tree would be the next step, and has not been done.

## 8. Traceability note

Every test result attributed to this build in `EVIDENCE_LEDGER.md` is checked against the `FLASH_BUILD_ID` string logged at that test's `OnInit` in the Journal, not assumed from timing alone. Where a test ran under an earlier build (pre-fix), that is stated explicitly rather than folded into this build's results.

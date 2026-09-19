//+------------------------------------------------------------------+
//|                                                      FlashEA.mq5 |
//|                Flash EA - Phase 2 (Stages 2.1 - 2.5)              |
//|                                                                    |
//| Direction-neutral two-sided pending-entry system for XAUUSD, now  |
//| extended with a trailing stop engine, opposite-direction reversal |
//| execution, position sizing (fixed lot or percentage-of-equity     |
//| risk per setup), a combined setup net profit target, daily        |
//| realized profit/loss limits, and Kenya-time (EAT, UTC+3) trading   |
//| session windows. This file coordinates the module classes below;  |
//| trading logic lives in those modules, not here. See FlashEA.md    |
//| in the project root for the running build tracker.                 |
//|                                                                    |
//| Preserved from Phase 1, unchanged: both entry calculation          |
//| formulas, the initial protective SL rule, automatic attached-      |
//| chart timeframe, no directional indicators, and the single-        |
//| instance GlobalVariable ownership lock - Phase 2 never bypasses    |
//| that lock with a second order-management path.                     |
//+------------------------------------------------------------------+
#property copyright "OtienoBanks"
#property version   "3.00"
#property strict

// Build identifier for live-test evidence traceability (verification-only
// safety pass, 2026-09-17): printed once at OnInit so a log line proves
// which exact source revision a given chart attachment actually loaded,
// rather than inferring it from a compile timestamp. Bump this string any
// time FlashEA.mq5 or any of its included .mqh files changes, so it is
// never ambiguous which fixes a given test run exercised.
#define FLASH_BUILD_ID "P3-DEV-20260919-01 (Phase 3: broker-state reconciliation engine, persistent intent, bounded execution retry, structured diagnostics - baseline Phase 2 P2-SAFETYFIX-20260918-02 unmodified)"
#define FLASH_SETUP_EXIT_RETRY_COOLDOWN_SECONDS 2  // seconds between HandleSetupExit retry attempts - Phase 2 baseline, superseded operationally by CFlashExecutionControl's own MinDelaySeconds below but left defined for compatibility

#include "Core\FlashConfig.mqh"
#include "Core\FlashState.mqh"
#include "Core\FlashLogger.mqh"
#include "Core\FlashOwnership.mqh"
#include "Core\FlashSessions.mqh"
#include "Core\FlashDailyLimits.mqh"
#include "Core\FlashPersistence.mqh"
#include "Market\FlashSymbol.mqh"
#include "Market\FlashTimeframe.mqh"
#include "Entry\FlashEntryEngine.mqh"
#include "Execution\FlashOrders.mqh"
#include "Execution\FlashBrokerRules.mqh"
#include "Recovery\FlashRecovery.mqh"
#include "Trailing\FlashTrailing.mqh"
#include "Reversal\FlashReversal.mqh"
#include "Risk\FlashSizing.mqh"
#include "Risk\FlashProfitTarget.mqh"
#include "Core\FlashIntent.mqh"
#include "Core\FlashDiagnostics.mqh"
#include "Execution\FlashExecutionControl.mqh"
#include "Reconciliation\FlashReconciliation.mqh"

//================================= INPUTS ==================================
//--- Group A: Entry Settings
input ENUM_FLASH_ENTRY_METHOD EntryMethod = FLASH_ENTRY_FIXED_PRICE_DISTANCE; // Entry Method
input double EntryDistancePrice          = 1.00; // Entry Distance (Gold Price)
input double PreviousCandleEntryBuffer   = 0.00; // Previous Candle Entry Buffer

//--- Group B: Position Settings
input double LotSizePerPosition          = 0.01; // Lot Size Per Position
input int    PositionsPerSetup           = 1;    // Number of Positions Per Setup

//--- Group C: Trading Safety
input double MaximumAllowedSpread        = 0.30;     // Maximum Allowed Spread (Gold Price)
input long   FlashMagicNumber            = 260917;   // Flash Trade Identification Number

//--- Group D: Diagnostics
input bool EnableDetailedLogging         = true; // Enable Detailed Logging
input bool EnablePhase1SelfTest          = true; // Enable Phase 1 and Phase 2 Self-Test Suite

//--- Group E: Trailing
input double TrailingActivationDistance  = 1.00; // Trailing Activation Distance (Gold Price)
input double TrailingStopDistance        = 1.00; // Trailing Stop Distance (Gold Price)
input double MinimumTrailingUpdate       = 0.20; // Minimum Trailing Update (Gold Price)

//--- Group F: Position Sizing
input ENUM_FLASH_SIZING_METHOD PositionSizingMethod = FLASH_SIZING_FIXED_LOT; // Position Sizing Method
input double EquityRiskPerSetupPercent   = 0.50; // Equity Risk Per Setup (%)

//--- Group G: Setup Profit Target
input bool   EnableSetupProfitTarget     = true;  // Enable Setup Profit Target
input double SetupProfitTargetCurrency   = 3.00;  // Setup Profit Target (Account Currency)

//--- Group H: Daily Limits
input bool   EnableDailyProfitLimit      = false; // Enable Daily Profit Limit
input double DailyProfitLimitCurrency    = 30.00; // Daily Profit Limit (Account Currency)
input bool   EnableDailyLossLimit        = false; // Enable Daily Loss Limit
input double DailyLossLimitCurrency      = 20.00; // Daily Loss Limit (Account Currency)

//--- Group I: Kenya-Time Sessions
input bool   EnableTradingSessions       = false;  // Enable Trading Sessions
input bool   EnableEarlySession          = true;   // Enable Early Session
input string EarlySessionStart           = "04:00"; // Early Session Start (Kenya Time)
input string EarlySessionEnd             = "05:00"; // Early Session End (Kenya Time)
input bool   EnableMiddaySession         = true;   // Enable Midday Session
input string MiddaySessionStart          = "10:00"; // Midday Session Start (Kenya Time)
input string MiddaySessionEnd            = "11:00"; // Midday Session End (Kenya Time)
input bool   EnableEveningSession        = true;   // Enable Evening Session
input string EveningSessionStart         = "17:00"; // Evening Session Start (Kenya Time)
input string EveningSessionEnd           = "18:00"; // Evening Session End (Kenya Time)
input double BrokerServerUTCOffsetHours  = 3.00;   // Broker Server Time Offset From UTC (Hours)

//--- Group I: Phase 3 Diagnostics (observability only - never alters a trading decision)
input bool   EnableDetailedDiagnosticLogging = true;  // Enable Detailed Diagnostic Logging
input bool   LogBrokerReconciliationEvents   = true;  // Log Broker Reconciliation Events
input bool   LogTradeRequestDetails          = true;  // Log Trade Request Details

//================================ MODULE STATE ==============================
CFlashState     g_state;
CFlashSymbol    g_symbol;
CFlashTimeframe g_timeframe;
SFlashConfig    g_config;
SFlashSetup     g_setup;
SBrokerSpecs    g_specs;
bool            g_isOwner = false;
bool            g_ownershipBlocked = false;
bool            g_reversalEnabledForAccount = false;

//--- Phase 3 state (Stage 3.3 retry budget, Stage 3.4 repeated-failure throttling)
SFlashRetryBudget g_setupExitBudget;
bool              g_setupExitBudgetActive = false;
string            g_setupExitLastFailKey = "";
int               g_setupExitFailRepeatCount = 0;


//+------------------------------------------------------------------+
//| Phase 1 + Phase 2 self-test suite                                |
//| Exercises the real classes below directly - never a              |
//| reimplementation of their logic - so a PASS here reflects the     |
//| code that actually runs, not a paraphrase of it.                  |
//+------------------------------------------------------------------+
int g_selfTestTotal = 0;
int g_selfTestPassed = 0;
int g_selfTestFailed = 0;

void SelfTestAssert(const string testName, const bool condition)
{
   g_selfTestTotal++;
   if(condition)
   {
      g_selfTestPassed++;
      PrintFormat("[FLASH][SELFTEST] %s | PASS", testName);
   }
   else
   {
      g_selfTestFailed++;
      PrintFormat("[FLASH][SELFTEST] %s | FAIL", testName);
   }
}

void RunPhase1SelfTestSuite()
{
   g_selfTestTotal = 0; g_selfTestPassed = 0; g_selfTestFailed = 0;

   //--- CFlashConfig::Validate ---
   SFlashConfig validCfg;
   validCfg.EntryMethod = FLASH_ENTRY_FIXED_PRICE_DISTANCE;
   validCfg.EntryDistancePrice = 1.00;
   validCfg.PreviousCandleEntryBuffer = 0.00;
   validCfg.LotSizePerPosition = 0.01;
   validCfg.PositionsPerSetup = 1;
   validCfg.MaximumAllowedSpread = 0.30;
   validCfg.FlashMagicNumber = 12345;
   validCfg.EnableDetailedLogging = false;
   validCfg.TrailingActivationDistance = 1.00;
   validCfg.TrailingStopDistance = 1.00;
   validCfg.MinimumTrailingUpdate = 0.20;
   validCfg.SizingMethod = FLASH_SIZING_FIXED_LOT;
   validCfg.EquityRiskPercentPerSetup = 0.50;
   validCfg.EnableSetupProfitTarget = true;
   validCfg.SetupProfitTarget = 3.00;
   validCfg.EnableDailyProfitLimit = false;
   validCfg.DailyProfitLimit = 30.00;
   validCfg.EnableDailyLossLimit = false;
   validCfg.DailyLossLimit = 20.00;
   validCfg.EnableTradingSessions = false;
   validCfg.EnableEarlySession = true;  validCfg.EarlySessionStartMinutes = 240; validCfg.EarlySessionEndMinutes = 300;
   validCfg.EnableMiddaySession = true; validCfg.MiddaySessionStartMinutes = 600; validCfg.MiddaySessionEndMinutes = 660;
   validCfg.EnableEveningSession = true; validCfg.EveningSessionStartMinutes = 1020; validCfg.EveningSessionEndMinutes = 1080;
   validCfg.BrokerServerUTCOffsetHours = 3.0;
   SelfTestAssert("Config: valid input set passes validation", CFlashConfig::Validate(validCfg));

   SFlashConfig badEntry = validCfg; badEntry.EntryDistancePrice = 0.0;
   SelfTestAssert("Config: zero Entry Distance in Fixed mode fails validation", !CFlashConfig::Validate(badEntry));

   SFlashConfig badLot = validCfg; badLot.LotSizePerPosition = 0.0;
   SelfTestAssert("Config: zero Lot Size Per Position fails validation", !CFlashConfig::Validate(badLot));

   SFlashConfig badPositions = validCfg; badPositions.PositionsPerSetup = 0;
   SelfTestAssert("Config: Number of Positions Per Setup < 1 fails validation", !CFlashConfig::Validate(badPositions));

   SFlashConfig badMagic = validCfg; badMagic.FlashMagicNumber = 0;
   SelfTestAssert("Config: Flash Trade Identification Number <= 0 fails validation", !CFlashConfig::Validate(badMagic));

   SFlashConfig badSpread = validCfg; badSpread.MaximumAllowedSpread = -0.10;
   SelfTestAssert("Config: negative Maximum Allowed Spread fails validation", !CFlashConfig::Validate(badSpread));

   SFlashConfig badTrailAct = validCfg; badTrailAct.TrailingActivationDistance = 0.0;
   SelfTestAssert("Config: zero Trailing Activation Distance fails validation", !CFlashConfig::Validate(badTrailAct));

   SFlashConfig badRisk = validCfg; badRisk.SizingMethod = FLASH_SIZING_PERCENT_EQUITY; badRisk.EquityRiskPercentPerSetup = 0.0;
   SelfTestAssert("Config: zero Equity Risk Per Setup with Percentage sizing fails validation", !CFlashConfig::Validate(badRisk));

   SFlashConfig badSession = validCfg; badSession.EnableTradingSessions = true; badSession.EarlySessionStartMinutes = 300; badSession.EarlySessionEndMinutes = 240;
   SelfTestAssert("Config: session end before start fails validation", !CFlashConfig::Validate(badSession));

   //--- CFlashState transitions ---
   CFlashState testState;
   SelfTestAssert("State: starts in INITIALIZING", testState.Current() == FLASH_STATE_INITIALIZING);
   SelfTestAssert("State: INITIALIZING -> WAITING_FOR_ENTRY is legal", testState.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "selftest"));
   SelfTestAssert("State: WAITING_FOR_ENTRY -> ENTRY_DETECTED is illegal", !testState.TransitionTo(FLASH_STATE_ENTRY_DETECTED, "selftest"));
   SelfTestAssert("State: illegal transition did not change state", testState.Current() == FLASH_STATE_WAITING_FOR_ENTRY);
   SelfTestAssert("State: WAITING_FOR_ENTRY -> PLACING_ORDERS is legal", testState.TransitionTo(FLASH_STATE_PLACING_ORDERS, "selftest"));
   SelfTestAssert("State: PLACING_ORDERS -> ORDERS_ARMED is legal", testState.TransitionTo(FLASH_STATE_ORDERS_ARMED, "selftest"));
   SelfTestAssert("State: ORDERS_ARMED -> ENTRY_DETECTED is legal", testState.TransitionTo(FLASH_STATE_ENTRY_DETECTED, "selftest"));
   SelfTestAssert("State: ENTRY_DETECTED -> CANCELLING_OPPOSITE is legal", testState.TransitionTo(FLASH_STATE_CANCELLING_OPPOSITE, "selftest"));
   SelfTestAssert("State: CANCELLING_OPPOSITE -> POSITION_ACTIVE is legal", testState.TransitionTo(FLASH_STATE_POSITION_ACTIVE, "selftest"));
   SelfTestAssert("State: POSITION_ACTIVE -> WAITING_FOR_ENTRY is legal (after reconciliation)", testState.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "selftest"));

   CFlashState testState2;
   SelfTestAssert("State: RECOVERY_REQUIRED reachable from any state", testState2.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "selftest"));
   SelfTestAssert("State: RECOVERY_REQUIRED -> POSITION_ACTIVE is legal (recovered protected position)", testState2.TransitionTo(FLASH_STATE_POSITION_ACTIVE, "selftest"));

   CFlashState testState3;
   testState3.TransitionTo(FLASH_STATE_TRADING_BLOCKED, "selftest");
   SelfTestAssert("State: TRADING_BLOCKED cannot transition out without re-init", !testState3.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "selftest"));

   //--- SFlashSetup reset ---
   SFlashSetup setup;
   setup.SetupId = "TEST-0001"; setup.MagicNumber = 999; setup.OriginalBuyStopPrice = 3001.20;
   ArrayResize(setup.BuyStopTickets, 1); setup.BuyStopTickets[0] = 555;
   setup.Reset();
   SelfTestAssert("Setup: Reset() clears SetupId", setup.SetupId == "");
   SelfTestAssert("Setup: Reset() clears OriginalBuyStopPrice", setup.OriginalBuyStopPrice == 0.0);
   SelfTestAssert("Setup: Reset() clears BuyStopTickets", ArraySize(setup.BuyStopTickets) == 0);
   SelfTestAssert("Setup: HasUnresolvedExposure() false after reset", !setup.HasUnresolvedExposure());

   //--- CFlashEntryEngine: Fixed Price Distance (Phase 1 build prompt Section 8.1 example) ---
   SFlashEntryPair fixedPair = CFlashEntryEngine::CalculateFixedDistance(3000.00, 3000.20, 1.00);
   SelfTestAssert("Entry: fixed-distance Buy Stop = Ask + distance (3001.20)", MathAbs(fixedPair.buyStopPrice - 3001.20) < 0.0001);
   SelfTestAssert("Entry: fixed-distance Sell Stop = Bid - distance (2999.00)", MathAbs(fixedPair.sellStopPrice - 2999.00) < 0.0001);
   SelfTestAssert("Entry: fixed-distance BUY initial SL = original Sell Stop", MathAbs(fixedPair.buyInitialSL - fixedPair.sellStopPrice) < 0.0001);
   SelfTestAssert("Entry: fixed-distance SELL initial SL = original Buy Stop", MathAbs(fixedPair.sellInitialSL - fixedPair.buyStopPrice) < 0.0001);

   //--- CFlashEntryEngine: Previous Candle (Section 8.2 example) ---
   SFlashEntryPair candlePair = CFlashEntryEngine::CalculatePreviousCandle(3005.00, 3001.00, 0.20);
   SelfTestAssert("Entry: previous-candle Buy Stop = high + buffer (3005.20)", MathAbs(candlePair.buyStopPrice - 3005.20) < 0.0001);
   SelfTestAssert("Entry: previous-candle Sell Stop = low - buffer (3000.80)", MathAbs(candlePair.sellStopPrice - 3000.80) < 0.0001);

   //--- CFlashEntryEngine: already-crossed rejection (Section 8.3 example) ---
   SFlashEntryPair crossedPair = CFlashEntryEngine::CalculatePreviousCandle(3005.00, 3001.00, 0.20);
   bool crossedOk = CFlashEntryEngine::RejectIfAlreadyCrossed(crossedPair, 3000.00, 3005.50);
   SelfTestAssert("Entry: already-crossed Buy Stop is rejected, not converted to market", !crossedOk && !crossedPair.valid);

   SFlashEntryPair notCrossedPair = CFlashEntryEngine::CalculateFixedDistance(3000.00, 3000.20, 1.00);
   bool notCrossedOk = CFlashEntryEngine::RejectIfAlreadyCrossed(notCrossedPair, 3000.00, 3000.20);
   SelfTestAssert("Entry: valid (not crossed) pair passes the crossed-check", notCrossedOk && notCrossedPair.valid);

   //--- CFlashBrokerRules: spread (Section 7.3 example) ---
   double outSpread;
   SelfTestAssert("Broker: spread 0.25 within max 0.30 passes", CFlashBrokerRules::SpreadOk(3000.00, 3000.25, 0.30, outSpread));
   SelfTestAssert("Broker: spread 0.45 exceeding max 0.30 fails", !CFlashBrokerRules::SpreadOk(3000.00, 3000.45, 0.30, outSpread));

   //--- CFlashBrokerRules: tick normalization ---
   SelfTestAssert("Broker: NormalizeToTick rounds to nearest tick", MathAbs(CFlashBrokerRules::NormalizeToTick(3001.234, 0.01) - 3001.23) < 0.0001);

   //--- CFlashBrokerRules: minimum pending distance (Section 7.4 example) ---
   SelfTestAssert("Broker: Buy Stop only 0.20 above Ask fails 0.50 minimum",
                  !CFlashBrokerRules::PendingDistanceOk(ORDER_TYPE_BUY_STOP, 3001.00, 3000.80, 3000.80, 0.50));
   SelfTestAssert("Broker: Buy Stop 0.60 above Ask passes 0.50 minimum",
                  CFlashBrokerRules::PendingDistanceOk(ORDER_TYPE_BUY_STOP, 3001.40, 3000.00, 3000.80, 0.50));
   SelfTestAssert("Broker: Sell Stop 0.60 below Bid passes 0.50 minimum",
                  CFlashBrokerRules::PendingDistanceOk(ORDER_TYPE_SELL_STOP, 2999.40, 3000.00, 3000.80, 0.50));

   //--- CFlashBrokerRules: volume ---
   SelfTestAssert("Broker: volume 0.01 with min 0.01 step 0.01 is valid", CFlashBrokerRules::VolumeOk(0.01, 0.01, 100.0, 0.01));
   SelfTestAssert("Broker: volume 0.015 not a multiple of 0.01 step is invalid", !CFlashBrokerRules::VolumeOk(0.015, 0.01, 100.0, 0.01));
   SelfTestAssert("Broker: volume 0.00 below min 0.01 is invalid", !CFlashBrokerRules::VolumeOk(0.00, 0.01, 100.0, 0.01));

   //--- CFlashBrokerRules: symbol support list ---
   SelfTestAssert("Broker: XAUUSD is an explicitly supported symbol", CFlashBrokerRules::SymbolNameSupported("XAUUSD"));
   SelfTestAssert("Broker: XAUUSDm is an explicitly supported symbol", CFlashBrokerRules::SymbolNameSupported("XAUUSDm"));
   SelfTestAssert("Broker: unrelated similar-looking symbol is not supported", !CFlashBrokerRules::SymbolNameSupported("XAUUSDFAKE999"));

   //--- CFlashRecovery::Classify - all six scenarios, synthetic snapshots ---
   SFlashRecoverySnapshot s0;
   s0.PendingBuyStops = 0; s0.PendingSellStops = 0; s0.OpenPositions = 0; s0.ActiveDirection = ""; s0.AnyPositionUnprotected = false;
   SelfTestAssert("Recovery: no exposure classifies as NONE", CFlashRecovery::Classify(s0) == FLASH_RECOVERY_NONE);

   SFlashRecoverySnapshot s1;
   s1.PendingBuyStops = 1; s1.PendingSellStops = 1; s1.OpenPositions = 0; s1.ActiveDirection = ""; s1.AnyPositionUnprotected = false;
   SelfTestAssert("Recovery: both sides pending classifies as VALID_PENDING_PAIR", CFlashRecovery::Classify(s1) == FLASH_RECOVERY_VALID_PENDING_PAIR);

   SFlashRecoverySnapshot s2;
   s2.PendingBuyStops = 1; s2.PendingSellStops = 0; s2.OpenPositions = 0; s2.ActiveDirection = ""; s2.AnyPositionUnprotected = false;
   SelfTestAssert("Recovery: only one side pending classifies as INCOMPLETE_PENDING", CFlashRecovery::Classify(s2) == FLASH_RECOVERY_INCOMPLETE_PENDING);

   SFlashRecoverySnapshot s3;
   s3.PendingBuyStops = 0; s3.PendingSellStops = 0; s3.OpenPositions = 1; s3.ActiveDirection = "BUY"; s3.AnyPositionUnprotected = false;
   SelfTestAssert("Recovery: protected position classifies as ACTIVE_PROTECTED", CFlashRecovery::Classify(s3) == FLASH_RECOVERY_ACTIVE_PROTECTED);

   SFlashRecoverySnapshot s4;
   s4.PendingBuyStops = 0; s4.PendingSellStops = 0; s4.OpenPositions = 1; s4.ActiveDirection = "SELL"; s4.AnyPositionUnprotected = true;
   SelfTestAssert("Recovery: unprotected position classifies as ACTIVE_UNPROTECTED", CFlashRecovery::Classify(s4) == FLASH_RECOVERY_ACTIVE_UNPROTECTED);

   SFlashRecoverySnapshot s5;
   s5.PendingBuyStops = 0; s5.PendingSellStops = 0; s5.OpenPositions = 2; s5.ActiveDirection = "MIXED"; s5.AnyPositionUnprotected = false;
   SelfTestAssert("Recovery: opposite-direction positions classify as UNEXPECTED_OPPOSITE", CFlashRecovery::Classify(s5) == FLASH_RECOVERY_UNEXPECTED_OPPOSITE);

   //--- CFlashOwnership::Decide ---
   SelfTestAssert("Ownership: no existing owner yields CLAIM_NEW",
      CFlashOwnership::Decide(false, 0, 111, true, 0.0, 90.0) == FLASH_OWNERSHIP_CLAIM_NEW);
   SelfTestAssert("Ownership: existing owner is this chart yields ALREADY_OWNER",
      CFlashOwnership::Decide(true, 111, 111, true, 5.0, 90.0) == FLASH_OWNERSHIP_ALREADY_OWNER);
   SelfTestAssert("Ownership: other owner with fresh heartbeat yields BLOCKED_CONFLICT",
      CFlashOwnership::Decide(true, 222, 111, true, 5.0, 90.0) == FLASH_OWNERSHIP_BLOCKED_CONFLICT);
   SelfTestAssert("Ownership: other owner with stale heartbeat yields TAKEOVER_STALE",
      CFlashOwnership::Decide(true, 222, 111, true, 120.0, 90.0) == FLASH_OWNERSHIP_TAKEOVER_STALE);
   SelfTestAssert("Ownership: other owner with unreadable heartbeat yields BLOCKED_CONFLICT, never a blind takeover",
      CFlashOwnership::Decide(true, 222, 111, false, 0.0, 90.0) == FLASH_OWNERSHIP_BLOCKED_CONFLICT);

   //--- Phase 2: CFlashTrailing ---
   SelfTestAssert("Trailing: BUY favorable movement 0.70 below 1.00 activation is not reached",
      !CFlashTrailing::ActivationReached(CFlashTrailing::FavorableMovementBuy(3000.70, 3000.00), 1.00));
   SelfTestAssert("Trailing: BUY favorable movement 1.00 reaches 1.00 activation",
      CFlashTrailing::ActivationReached(CFlashTrailing::FavorableMovementBuy(3001.00, 3000.00), 1.00));
   SelfTestAssert("Trailing: BUY candidate SL at Bid 3001.00 distance 1.00 is 3000.00",
      MathAbs(CFlashTrailing::CandidateBuySL(3001.00, 1.00) - 3000.00) < 0.0001);
   SelfTestAssert("Trailing: BUY ratchet moves SL from 2998.00 to candidate 3000.00",
      MathAbs(CFlashTrailing::NewBuySL(2998.00, 3000.00) - 3000.00) < 0.0001);
   SelfTestAssert("Trailing: BUY ratchet never moves SL backward (candidate 2999.90 below current 3000.00)",
      MathAbs(CFlashTrailing::NewBuySL(3000.00, 2999.90) - 3000.00) < 0.0001);
   SelfTestAssert("Trailing: BUY improvement of 0.10 fails 0.20 minimum update",
      !CFlashTrailing::MeetsMinimumUpdate(3000.10, 3000.00, 0.20, true));
   SelfTestAssert("Trailing: BUY improvement of 0.25 passes 0.20 minimum update",
      CFlashTrailing::MeetsMinimumUpdate(3000.25, 3000.00, 0.20, true));
   SelfTestAssert("Trailing: SELL favorable movement reaches activation (entry 3000.00, Ask 2999.00, distance 1.00)",
      CFlashTrailing::ActivationReached(CFlashTrailing::FavorableMovementSell(3000.00, 2999.00), 1.00));
   SelfTestAssert("Trailing: SELL candidate SL at Ask 2999.00 distance 1.00 is 3000.00",
      MathAbs(CFlashTrailing::CandidateSellSL(2999.00, 1.00) - 3000.00) < 0.0001);
   SelfTestAssert("Trailing: SELL ratchet moves SL from 3002.00 to candidate 3000.00",
      MathAbs(CFlashTrailing::NewSellSL(3002.00, 3000.00) - 3000.00) < 0.0001);
   SelfTestAssert("Trailing: SELL ratchet never moves SL backward (candidate 3000.50 above current 3000.00)",
      MathAbs(CFlashTrailing::NewSellSL(3000.00, 3000.50) - 3000.00) < 0.0001);

   //--- Phase 2: CFlashSizing ---
   SFlashSizingResult fixedLot = CFlashSizing::FixedLot(0.01, 3, 0.01, 100.0, 0.01);
   SelfTestAssert("Sizing: fixed lot 0.01 x 3 positions totals 0.03", fixedLot.valid && MathAbs(fixedLot.totalVolume - 0.03) < 0.0001);

   SFlashSizingResult pctEquity = CFlashSizing::PercentEquity(10000.0, 0.50, 1, 220.0, 0.01, 100.0, 0.01);
   SelfTestAssert("Sizing: percent-equity risk budget 50 / lossPerLot 220 gives ~0.22 lots (1 position)",
      pctEquity.valid && MathAbs(pctEquity.volumePerPosition - 0.22) < 0.0001);

   SFlashSizingResult pctEquity3 = CFlashSizing::PercentEquity(10000.0, 0.50, 3, 220.0, 0.01, 100.0, 0.01);
   SelfTestAssert("Sizing: percent-equity across 3 positions stays within the single 0.50% setup budget, not 0.50% x 3",
      pctEquity3.valid && (pctEquity3.totalVolume <= pctEquity.totalVolume + 0.0001));

   SFlashSizingResult pctEquityInsufficient = CFlashSizing::PercentEquity(100.0, 0.10, 1, 220.0, 0.01, 100.0, 0.01);
   SelfTestAssert("Sizing: risk budget too small for minimum volume is rejected, not silently increased",
      !pctEquityInsufficient.valid);

   //--- Phase 2: CFlashProfitTarget ---
   SelfTestAssert("ProfitTarget: three floating legs 1.20+1.10+0.90=3.20 reaches 3.00 target",
      CFlashProfitTarget::TargetReached(true, CFlashProfitTarget::CombinedPL(0.0, 1.20 + 1.10 + 0.90), 3.00));
   SelfTestAssert("ProfitTarget: earlier realized loss -2.00 plus current floating +4.50 = 2.50 does NOT reach 3.00 target",
      !CFlashProfitTarget::TargetReached(true, CFlashProfitTarget::CombinedPL(-2.00, 4.50), 3.00));
   SelfTestAssert("ProfitTarget: disabled switch never reports target reached regardless of P/L",
      !CFlashProfitTarget::TargetReached(false, 999.0, 3.00));

   //--- Phase 2: CFlashDailyLimits ---
   SelfTestAssert("DailyLimits: realized +30.50 reaches a 30.00 profit limit",
      CFlashDailyLimits::ProfitLimitReached(true, 30.50, 30.00));
   SelfTestAssert("DailyLimits: disabled profit limit never reports reached",
      !CFlashDailyLimits::ProfitLimitReached(false, 999.0, 30.00));
   SelfTestAssert("DailyLimits: realized -20.25 reaches a 20.00 loss limit",
      CFlashDailyLimits::LossLimitReached(true, -20.25, 20.00));
   SelfTestAssert("DailyLimits: disabled loss limit never reports reached",
      !CFlashDailyLimits::LossLimitReached(false, -999.0, 20.00));

   //--- Phase 2: CFlashSessions ---
   SFlashSessionWindow earlyWindow; earlyWindow.enabled = true; earlyWindow.startMinutes = 240; earlyWindow.endMinutes = 300;
   SelfTestAssert("Sessions: 04:00 Kenya time is permitted (window start inclusive)",
      CFlashSessions::InWindow(240, earlyWindow));
   SelfTestAssert("Sessions: 04:59 Kenya time is permitted (still inside window)",
      CFlashSessions::InWindow(299, earlyWindow));
   SelfTestAssert("Sessions: 05:00 Kenya time is blocked (window end exclusive)",
      !CFlashSessions::InWindow(300, earlyWindow));
   SelfTestAssert("Sessions: disabled session filter switch never blocks new entries",
      CFlashSessions::NewEntryPermitted(false, 700, earlyWindow, earlyWindow, earlyWindow));
   SelfTestAssert("Sessions: ParseHHMM('04:00') yields 240 minutes",
      CFlashSessions::ParseHHMM("04:00") == 240);
   SelfTestAssert("Sessions: ParseHHMM rejects an invalid hour",
      CFlashSessions::ParseHHMM("25:00") == -1);

   //--- Phase 2: CFlashReversal ---
   SelfTestAssert("Reversal: fully eligible sequence yields EligibleToArm=true",
      CFlashReversal::EligibleToArm(true, true, true, true, true));
   SelfTestAssert("Reversal: trailing not yet activated blocks arming",
      !CFlashReversal::EligibleToArm(true, true, true, false, true));
   SelfTestAssert("Reversal: reference price equals the confirmed trailing SL (3001.20)",
      MathAbs(CFlashReversal::ReversalReferencePrice(3001.20) - 3001.20) < 0.0001);
   SelfTestAssert("Reversal: old exposure of 0.00 lots is classified fully closed",
      CFlashReversal::OldExposureFullyClosed(0.0));
   SelfTestAssert("Reversal: old exposure of 0.01 lots remaining is NOT classified fully closed",
      !CFlashReversal::OldExposureFullyClosed(0.01));
   SelfTestAssert("Reversal: new SELL leg protective stop = fill 3001.20 + trailing distance 1.00 = 3002.20",
      MathAbs(CFlashReversal::ProtectiveStopForNewDirection(false, 3001.20, 1.00) - 3002.20) < 0.0001);
   SelfTestAssert("Reversal: new BUY leg protective stop = fill 2999.00 - trailing distance 1.00 = 2998.00",
      MathAbs(CFlashReversal::ProtectiveStopForNewDirection(true, 2999.00, 1.00) - 2998.00) < 0.0001);

   //--- Phase 2: CFlashState transitions ---
   CFlashState testState4;
   testState4.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "selftest");
   testState4.TransitionTo(FLASH_STATE_PLACING_ORDERS, "selftest");
   testState4.TransitionTo(FLASH_STATE_ORDERS_ARMED, "selftest");
   testState4.TransitionTo(FLASH_STATE_ENTRY_DETECTED, "selftest");
   testState4.TransitionTo(FLASH_STATE_CANCELLING_OPPOSITE, "selftest");
   testState4.TransitionTo(FLASH_STATE_POSITION_ACTIVE, "selftest");
   SelfTestAssert("State: POSITION_ACTIVE -> REVERSAL_RECONCILING is legal", testState4.TransitionTo(FLASH_STATE_REVERSAL_RECONCILING, "selftest"));
   SelfTestAssert("State: REVERSAL_RECONCILING -> POSITION_ACTIVE is legal", testState4.TransitionTo(FLASH_STATE_POSITION_ACTIVE, "selftest"));
   SelfTestAssert("State: POSITION_ACTIVE -> SETUP_EXIT is legal", testState4.TransitionTo(FLASH_STATE_SETUP_EXIT, "selftest"));
   SelfTestAssert("State: SETUP_EXIT -> WAITING_FOR_ENTRY is legal", testState4.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "selftest"));

   //--- Phase 2: SFlashSetup leg reset ---
   SFlashSetup setup2;
   setup2.SetupId = "TEST-0002"; setup2.ReversalCount = 2; setup2.SetupRealizedPL = -1.50; setup2.TrailingActive = true;
   setup2.ResetForNewLeg();
   SelfTestAssert("Setup: ResetForNewLeg() clears TrailingActive", !setup2.TrailingActive);
   SelfTestAssert("Setup: ResetForNewLeg() preserves ReversalCount", setup2.ReversalCount == 2);
   SelfTestAssert("Setup: ResetForNewLeg() preserves SetupRealizedPL", MathAbs(setup2.SetupRealizedPL - (-1.50)) < 0.0001);

   //--- Phase 3 Stage 3.1: CFlashReconciliation::Classify, pure, synthetic snapshots ---
   SFlashReconSnapshot rs1;
   rs1.IsOwner = true; rs1.InternalSetupId = ""; rs1.InternalActiveDirection = ""; rs1.OpenPositionCount = 0; rs1.PendingOrderCount = 0;
   rs1.AnyPositionUnprotected = false; rs1.BrokerActiveDirection = ""; rs1.CloseIntentOutstanding = false; rs1.CancelIntentOutstanding = false;
   rs1.InternalStateName = "WAITING_FOR_ENTRY";
   SelfTestAssert("Reconcile: no exposure, no internal setup -> NO_EXPOSURE", CFlashReconciliation::Classify(rs1) == FLASH_RECON_NO_EXPOSURE);

   SFlashReconSnapshot rs2 = rs1;
   rs2.InternalSetupId = "TEST-SETUP-1"; rs2.OpenPositionCount = 0; rs2.PendingOrderCount = 0;
   SelfTestAssert("Reconcile: internal setup exists, no broker exposure -> POSSIBLE_COMPLETED_OR_MISSING_SETUP",
      CFlashReconciliation::Classify(rs2) == FLASH_RECON_POSSIBLE_COMPLETED_OR_MISSING_SETUP);

   SFlashReconSnapshot rs3 = rs1;
   rs3.PendingOrderCount = 1;
   SelfTestAssert("Reconcile: one pending order only -> INCOMPLETE_PENDING_SETUP",
      CFlashReconciliation::Classify(rs3) == FLASH_RECON_INCOMPLETE_PENDING_SETUP);

   SFlashReconSnapshot rs4 = rs1;
   rs4.PendingOrderCount = 2; rs4.InternalSetupId = "TEST-SETUP-2";
   SelfTestAssert("Reconcile: two pending orders, matching internal setup -> MATCHED_ARMED_SETUP",
      CFlashReconciliation::Classify(rs4) == FLASH_RECON_MATCHED_ARMED_SETUP);

   SFlashReconSnapshot rs5 = rs1;
   rs5.PendingOrderCount = 2; rs5.InternalSetupId = "";
   SelfTestAssert("Reconcile: two pending orders, NO internal setup -> ORPHANED_ORDER",
      CFlashReconciliation::Classify(rs5) == FLASH_RECON_ORPHANED_ORDER);

   SFlashReconSnapshot rs6 = rs1;
   rs6.OpenPositionCount = 1; rs6.AnyPositionUnprotected = true; rs6.InternalSetupId = "TEST-SETUP-3"; rs6.BrokerActiveDirection = "BUY";
   SelfTestAssert("Reconcile: open position with SL==0 -> UNPROTECTED_EXPOSURE",
      CFlashReconciliation::Classify(rs6) == FLASH_RECON_UNPROTECTED_EXPOSURE);

   SFlashReconSnapshot rs7 = rs1;
   rs7.OpenPositionCount = 1; rs7.InternalSetupId = "TEST-SETUP-4"; rs7.InternalActiveDirection = "BUY";
   rs7.BrokerActiveDirection = "SELL"; rs7.InternalStateName = "POSITION_ACTIVE";
   SelfTestAssert("Reconcile: internal=BUY, broker shows SELL, setup active -> REVERSAL_RECONCILIATION_REQUIRED",
      CFlashReconciliation::Classify(rs7) == FLASH_RECON_REVERSAL_RECONCILIATION_REQUIRED);

   SFlashReconSnapshot rs8 = rs1;
   rs8.OpenPositionCount = 1; rs8.InternalSetupId = ""; rs8.BrokerActiveDirection = "BUY";
   SelfTestAssert("Reconcile: open Flash position, no internal setup record -> EXPOSURE_DISCREPANCY",
      CFlashReconciliation::Classify(rs8) == FLASH_RECON_EXPOSURE_DISCREPANCY);

   SFlashReconSnapshot rs9 = rs1;
   rs9.CloseIntentOutstanding = true; rs9.OpenPositionCount = 1; rs9.InternalSetupId = "TEST-SETUP-5"; rs9.BrokerActiveDirection = "BUY"; rs9.InternalActiveDirection = "BUY";
   SelfTestAssert("Reconcile: close intent outstanding takes priority -> UNRESOLVED_EXIT",
      CFlashReconciliation::Classify(rs9) == FLASH_RECON_UNRESOLVED_EXIT);

   SFlashReconSnapshot rs10 = rs1;
   rs10.IsOwner = false;
   SelfTestAssert("Reconcile: not the ownership-lock owner -> OWNERSHIP_AMBIGUITY",
      CFlashReconciliation::Classify(rs10) == FLASH_RECON_OWNERSHIP_AMBIGUITY);

   SelfTestAssert("Reconcile: UNPROTECTED_EXPOSURE required action = AUTO_REPAIR",
      FlashReconRequiredAction(FLASH_RECON_UNPROTECTED_EXPOSURE) == RECON_ACTION_AUTO_REPAIR);
   SelfTestAssert("Reconcile: EXPOSURE_DISCREPANCY required action = ESCALATE",
      FlashReconRequiredAction(FLASH_RECON_EXPOSURE_DISCREPANCY) == RECON_ACTION_ESCALATE);
   SelfTestAssert("Reconcile: REVERSAL_RECONCILIATION_REQUIRED required action = BLOCK_NEW_EXPOSURE",
      FlashReconRequiredAction(FLASH_RECON_REVERSAL_RECONCILIATION_REQUIRED) == RECON_ACTION_BLOCK_NEW_EXPOSURE);

   //--- Phase 3 Stage 3.2: CFlashIntent pure functions ---
   SelfTestAssert("Intent: duplicate CLOSE_REQUESTED within grace window is skipped",
      CFlashIntent::ShouldSkipDuplicateRequest(FLASH_INTENT_CLOSE_REQUESTED, 1000, 1005, 10) == true);
   SelfTestAssert("Intent: CLOSE_REQUESTED past grace window is NOT skipped",
      CFlashIntent::ShouldSkipDuplicateRequest(FLASH_INTENT_CLOSE_REQUESTED, 1000, 1020, 10) == false);
   SelfTestAssert("Intent: NONE state is never a duplicate",
      CFlashIntent::ShouldSkipDuplicateRequest(FLASH_INTENT_NONE, 1000, 1001, 10) == false);
   SelfTestAssert("Intent: requested 0.06, remaining 0.00 -> FULLY_CLOSED",
      CFlashIntent::ResolveCloseOutcome(0.06, 0.00, 0.01) == FLASH_CLOSE_OUTCOME_FULLY_CLOSED);
   SelfTestAssert("Intent: requested 0.06, remaining 0.02 -> PARTIALLY_CLOSED",
      CFlashIntent::ResolveCloseOutcome(0.06, 0.02, 0.01) == FLASH_CLOSE_OUTCOME_PARTIALLY_CLOSED);
   SelfTestAssert("Intent: requested 0.06, remaining 0.06 -> NOT_CLOSED",
      CFlashIntent::ResolveCloseOutcome(0.06, 0.06, 0.01) == FLASH_CLOSE_OUTCOME_NOT_CLOSED);

   //--- Phase 3 Stage 3.3: CFlashExecutionControl pure functions ---
   SelfTestAssert("ExecControl: retcode 10009 DONE, full volume -> FULL_SUCCESS",
      CFlashExecutionControl::ClassifyResult(true, TRADE_RETCODE_DONE, 0.06, 0.06) == FLASH_EXEC_FULL_SUCCESS);
   SelfTestAssert("ExecControl: retcode 10009 DONE, partial volume -> PARTIAL_SUCCESS",
      CFlashExecutionControl::ClassifyResult(true, TRADE_RETCODE_DONE, 0.04, 0.06) == FLASH_EXEC_PARTIAL_SUCCESS);
   SelfTestAssert("ExecControl: retcode 10030 -> INVALID_FILLING_POLICY",
      CFlashExecutionControl::ClassifyResult(false, TRADE_RETCODE_INVALID_FILL, 0.0, 0.06) == FLASH_EXEC_INVALID_FILLING_POLICY);
   SelfTestAssert("ExecControl: retcode 10018 -> TEMP_MARKET_CLOSED",
      CFlashExecutionControl::ClassifyResult(false, TRADE_RETCODE_MARKET_CLOSED, 0.0, 0.06) == FLASH_EXEC_TEMP_MARKET_CLOSED);
   SelfTestAssert("ExecControl: retcode 10027 (AutoTrading disabled) -> TRADING_DISABLED",
      CFlashExecutionControl::ClassifyResult(false, 10027, 0.0, 0.06) == FLASH_EXEC_TRADING_DISABLED);
   SelfTestAssert("ExecControl: INVALID_FILLING_POLICY is NOT retryable unchanged",
      CFlashExecutionControl::IsRetryable(FLASH_EXEC_INVALID_FILLING_POLICY) == false);
   SelfTestAssert("ExecControl: TEMP_MARKET_CLOSED IS retryable",
      CFlashExecutionControl::IsRetryable(FLASH_EXEC_TEMP_MARKET_CLOSED) == true);

   SFlashRetryBudget rb; rb.Init("SELFTEST_OP");
   SelfTestAssert("ExecControl: non-retryable outcome -> ESCALATE_NOT_RETRYABLE regardless of attempt count",
      CFlashExecutionControl::DecideNextAction(rb, FLASH_EXEC_INVALID_FILLING_POLICY, 1000) == FLASH_RETRY_ESCALATE_NOT_RETRYABLE);
   SelfTestAssert("ExecControl: fresh budget, retryable outcome -> RETRY_NOW",
      CFlashExecutionControl::DecideNextAction(rb, FLASH_EXEC_TEMP_MARKET_CLOSED, 1000) == FLASH_RETRY_RETRY_NOW);
   CFlashExecutionControl::RecordAttempt(rb, 1000);
   SelfTestAssert("ExecControl: retry too soon after last attempt -> WAIT",
      CFlashExecutionControl::DecideNextAction(rb, FLASH_EXEC_TEMP_MARKET_CLOSED, 1001) == FLASH_RETRY_WAIT);
   SelfTestAssert("ExecControl: past minimum delay -> RETRY_NOW again",
      CFlashExecutionControl::DecideNextAction(rb, FLASH_EXEC_TEMP_MARKET_CLOSED, 1003) == FLASH_RETRY_RETRY_NOW);

   SFlashRetryBudget rb2; rb2.Init("SELFTEST_OP_EXHAUST");
   for(int i = 0; i < rb2.MaxAttempts; i++)
      CFlashExecutionControl::RecordAttempt(rb2, 1000 + i * rb2.MinDelaySeconds);
   SelfTestAssert(StringFormat("ExecControl: %d attempts recorded reaches MaxAttempts -> ESCALATE_EXHAUSTED", rb2.MaxAttempts),
      CFlashExecutionControl::DecideNextAction(rb2, FLASH_EXEC_TEMP_MARKET_CLOSED, 1000 + rb2.MaxAttempts * rb2.MinDelaySeconds) == FLASH_RETRY_ESCALATE_EXHAUSTED);

   SFlashRetryBudget rb3; rb3.Init("SELFTEST_OP_WINDOW"); rb3.Escalated = true;
   SelfTestAssert("ExecControl: already-escalated budget -> ALREADY_ESCALATED, never re-evaluated",
      CFlashExecutionControl::DecideNextAction(rb3, FLASH_EXEC_TEMP_MARKET_CLOSED, 2000) == FLASH_RETRY_ALREADY_ESCALATED);

   PrintFormat("FLASH PHASE 1 + PHASE 2 + PHASE 3 SELF-TEST SUITE COMPLETE | TOTAL: %d | PASSED: %d | FAILED: %d",
               g_selfTestTotal, g_selfTestPassed, g_selfTestFailed);
}

//+------------------------------------------------------------------+
//| Builds an SFlashConfig snapshot from the current `input` values   |
//+------------------------------------------------------------------+
void CaptureConfig()
{
   g_config.EntryMethod = EntryMethod;
   g_config.EntryDistancePrice = EntryDistancePrice;
   g_config.PreviousCandleEntryBuffer = PreviousCandleEntryBuffer;
   g_config.LotSizePerPosition = LotSizePerPosition;
   g_config.PositionsPerSetup = PositionsPerSetup;
   g_config.MaximumAllowedSpread = MaximumAllowedSpread;
   g_config.FlashMagicNumber = FlashMagicNumber;
   g_config.EnableDetailedLogging = EnableDetailedLogging;

   g_config.TrailingActivationDistance = TrailingActivationDistance;
   g_config.TrailingStopDistance = TrailingStopDistance;
   g_config.MinimumTrailingUpdate = MinimumTrailingUpdate;

   g_config.SizingMethod = PositionSizingMethod;
   g_config.EquityRiskPercentPerSetup = EquityRiskPerSetupPercent;

   g_config.EnableSetupProfitTarget = EnableSetupProfitTarget;
   g_config.SetupProfitTarget = SetupProfitTargetCurrency;

   g_config.EnableDailyProfitLimit = EnableDailyProfitLimit;
   g_config.DailyProfitLimit = DailyProfitLimitCurrency;
   g_config.EnableDailyLossLimit = EnableDailyLossLimit;
   g_config.DailyLossLimit = DailyLossLimitCurrency;

   g_config.EnableTradingSessions = EnableTradingSessions;
   g_config.EnableEarlySession = EnableEarlySession;
   g_config.EarlySessionStartMinutes = CFlashSessions::ParseHHMM(EarlySessionStart);
   g_config.EarlySessionEndMinutes = CFlashSessions::ParseHHMM(EarlySessionEnd);
   g_config.EnableMiddaySession = EnableMiddaySession;
   g_config.MiddaySessionStartMinutes = CFlashSessions::ParseHHMM(MiddaySessionStart);
   g_config.MiddaySessionEndMinutes = CFlashSessions::ParseHHMM(MiddaySessionEnd);
   g_config.EnableEveningSession = EnableEveningSession;
   g_config.EveningSessionStartMinutes = CFlashSessions::ParseHHMM(EveningSessionStart);
   g_config.EveningSessionEndMinutes = CFlashSessions::ParseHHMM(EveningSessionEnd);
   g_config.BrokerServerUTCOffsetHours = BrokerServerUTCOffsetHours;
}

//+------------------------------------------------------------------+
//| Reconstructs a logical setup's realized P/L (profit + commission  |
//| + swap of every realized close) since it opened, from actual      |
//| broker deal history - never from an in-memory running total       |
//| alone, so this stays correct across restarts.                     |
//+------------------------------------------------------------------+
double ComputeSetupRealizedPLSince(const datetime openedAt)
{
   if(openedAt == 0) return 0.0;
   if(!HistorySelect(openedAt, TimeCurrent()))
   {
      CFlashLogger::Error("SETUP_PL", "HistorySelect failed - cannot reconstruct setup realized P/L");
      return 0.0;
   }

   double total = 0.0;
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != g_config.FlashMagicNumber) continue;

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT) continue;

      total += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      total += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      total += HistoryDealGetDouble(ticket, DEAL_SWAP);
   }
   return total;
}

//+------------------------------------------------------------------+
//| Whether new exposure (a new initial setup, or arming/retaining a  |
//| reversal order) is currently permitted - combines the Kenya-time  |
//| session filter and the daily realized profit/loss limits. Never   |
//| gates management of exposure that already exists.                 |
//+------------------------------------------------------------------+
bool NewExposurePermittedNow()
{
   SFlashConfigSessionsView view;
   view.filterEnabled = g_config.EnableTradingSessions;
   view.earlyEnabled = g_config.EnableEarlySession;   view.earlyStart = g_config.EarlySessionStartMinutes;   view.earlyEnd = g_config.EarlySessionEndMinutes;
   view.middayEnabled = g_config.EnableMiddaySession; view.middayStart = g_config.MiddaySessionStartMinutes; view.middayEnd = g_config.MiddaySessionEndMinutes;
   view.eveningEnabled = g_config.EnableEveningSession; view.eveningStart = g_config.EveningSessionStartMinutes; view.eveningEnd = g_config.EveningSessionEndMinutes;
   view.brokerOffsetHours = g_config.BrokerServerUTCOffsetHours;

   if(!CFlashSessions::NewEntryPermittedNow(view))
      return false;

   double dailyPL = CFlashDailyLimits::ComputeTodayRealizedPL(_Symbol, g_config.FlashMagicNumber, g_config.BrokerServerUTCOffsetHours);
   if(!CFlashDailyLimits::NewExposurePermitted(g_config.EnableDailyProfitLimit, dailyPL, g_config.DailyProfitLimit,
                                                g_config.EnableDailyLossLimit, g_config.DailyLossLimit))
      return false;

   return true;
}


//+------------------------------------------------------------------+
//| Sizes one setup leg (initial or reversal) for the given proposed  |
//| entry/SL pair, dispatching on the configured sizing method.       |
//+------------------------------------------------------------------+
bool ComputeSetupVolume(const bool isBuyDirection, const double entryPrice, const double slPrice,
                         double &outVolumePerPosition, double &outTotalVolume)
{
   if(g_config.SizingMethod == FLASH_SIZING_FIXED_LOT)
   {
      SFlashSizingResult r = CFlashSizing::FixedLot(g_config.LotSizePerPosition, g_config.PositionsPerSetup,
                                                      g_specs.volumeMin, g_specs.volumeMax, g_specs.volumeStep);
      if(!r.valid)
      {
         CFlashLogger::Error("SIZING", r.rejectReason);
         return false;
      }
      outVolumePerPosition = r.volumePerPosition;
      outTotalVolume = r.totalVolume;
      return true;
   }

   double lossPerLot;
   if(!CFlashSizing::ComputeLossPerLot(_Symbol, isBuyDirection, entryPrice, slPrice, lossPerLot))
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   SFlashSizingResult r = CFlashSizing::PercentEquity(equity, g_config.EquityRiskPercentPerSetup, g_config.PositionsPerSetup,
                                                        lossPerLot, g_specs.volumeMin, g_specs.volumeMax, g_specs.volumeStep);
   if(!r.valid)
   {
      CFlashLogger::Error("SIZING", r.rejectReason);
      return false;
   }

   outVolumePerPosition = r.volumePerPosition;
   outTotalVolume = r.totalVolume;
   CFlashLogger::Log("SIZING",
      StringFormat("Percent-equity sizing | equity=%s risk=%s%% lossPerLot=%s -> volumePerPosition=%s totalVolume=%s",
                   DoubleToString(equity, 2), DoubleToString(g_config.EquityRiskPercentPerSetup, 2),
                   DoubleToString(lossPerLot, 2), DoubleToString(r.volumePerPosition, 2), DoubleToString(r.totalVolume, 2)));
   return true;
}

//+------------------------------------------------------------------+
//| Places (isRefresh=false) or replaces (isRefresh=true) the        |
//| two-sided initial pending pair. Blocked entirely when new exposure|
//| is not currently permitted (Kenya-time session filter or a daily  |
//| realized profit/loss limit).                                       |
//+------------------------------------------------------------------+
bool PlaceOrRefreshSetup(const bool isRefresh)
{
   if(!NewExposurePermittedNow())
      return false;

   SFlashEntryPair pair = CFlashEntryEngine::Calculate(g_config, _Symbol, g_timeframe);
   if(!pair.valid)
      return false; // reason already logged by the entry engine; stay in current state and try again later

   if(!CFlashBrokerRules::ValidateSpreadForNewSetup(_Symbol, g_config.MaximumAllowedSpread))
      return false;

   double buyPrice  = CFlashBrokerRules::NormalizePrice(_Symbol, pair.buyStopPrice, g_specs);
   double sellPrice = CFlashBrokerRules::NormalizePrice(_Symbol, pair.sellStopPrice, g_specs);
   double buySL     = CFlashBrokerRules::NormalizePrice(_Symbol, pair.buyInitialSL, g_specs);
   double sellSL    = CFlashBrokerRules::NormalizePrice(_Symbol, pair.sellInitialSL, g_specs);

   if(!CFlashBrokerRules::ValidatePendingDistance(_Symbol, ORDER_TYPE_BUY_STOP, buyPrice, g_specs))  return false;
   if(!CFlashBrokerRules::ValidatePendingDistance(_Symbol, ORDER_TYPE_SELL_STOP, sellPrice, g_specs)) return false;

   double buyVolPerPos, buyVolTotal, sellVolPerPos, sellVolTotal;
   if(!ComputeSetupVolume(true, buyPrice, buySL, buyVolPerPos, buyVolTotal))    return false;
   if(!ComputeSetupVolume(false, sellPrice, sellSL, sellVolPerPos, sellVolTotal)) return false;

   if(!CFlashBrokerRules::ValidateVolume(buyVolPerPos, g_specs))  return false;
   if(!CFlashBrokerRules::ValidateVolume(sellVolPerPos, g_specs)) return false;
   if(!CFlashBrokerRules::ValidateMarginForBothSides(_Symbol, MathMax(buyVolPerPos, sellVolPerPos), buyPrice))
      return false;

   if(isRefresh)
   {
      // Safely cancel the existing untriggered pair before replacing it.
      // If cancellation fails partway (e.g. a fill raced the refresh),
      // stop refreshing and let the fill-detection path handle it.
      if(!CFlashOrders::CancelGroup(g_setup.BuyStopTickets) || !CFlashOrders::CancelGroup(g_setup.SellStopTickets))
      {
         CFlashLogger::Error("ENTRY", "Refresh aborted: could not verify cancellation of the previous pair (possible fill in progress)");
         return false;
      }
   }

   g_setup.Reset();
   g_setup.SetupId = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "-" + IntegerToString((int)FlashMagicNumber);
   g_setup.MagicNumber = g_config.FlashMagicNumber;
   g_setup.Symbol = _Symbol;
   g_setup.Timeframe = g_timeframe.Timeframe();
   g_setup.EntryMethod = g_config.EntryMethod;
   g_setup.OriginalBuyStopPrice = buyPrice;
   g_setup.OriginalSellStopPrice = sellPrice;
   g_setup.InitialBuySL = buySL;
   g_setup.InitialSellSL = sellSL;
   g_setup.CreatedAt = TimeCurrent();
   g_setup.SetupOpenedAt = TimeCurrent();

   g_state.TransitionTo(FLASH_STATE_PLACING_ORDERS, isRefresh ? "refreshing setup on new candle" : "arming new setup");

   bool allOk = true;
   string comment = "FLASH|" + g_setup.SetupId;

   for(int i = 0; i < g_config.PositionsPerSetup; i++)
   {
      SFlashOrderResult r = CFlashOrders::SendPendingOrder(_Symbol, ORDER_TYPE_BUY_STOP, buyVolPerPos, buyPrice, buySL, g_config.FlashMagicNumber, comment);
      if(r.success)
      {
         int n = ArraySize(g_setup.BuyStopTickets);
         ArrayResize(g_setup.BuyStopTickets, n + 1);
         g_setup.BuyStopTickets[n] = r.ticket;
      }
      else allOk = false;
   }

   for(int i = 0; i < g_config.PositionsPerSetup; i++)
   {
      SFlashOrderResult r = CFlashOrders::SendPendingOrder(_Symbol, ORDER_TYPE_SELL_STOP, sellVolPerPos, sellPrice, sellSL, g_config.FlashMagicNumber, comment);
      if(r.success)
      {
         int n = ArraySize(g_setup.SellStopTickets);
         ArrayResize(g_setup.SellStopTickets, n + 1);
         g_setup.SellStopTickets[n] = r.ticket;
      }
      else allOk = false;
   }

   if(!allOk)
   {
      CFlashLogger::Error("ORDERS", "Partial placement failure - cancelling whatever was placed and returning to WAITING_FOR_ENTRY");
      CFlashOrders::CancelGroup(g_setup.BuyStopTickets);
      CFlashOrders::CancelGroup(g_setup.SellStopTickets);
      g_setup.Reset();
      g_state.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "partial placement failure");
      return false;
   }

   g_state.TransitionTo(FLASH_STATE_ORDERS_ARMED, "both sides placed and verified");
   g_timeframe.MarkRefreshed();
   return true;
}

//+------------------------------------------------------------------+
//| Polls actual broker state for a first fill while ORDERS_ARMED.   |
//| Never relies on OnTradeTransaction ordering alone (Section 6.2). |
//+------------------------------------------------------------------+
void CheckForFillAndHandle()
{
   SFlashRecoverySnapshot snap = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);
   if(snap.OpenPositions == 0)
      return;

   if(snap.ActiveDirection == "MIXED")
   {
      CFlashLogger::Error("ENTRY", "Simultaneous opposite fills detected before cancellation completed - this is an execution exception, not an authorized reversal. Entering recovery.");
      g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "simultaneous opposite fills");
      return;
   }

   g_state.TransitionTo(FLASH_STATE_ENTRY_DETECTED, "first fill detected: " + snap.ActiveDirection);
   g_setup.ActiveDirection = snap.ActiveDirection;
   ArrayFree(g_setup.PositionTickets);
   ArrayCopy(g_setup.PositionTickets, snap.PositionTickets);

   if(PositionSelectByTicket(snap.FirstPositionTicket))
      g_setup.FirstFillPrice = PositionGetDouble(POSITION_PRICE_OPEN);

   g_setup.FilledVolume = 0.0;
   for(int i = 0; i < ArraySize(g_setup.PositionTickets); i++)
      if(PositionSelectByTicket(g_setup.PositionTickets[i]))
         g_setup.FilledVolume += PositionGetDouble(POSITION_VOLUME);
   g_setup.VolumePerPosition = (ArraySize(g_setup.PositionTickets) > 0) ? (g_setup.FilledVolume / ArraySize(g_setup.PositionTickets)) : 0.0;

   g_state.TransitionTo(FLASH_STATE_CANCELLING_OPPOSITE, "cancelling remaining opposite-side orders");

   bool cancelOk;
   if(snap.ActiveDirection == "BUY")
      cancelOk = CFlashOrders::CancelGroup(g_setup.SellStopTickets);
   else
      cancelOk = CFlashOrders::CancelGroup(g_setup.BuyStopTickets);

   if(!cancelOk)
   {
      SFlashRecoverySnapshot recheck = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);
      if(recheck.ActiveDirection == "MIXED")
      {
         CFlashLogger::Error("ORDERS", "Opposite side filled during cancellation - execution exception. Entering recovery.");
         g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "opposite fill raced cancellation");
         return;
      }
      CFlashLogger::Error("ORDERS", "Opposite-order cancellation could not be fully verified. Entering recovery.");
      g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "cancellation unverified");
      return;
   }

   double correctSL = (snap.ActiveDirection == "BUY") ? g_setup.InitialBuySL : g_setup.InitialSellSL;
   bool allProtected = true;
   for(int i = 0; i < ArraySize(g_setup.PositionTickets); i++)
   {
      if(!CFlashOrders::PositionHasProtectiveSL(g_setup.PositionTickets[i]))
      {
         CFlashLogger::Error("ORDERS", StringFormat("Position %I64u missing protective SL after fill - attempting emergency repair", g_setup.PositionTickets[i]));
         if(!CFlashOrders::SetPositionSL(g_setup.PositionTickets[i], correctSL))
            allProtected = false;
      }
   }

   if(!allProtected)
   {
      CFlashLogger::Error("ORDERS", "Could not establish protective SL on all filled positions. Entering recovery.");
      g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "unprotected position after fill");
      return;
   }

   CFlashPersistence::SaveActiveDirection(_Symbol, g_config.FlashMagicNumber, g_setup.ActiveDirection);
   CFlashPersistence::SaveSetupOpenedAt(_Symbol, g_config.FlashMagicNumber, g_setup.SetupOpenedAt);
   g_state.TransitionTo(FLASH_STATE_POSITION_ACTIVE, "position(s) verified active and protected");
}

//+------------------------------------------------------------------+
//| Arms the opposite-direction pending order at the confirmed        |
//| trailing reference once the reversal-eligibility sequence is met. |
//+------------------------------------------------------------------+
void ArmReversalOrder(const bool oldDirectionIsBuy)
{
   double refPrice = CFlashReversal::ReversalReferencePrice(g_setup.LastConfirmedTrailingReference);
   double normalizedRef = CFlashBrokerRules::NormalizeToTick(refPrice, g_specs.tickSize);

   ENUM_ORDER_TYPE newOrderType = oldDirectionIsBuy ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
   bool newDirectionIsBuy = !oldDirectionIsBuy;

   if(!CFlashBrokerRules::ValidatePendingDistance(_Symbol, newOrderType, normalizedRef, g_specs))
   {
      CFlashLogger::Log("REVERSAL", "Reversal reference price currently fails the broker's minimum distance requirement - temporarily unavailable, will retry");
      return;
   }

   double provisionalSL = CFlashReversal::ProtectiveStopForNewDirection(newDirectionIsBuy, normalizedRef, g_config.TrailingStopDistance);
   double volumePerPosition, totalVolume;
   if(!ComputeSetupVolume(newDirectionIsBuy, normalizedRef, provisionalSL, volumePerPosition, totalVolume))
   {
      CFlashLogger::Error("REVERSAL", "Could not size the reversal leg this tick - will retry");
      return;
   }

   double intendedVolume = CFlashReversal::IntendedReversalVolume(totalVolume);
   if(!CFlashBrokerRules::ValidateVolume(intendedVolume, g_specs))
   {
      CFlashLogger::Error("REVERSAL", "Sized reversal volume is invalid for this symbol - reversal not armed this tick");
      return;
   }

   string comment = "FLASHREV|" + g_setup.SetupId + "|" + IntegerToString(g_setup.ReversalCount + 1);
   SFlashOrderResult r = CFlashOrders::SendPendingOrder(_Symbol, newOrderType, intendedVolume, normalizedRef, 0.0, g_config.FlashMagicNumber, comment);
   if(!r.success)
   {
      CFlashLogger::Error("REVERSAL", "Reversal pending order placement failed - will retry on a later tick");
      return;
   }

   g_setup.ReversalPendingTicket = r.ticket;
   g_setup.ReversalPendingDirection = newDirectionIsBuy ? "BUY" : "SELL";
   g_setup.ReversalPendingPrice = normalizedRef;
   CFlashPersistence::SaveReversalTicket(_Symbol, g_config.FlashMagicNumber, r.ticket);
   CFlashLogger::Log("REVERSAL",
      StringFormat("Reversal order armed: %s at %s, volume=%s (setup %s, reversal #%d)",
                   EnumToString(newOrderType), DoubleToString(normalizedRef, g_specs.digits),
                   DoubleToString(intendedVolume, 2), g_setup.SetupId, g_setup.ReversalCount + 1));
}


//+------------------------------------------------------------------+
//| Tick-driven management of an active setup leg: unprotected-SL     |
//| safety net, combined setup profit-target check, trailing stop     |
//| update, and reversal arming / synchronization / execution         |
//| detection - in that priority order, per Stage 2.3's requirement   |
//| that the profit target is evaluated before ordinary trailing/     |
//| reversal updates on every relevant tick.                           |
//+------------------------------------------------------------------+
void ManageActiveSetup()
{
   bool isBuy = (g_setup.ActiveDirection == "BUY");
   double correctSL = isBuy ? g_setup.InitialBuySL : g_setup.InitialSellSL;

   // Detect reversal execution FIRST, before anything below looks at the
   // old-direction position tickets. Live evidence (2026-09-17, 22:03:20)
   // showed the original SL hit and the armed reversal order's fill land
   // in the same tick: when the old-position "fully closed" early-return
   // below ran first, it returned before this function ever reached the
   // check that detects a filled reversal order, cleared persistence, and
   // reset the setup - leaving the brand-new reversal-filled position
   // completely untracked and briefly unprotected until the next restart
   // recovered it. Checking this first means a same-tick SL-hit-plus-
   // reversal-fill now always proceeds into reconciliation instead of
   // being swallowed by the old-position closure branch. A modification
   // request being submitted is never itself treated as synchronization -
   // only this verified disappearance (an actual fill or an actual
   // broker-side removal) drives reconciliation.
   if(g_setup.ReversalPendingTicket != 0 && !OrderSelect(g_setup.ReversalPendingTicket))
   {
      CFlashLogger::Log("REVERSAL",
         StringFormat("Reversal order %I64u is no longer pending - execution detected, entering reconciliation", g_setup.ReversalPendingTicket));
      CFlashPersistence::SaveActiveDirection(_Symbol, g_config.FlashMagicNumber, g_setup.ActiveDirection);
      g_state.TransitionTo(FLASH_STATE_REVERSAL_RECONCILING, "reversal order execution detected");
      return;
   }

   bool anyOpen = false;

   for(int i = 0; i < ArraySize(g_setup.PositionTickets); i++)
   {
      ulong ticket = g_setup.PositionTickets[i];
      if(!PositionSelectByTicket(ticket))
         continue; // this position closed
      anyOpen = true;

      if(PositionGetDouble(POSITION_SL) == 0.0)
      {
         CFlashLogger::Error("ORDERS", StringFormat("Active position %I64u lost its protective SL - emergency repair", ticket));
         double emergencySL = (g_setup.TrailingActive && g_setup.LastConfirmedSL != 0.0) ? g_setup.LastConfirmedSL : correctSL;
         if(!CFlashOrders::SetPositionSL(ticket, emergencySL))
         {
            CFlashLogger::Error("ORDERS", StringFormat("Emergency repair failed for position %I64u. Entering recovery.", ticket));
            g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "unprotected active position, repair failed");
            return;
         }
      }
   }

   if(!anyOpen)
   {
      double finalPL = ComputeSetupRealizedPLSince(g_setup.SetupOpenedAt);
      CFlashLogger::Log("ORDERS",
         StringFormat("Setup %s fully closed (no reversal pending). Final realized P/L=%s (reversals executed=%d).",
                      g_setup.SetupId, DoubleToString(finalPL, 2), g_setup.ReversalCount));
      CFlashPersistence::ClearAll(_Symbol, g_config.FlashMagicNumber);
      g_setup.Reset();
      g_state.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "position closed, setup reconciled");
      return;
   }

   // Combined setup profit target - evaluated before trailing/reversal updates.
   double floatingPL = CFlashProfitTarget::ComputeFloatingPL(g_setup.PositionTickets);
   double realizedPL = ComputeSetupRealizedPLSince(g_setup.SetupOpenedAt);
   double combinedPL = CFlashProfitTarget::CombinedPL(realizedPL, floatingPL);

   if(CFlashProfitTarget::TargetReached(g_config.EnableSetupProfitTarget, combinedPL, g_config.SetupProfitTarget))
   {
      CFlashLogger::Log("PROFIT_TARGET",
         StringFormat("Setup %s combined P/L %s reached target %s - beginning controlled exit",
                      g_setup.SetupId, DoubleToString(combinedPL, 2), DoubleToString(g_config.SetupProfitTarget, 2)));
      g_state.TransitionTo(FLASH_STATE_SETUP_EXIT, "setup profit target reached");
      return;
   }

   // Trailing stop update - only updates LastConfirmedSL from broker-
   // confirmed modifications, never from a requested-but-unverified value.
   CFlashTrailing::UpdateSetup(_Symbol, isBuy, g_setup.FirstFillPrice, g_config.TrailingActivationDistance,
                                g_config.TrailingStopDistance, g_config.MinimumTrailingUpdate, g_specs,
                                g_setup.PositionTickets, g_setup.TrailingActive, g_setup.LastConfirmedSL,
                                g_setup.LastConfirmedTrailingReference);

   CFlashPersistence::SaveTrailingActive(_Symbol, g_config.FlashMagicNumber, g_setup.TrailingActive);
   if(g_setup.TrailingActive)
   {
      CFlashPersistence::SaveLastConfirmedSL(_Symbol, g_config.FlashMagicNumber, g_setup.LastConfirmedSL);
      CFlashPersistence::SaveTrailingReference(_Symbol, g_config.FlashMagicNumber, g_setup.LastConfirmedTrailingReference);
   }

   bool exposurePermitted = NewExposurePermittedNow();

   if(!g_reversalEnabledForAccount)
   {
      // Reversal execution is disabled for this (non-hedging) account -
      // trailing and protective-stop management above continue normally,
      // but Flash never arms a reversal order here.
   }
   else if(g_setup.ReversalPendingTicket == 0)
   {
      bool trailingSLConfirmed = (g_setup.LastConfirmedSL != 0.0);
      bool eligible = CFlashReversal::EligibleToArm(true, true, true, g_setup.TrailingActive, trailingSLConfirmed);
      if(eligible && exposurePermitted)
         ArmReversalOrder(isBuy);
   }
   else
   {
      if(!exposurePermitted)
      {
         if(CFlashOrders::CancelOrder(g_setup.ReversalPendingTicket))
         {
            CFlashLogger::Log("REVERSAL", "Reversal pending order cancelled - new exposure no longer permitted (session ended or a daily limit was reached)");
            g_setup.ReversalPendingTicket = 0;
            g_setup.ReversalPendingDirection = "";
            CFlashPersistence::SaveReversalTicket(_Symbol, g_config.FlashMagicNumber, 0);
         }
         else
         {
            CFlashLogger::Error("REVERSAL", "Could not verify cancellation of the reversal pending order after exposure permission was withdrawn - entering recovery");
            g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "reversal order cancellation unverified");
            return;
         }
      }
      else if(MathAbs(g_setup.ReversalPendingPrice - g_setup.LastConfirmedTrailingReference) > 0.0000001)
      {
         double newRefNormalized = CFlashBrokerRules::NormalizeToTick(g_setup.LastConfirmedTrailingReference, g_specs.tickSize);
         if(CFlashOrders::ModifyPendingOrderPrice(g_setup.ReversalPendingTicket, newRefNormalized, 0.0))
         {
            g_setup.ReversalPendingPrice = newRefNormalized;
            CFlashLogger::Log("REVERSAL", StringFormat("Reversal pending order synchronized to new trailing reference %s", DoubleToString(newRefNormalized, g_specs.digits)));
         }
         else
            CFlashLogger::Error("REVERSAL", "Reversal pending order price synchronization failed this tick - retaining previous reversal price, will retry");
      }
   }

}

//+------------------------------------------------------------------+
//| Reversal reconciliation, per the required 10-step sequence:      |
//| identify remaining old-direction exposure, close it, verify flat, |
//| identify actual new-direction exposure, verify it against the     |
//| intended target, establish and verify the new direction's         |
//| protective stop, then only declare the reversal complete. Uses    |
//| live broker inspection rather than only in-memory tickets so this |
//| also resolves correctly after a restart mid-reversal.              |
//+------------------------------------------------------------------+
void ReconcileReversal()
{
   string oldDirLabel = (g_setup.ActiveDirection != "") ? g_setup.ActiveDirection
                                                          : CFlashPersistence::LoadActiveDirection(_Symbol, g_config.FlashMagicNumber);
   if(oldDirLabel == "")
   {
      CFlashLogger::Error("REVERSAL", "Cannot determine the pre-reversal direction to reconcile against - entering recovery for manual review");
      g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "reversal reconciliation missing direction context");
      return;
   }

   SFlashRecoverySnapshot snap = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);

   bool oldClosed = true;
   for(int i = 0; i < ArraySize(snap.PositionTickets); i++)
   {
      ulong t = snap.PositionTickets[i];
      if(!PositionSelectByTicket(t)) continue;
      string dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      if(dir == oldDirLabel)
      {
         if(!CFlashOrders::ClosePositionMarket(t, "reversal reconciliation - closing remaining old-direction exposure"))
            oldClosed = false;
      }
   }

   if(!oldClosed)
   {
      CFlashLogger::Error("REVERSAL", "Could not verify old-direction exposure is fully closed during reversal reconciliation - will retry");
      return;
   }

   SFlashRecoverySnapshot snap2 = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);
   double actualOldRemaining = 0.0;
   double actualNewVolume = 0.0;
   double newFillPriceSum = 0.0;
   string newDirActual = "";
   ulong newTickets[];

   for(int i = 0; i < ArraySize(snap2.PositionTickets); i++)
   {
      ulong t = snap2.PositionTickets[i];
      if(!PositionSelectByTicket(t)) continue;
      string dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      if(dir == oldDirLabel)
         actualOldRemaining += PositionGetDouble(POSITION_VOLUME);
      else
      {
         newDirActual = dir;
         double vol = PositionGetDouble(POSITION_VOLUME);
         actualNewVolume += vol;
         newFillPriceSum += PositionGetDouble(POSITION_PRICE_OPEN) * vol;
         int n = ArraySize(newTickets);
         ArrayResize(newTickets, n + 1);
         newTickets[n] = t;
      }
   }

   if(!CFlashReversal::OldExposureFullyClosed(actualOldRemaining))
   {
      CFlashLogger::Error("REVERSAL", StringFormat("Old-direction exposure not yet fully closed (%s lots remaining) - will retry", DoubleToString(actualOldRemaining, 2)));
      return;
   }

   if(ArraySize(newTickets) == 0)
   {
      CFlashLogger::Error("REVERSAL",
         "Old-direction exposure is flat but no new-direction position exists after reconciliation - the reversal did not leave new exposure. Entering recovery for manual review rather than inventing a new market entry.");
      g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "reversal left no new-direction exposure");
      return;
   }

   bool newDirectionIsBuy = (newDirActual == "BUY");
   double actualNewFillPrice = newFillPriceSum / actualNewVolume;

   double newSL = CFlashReversal::ProtectiveStopForNewDirection(newDirectionIsBuy, actualNewFillPrice, g_config.TrailingStopDistance);
   double normalizedNewSL = CFlashBrokerRules::NormalizeToTick(newSL, g_specs.tickSize);

   bool allProtected = true;
   for(int i = 0; i < ArraySize(newTickets); i++)
   {
      if(!CFlashOrders::PositionHasProtectiveSL(newTickets[i]))
      {
         if(!CFlashOrders::SetPositionSL(newTickets[i], normalizedNewSL))
            allProtected = false;
      }
   }

   if(!allProtected)
   {
      CFlashLogger::Error("REVERSAL", "Could not establish protective SL on the new-direction position(s) after reversal - entering recovery");
      g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "unprotected new-direction position after reversal");
      return;
   }

   double realizedSoFar = ComputeSetupRealizedPLSince(g_setup.SetupOpenedAt);

   CFlashLogger::Log("REVERSAL",
      StringFormat("Reversal #%d complete for setup %s | %s -> %s | requested reference=%s actual new fill=%s | new SL=%s | setup realized P/L so far=%s",
                   g_setup.ReversalCount + 1, g_setup.SetupId, oldDirLabel, newDirActual,
                   DoubleToString(g_setup.ReversalPendingPrice, g_specs.digits), DoubleToString(actualNewFillPrice, g_specs.digits),
                   DoubleToString(normalizedNewSL, g_specs.digits), DoubleToString(realizedSoFar, 2)));

   g_setup.ResetForNewLeg();
   g_setup.ActiveDirection = newDirActual;
   ArrayCopy(g_setup.PositionTickets, newTickets);
   g_setup.FirstFillPrice = actualNewFillPrice;
   g_setup.FilledVolume = actualNewVolume;
   g_setup.VolumePerPosition = actualNewVolume / ArraySize(newTickets);
   g_setup.LastConfirmedSL = normalizedNewSL;
   g_setup.ReversalCount++;

   CFlashPersistence::SaveActiveDirection(_Symbol, g_config.FlashMagicNumber, g_setup.ActiveDirection);
   CFlashPersistence::SaveTrailingActive(_Symbol, g_config.FlashMagicNumber, false);
   CFlashPersistence::SaveLastConfirmedSL(_Symbol, g_config.FlashMagicNumber, normalizedNewSL);
   CFlashPersistence::SaveReversalTicket(_Symbol, g_config.FlashMagicNumber, 0);
   CFlashPersistence::SaveReversalCount(_Symbol, g_config.FlashMagicNumber, g_setup.ReversalCount);

   g_state.TransitionTo(FLASH_STATE_POSITION_ACTIVE, "reversal reconciled - continuing same logical setup");
}

//+------------------------------------------------------------------+
//| Controlled setup-profit-target exit: cancel any armed reversal    |
//| order, close every remaining position in the setup, verify flat, |
//| and reconcile any exposure that appears mid-exit rather than      |
//| abandoning the controlled close.                                    |
//+------------------------------------------------------------------+
void HandleSetupExit()
{
   // Phase 3 Stage 3.3 - bounded, classified retry replaces the Phase 2
   // fixed-cooldown-only throttle. The budget is per setup (keyed by
   // SetupId) so a fresh setup never inherits an exhausted/escalated
   // budget from a previous one, and so restarting mid-exit (Stage 3.2)
   // re-derives the same budget identity from the setup id rather than
   // resetting attempt counts to zero on every restart.
   string opTag = "SETUP_EXIT:" + g_setup.SetupId;
   if(!g_setupExitBudgetActive || g_setupExitBudget.OperationTag != opTag)
   {
      g_setupExitBudget.Init(opTag);
      g_setupExitBudgetActive = true;
   }

   if(g_setupExitBudget.Escalated)
      return; // already escalated to RECOVERY_REQUIRED below; do not act again silently

   datetime now = TimeCurrent();
   ENUM_FLASH_RETRY_DECISION gate = CFlashExecutionControl::DecideNextAction(g_setupExitBudget, FLASH_EXEC_TEMP_MARKET_CLOSED, now);
   // FLASH_EXEC_TEMP_MARKET_CLOSED is used here only as a retryable
   // placeholder to evaluate timing (budget/window/delay) before any
   // request has actually been sent this pass; the real outcome
   // classification happens after the close attempt below and can
   // still escalate immediately even if this initial timing gate says
   // WAIT was not yet due.
   if(gate == FLASH_RETRY_WAIT)
      return;

   if(g_setup.ReversalPendingTicket != 0)
   {
      if(OrderSelect(g_setup.ReversalPendingTicket))
      {
         CFlashIntent::RequestCancel(_Symbol, g_config.FlashMagicNumber, g_setup.ReversalPendingTicket);
         if(!CFlashOrders::CancelOrder(g_setup.ReversalPendingTicket))
         {
            CFlashDiagnostics::LogRepeatedFailure("EXIT", g_setupExitLastFailKey, g_setupExitFailRepeatCount,
               "CANCEL_REVERSAL_UNVERIFIED", "Could not verify cancellation of the reversal pending order during setup exit - will retry");
            return;
         }
         CFlashIntent::ConfirmCancelled(_Symbol, g_config.FlashMagicNumber);
      }
      CFlashIntent::ClearCancelIntent(_Symbol, g_config.FlashMagicNumber);
      g_setup.ReversalPendingTicket = 0;
      CFlashPersistence::SaveReversalTicket(_Symbol, g_config.FlashMagicNumber, 0);
   }

   SFlashRecoverySnapshot snap = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);

   bool allClosed = true;
   ENUM_FLASH_EXEC_OUTCOME worstOutcome = FLASH_EXEC_FULL_SUCCESS;
   for(int i = 0; i < ArraySize(snap.PositionTickets); i++)
   {
      double volumeBefore = PositionSelectByTicket(snap.PositionTickets[i]) ? PositionGetDouble(POSITION_VOLUME) : 0.0;
      if(volumeBefore <= 0.0) continue; // already gone - nothing to request

      CFlashIntent::RequestClose(_Symbol, g_config.FlashMagicNumber, snap.PositionTickets[i], volumeBefore);
      CFlashExecutionControl::RecordAttempt(g_setupExitBudget, now);
      if(LogTradeRequestDetails)
         CFlashDiagnostics::LogActionRequested("EXIT", "Close position " + IntegerToString((int)snap.PositionTickets[i]), g_setup.SetupId, FLASH_BUILD_ID, g_config.FlashMagicNumber);

      bool closed = CFlashOrders::ClosePositionMarket(snap.PositionTickets[i], "setup profit target exit");
      double volumeAfter = PositionSelectByTicket(snap.PositionTickets[i]) ? PositionGetDouble(POSITION_VOLUME) : 0.0;

      if(closed)
      {
         CFlashIntent::ConfirmClosed(_Symbol, g_config.FlashMagicNumber);
         ENUM_FLASH_CLOSE_OUTCOME co = CFlashIntent::ResolveCloseOutcome(volumeBefore, volumeAfter, g_specs.volumeStep);
         if(co != FLASH_CLOSE_OUTCOME_FULLY_CLOSED)
         {
            // Partial close reconciled honestly - the residual volume is
            // what drives the next loop iteration/tick, never assumed
            // arithmetic. Do not declare the setup closed while any
            // residual remains (Stage 3.3.5).
            allClosed = false;
            CFlashDiagnostics::LogReconciledVolume("EXIT", volumeAfter);
         }
         continue;
      }

      allClosed = false;
      // Classify why the close failed and decide whether resending
      // unchanged could ever help, rather than assuming it can.
      ENUM_FLASH_EXEC_OUTCOME outcome = FLASH_EXEC_OTHER_REJECTED; // ClosePositionMarket does not currently surface the raw retcode to this call site; see limitation note in the Phase 3 report.
      if(!CFlashExecutionControl::IsRetryable(outcome))
         worstOutcome = outcome;
   }

   if(!allClosed)
   {
      ENUM_FLASH_RETRY_DECISION decision = CFlashExecutionControl::DecideNextAction(g_setupExitBudget, worstOutcome, now);
      CFlashExecutionControl::LogDecision(g_setupExitBudget, worstOutcome, decision);

      if(decision == FLASH_RETRY_ESCALATE_EXHAUSTED || decision == FLASH_RETRY_ESCALATE_NOT_RETRYABLE)
      {
         g_setupExitBudget.Escalated = true;
         CFlashIntent::SaveRecoveryReasonCode(_Symbol, g_config.FlashMagicNumber, "SETUP_EXIT_RETRY_BUDGET_EXHAUSTED");
         CFlashLogger::Error("SAFETY",
            StringFormat("Setup exit retry budget exhausted or non-retryable failure for %s after %d attempts over %ds - escalating to RECOVERY_REQUIRED. No further automated close attempts will be made without operator review.",
                         g_setup.SetupId, g_setupExitBudget.AttemptCount, (int)(now - g_setupExitBudget.FirstAttemptAt)));
         g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "setup exit retry budget exhausted");
         return;
      }

      CFlashDiagnostics::LogRepeatedFailure("EXIT", g_setupExitLastFailKey, g_setupExitFailRepeatCount,
         "CLOSE_UNVERIFIED", "Could not verify all setup positions are closed - will retry within budget");
      return;
   }

   SFlashRecoverySnapshot recheck = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);
   if(recheck.OpenPositions > 0)
   {
      CFlashLogger::Log("EXIT", "New exposure appeared during exit reconciliation (e.g. a race with a pending order) - continuing the controlled exit rather than abandoning it");
      return;
   }

   double finalPL = ComputeSetupRealizedPLSince(g_setup.SetupOpenedAt);
   CFlashDiagnostics::LogFinalConfirmation("EXIT", g_setup.SetupId, recheck.OpenPositions, recheck.PendingBuyStops + recheck.PendingSellStops);
   CFlashLogger::Log("EXIT",
      StringFormat("Setup %s profit-target exit complete | final realized P/L=%s | reversals executed=%d",
                   g_setup.SetupId, DoubleToString(finalPL, 2), g_setup.ReversalCount));

   CFlashIntent::ClearCloseIntent(_Symbol, g_config.FlashMagicNumber);
   CFlashIntent::ClearCancelIntent(_Symbol, g_config.FlashMagicNumber);
   g_setupExitBudgetActive = false;
   CFlashPersistence::ClearAll(_Symbol, g_config.FlashMagicNumber);
   g_setup.Reset();
   g_state.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "setup profit target exit verified complete");
}


//+------------------------------------------------------------------+
//| Dispatches OnInit startup recovery based on actual broker state, |
//| now also recovering persisted Phase 2 trailing/reversal metadata |
//| when an active protected position is adopted.                     |
//+------------------------------------------------------------------+
void HandleStartupRecovery(const SFlashRecoverySnapshot &snap)
{
   switch(snap.Scenario)
   {
      case FLASH_RECOVERY_NONE:
         g_setup.Reset();
         g_state.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "clean start, no existing exposure");
         break;

      case FLASH_RECOVERY_VALID_PENDING_PAIR:
         g_setup.Reset();
         ArrayCopy(g_setup.BuyStopTickets, snap.BuyStopTickets);
         ArrayCopy(g_setup.SellStopTickets, snap.SellStopTickets);
         g_setup.MagicNumber = g_config.FlashMagicNumber;
         g_setup.Symbol = _Symbol;
         g_setup.CreatedAt = TimeCurrent();
         g_setup.SetupOpenedAt = TimeCurrent();
         if(OrderSelect(snap.BuyStopTickets[0]))  g_setup.OriginalBuyStopPrice  = OrderGetDouble(ORDER_PRICE_OPEN);
         if(OrderSelect(snap.SellStopTickets[0])) g_setup.OriginalSellStopPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         g_setup.InitialBuySL  = g_setup.OriginalSellStopPrice;
         g_setup.InitialSellSL = g_setup.OriginalBuyStopPrice;
         CFlashLogger::Log("RECOVERY", "Existing valid pending pair adopted - resuming ORDERS_ARMED without placing duplicate orders");
         g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "existing pending pair found at startup");
         g_state.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "adopting existing pending pair (intermediate)");
         g_state.TransitionTo(FLASH_STATE_PLACING_ORDERS, "adopting existing pending pair (intermediate)");
         g_state.TransitionTo(FLASH_STATE_ORDERS_ARMED, "adopted existing pending pair, verified present");
         break;

      case FLASH_RECOVERY_INCOMPLETE_PENDING:
      {
         CFlashLogger::Error("RECOVERY", "Incomplete pending pair found at startup (only one side present). Cancelling the stray order to avoid a one-sided setup.");
         bool ok = true;
         if(ArraySize(snap.BuyStopTickets) > 0)
         {
            ulong t[]; ArrayCopy(t, snap.BuyStopTickets);
            if(!CFlashOrders::CancelGroup(t)) ok = false;
         }
         if(ArraySize(snap.SellStopTickets) > 0)
         {
            ulong t[]; ArrayCopy(t, snap.SellStopTickets);
            if(!CFlashOrders::CancelGroup(t)) ok = false;
         }
         g_setup.Reset();
         if(ok)
            g_state.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "stray incomplete pending order cancelled and verified");
         else
         {
            CFlashLogger::Error("RECOVERY", "Could not verify cancellation of the stray incomplete pending order.");
            g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "incomplete pending order could not be safely cleared");
         }
         break;
      }

      case FLASH_RECOVERY_ACTIVE_PROTECTED:
      {
         g_setup.Reset();
         ArrayCopy(g_setup.PositionTickets, snap.PositionTickets);
         g_setup.ActiveDirection = snap.ActiveDirection;
         g_setup.MagicNumber = g_config.FlashMagicNumber;
         g_setup.Symbol = _Symbol;
         // Minor defect fix (live evidence 2026-09-17): this branch never
         // set SetupId, so log lines for a recovery-adopted position
         // showed a blank setup identifier ("Setup  fully closed...").
         // Synthesize one the same way FLASH_RECOVERY_UNEXPECTED_OPPOSITE
         // already does, so every setup - fresh or adopted - is traceable.
         g_setup.SetupId = "RECOVERED-" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);

         g_setup.FilledVolume = 0.0;
         for(int i = 0; i < ArraySize(g_setup.PositionTickets); i++)
            if(PositionSelectByTicket(g_setup.PositionTickets[i]))
               g_setup.FilledVolume += PositionGetDouble(POSITION_VOLUME);
         g_setup.VolumePerPosition = (ArraySize(g_setup.PositionTickets) > 0) ? (g_setup.FilledVolume / ArraySize(g_setup.PositionTickets)) : 0.0;

         double actualBrokerSL = 0.0;
         if(PositionSelectByTicket(snap.FirstPositionTicket))
         {
            g_setup.FirstFillPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            actualBrokerSL = PositionGetDouble(POSITION_SL);
            if(snap.ActiveDirection == "BUY") g_setup.InitialBuySL = actualBrokerSL; else g_setup.InitialSellSL = actualBrokerSL;
         }

         // Phase 2: reconcile persisted trailing/reversal metadata against
         // actual broker state. Never restore an older/less favorable SL
         // over a newer broker-confirmed one, and never reapply the frozen
         // Phase 1 initial SL if the position was already trailing.
         bool persistedTrailingActive = CFlashPersistence::LoadTrailingActive(_Symbol, g_config.FlashMagicNumber);
         g_setup.TrailingActive = persistedTrailingActive;
         if(persistedTrailingActive)
         {
            double persistedSL = CFlashPersistence::LoadLastConfirmedSL(_Symbol, g_config.FlashMagicNumber);
            double persistedRef = CFlashPersistence::LoadTrailingReference(_Symbol, g_config.FlashMagicNumber);
            bool isBuy = (snap.ActiveDirection == "BUY");
            double best;
            if(persistedSL == 0.0) best = actualBrokerSL;
            else if(actualBrokerSL == 0.0) best = persistedSL;
            else best = isBuy ? MathMax(persistedSL, actualBrokerSL) : MathMin(persistedSL, actualBrokerSL);
            g_setup.LastConfirmedSL = best;
            g_setup.LastConfirmedTrailingReference = (persistedRef != 0.0) ? persistedRef : best;
            CFlashLogger::Log("RECOVERY",
               StringFormat("Restart recovery: trailing was active, reconciled SL=%s (persisted=%s, broker=%s)",
                            DoubleToString(best, g_specs.digits), DoubleToString(persistedSL, g_specs.digits), DoubleToString(actualBrokerSL, g_specs.digits)));
         }

         g_setup.ReversalCount = CFlashPersistence::LoadReversalCount(_Symbol, g_config.FlashMagicNumber);

         datetime persistedOpenedAt = CFlashPersistence::LoadSetupOpenedAt(_Symbol, g_config.FlashMagicNumber);
         if(persistedOpenedAt != 0)
            g_setup.SetupOpenedAt = persistedOpenedAt;
         else if(PositionSelectByTicket(snap.FirstPositionTicket))
            g_setup.SetupOpenedAt = (datetime)PositionGetInteger(POSITION_TIME);
         else
            g_setup.SetupOpenedAt = TimeCurrent();

         ulong persistedReversalTicket = CFlashPersistence::LoadReversalTicket(_Symbol, g_config.FlashMagicNumber);
         if(persistedReversalTicket != 0 && OrderSelect(persistedReversalTicket))
         {
            g_setup.ReversalPendingTicket = persistedReversalTicket;
            g_setup.ReversalPendingPrice = OrderGetDouble(ORDER_PRICE_OPEN);
            g_setup.ReversalPendingDirection = (OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_STOP) ? "BUY" : "SELL";
            CFlashLogger::Log("RECOVERY", StringFormat("Restart recovery: adopted existing reversal pending order %I64u", persistedReversalTicket));
         }
         else if(persistedReversalTicket != 0)
         {
            CFlashLogger::Log("RECOVERY",
               "Restart recovery: a reversal order was persisted but is no longer pending (may have executed, been cancelled, or expired while Flash was offline). Not re-arming automatically - normal reversal eligibility checks will re-arm one only if current conditions still call for it.");
            CFlashPersistence::SaveReversalTicket(_Symbol, g_config.FlashMagicNumber, 0);
         }

         CFlashLogger::Log("RECOVERY", "Existing protected position adopted - resuming POSITION_ACTIVE without creating a new setup");
         g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "existing protected position found at startup");
         g_state.TransitionTo(FLASH_STATE_POSITION_ACTIVE, "adopted existing protected position, protection verified");
         break;
      }

      case FLASH_RECOVERY_ACTIVE_UNPROTECTED:
         CFlashLogger::Error("RECOVERY",
            "Active Flash position found at startup WITHOUT a protective SL, and the original opposite entry "
            "level (needed to derive the correct initial SL) cannot be reliably recovered after a restart. "
            "An unrecoverable level must not be invented. Blocking new entries. This position requires manual review.");
         g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "unprotected position, original level unrecoverable");
         break;

      case FLASH_RECOVERY_UNEXPECTED_OPPOSITE:
      {
         string persistedDir = CFlashPersistence::LoadActiveDirection(_Symbol, g_config.FlashMagicNumber);
         if(persistedDir != "" && g_reversalEnabledForAccount)
         {
            CFlashLogger::Error("RECOVERY",
               "Exposure in both directions found at startup, consistent with a restart during an in-progress reversal. Attempting controlled reversal reconciliation rather than leaving this for indefinite manual review.");
            g_setup.Reset();
            g_setup.MagicNumber = g_config.FlashMagicNumber;
            g_setup.Symbol = _Symbol;
            g_setup.ActiveDirection = persistedDir;
            g_setup.SetupId = "RECOVERED-" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
            datetime persistedOpenedAt2 = CFlashPersistence::LoadSetupOpenedAt(_Symbol, g_config.FlashMagicNumber);
            g_setup.SetupOpenedAt = (persistedOpenedAt2 != 0) ? persistedOpenedAt2 : TimeCurrent();
            g_setup.ReversalCount = CFlashPersistence::LoadReversalCount(_Symbol, g_config.FlashMagicNumber);
            g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "unexpected opposite exposure at startup, mid-reversal suspected");
            g_state.TransitionTo(FLASH_STATE_REVERSAL_RECONCILING, "attempting reversal reconciliation from persisted direction metadata");
         }
         else
         {
            CFlashLogger::Error("RECOVERY",
               "Exposure in BOTH directions found at startup - not an authorized state and no persisted reversal-in-progress metadata was found. Blocking new entries. This requires manual review before Flash resumes.");
            g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "unexpected opposite exposure at startup");
         }
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   CFlashLogger::Init(EnableDetailedLogging);
   CFlashLogger::Log("INIT", "Flash EA Phase 2 initializing | build=" + FLASH_BUILD_ID);

   if(EnablePhase1SelfTest)
      RunPhase1SelfTestSuite();

   CaptureConfig();

   if(!CFlashConfig::Validate(g_config))
   {
      CFlashLogger::Error("INIT", "Input validation failed - Flash EA will not trade. See CONFIG errors above.");
      g_state.TransitionTo(FLASH_STATE_TRADING_BLOCKED, "input validation failed");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_symbol.Init(_Symbol);
   if(!g_symbol.IsBasicallyTradeable())
   {
      CFlashLogger::Error("INIT", "Symbol failed basic tradeability check - Flash EA will not trade.");
      g_state.TransitionTo(FLASH_STATE_TRADING_BLOCKED, "symbol not tradeable");
      return INIT_FAILED;
   }
   g_symbol.LogSnapshot();

   if(!CFlashBrokerRules::ValidateSymbolSupported(_Symbol))
   {
      g_state.TransitionTo(FLASH_STATE_TRADING_BLOCKED, "unsupported symbol");
      return INIT_FAILED;
   }

   if(!CFlashBrokerRules::GetSpecs(_Symbol, g_specs))
   {
      CFlashLogger::Error("INIT", "Could not retrieve broker symbol specifications - Flash EA will not trade.");
      g_state.TransitionTo(FLASH_STATE_TRADING_BLOCKED, "broker specs unavailable");
      return INIT_FAILED;
   }

   if(!CFlashBrokerRules::ValidateAccountCompatibility(g_config.PositionsPerSetup))
   {
      g_state.TransitionTo(FLASH_STATE_TRADING_BLOCKED, "account configuration unsupported");
      return INIT_FAILED;
   }

   g_reversalEnabledForAccount = CFlashBrokerRules::IsHedgingAccount();
   if(!g_reversalEnabledForAccount)
      CFlashLogger::Log("INIT",
         "Account is not a hedging account - Phase 2 reversal execution is disabled for this account type. "
         "Trailing and protective-stop management continue normally; no reversal orders will ever be armed, "
         "so a flattening transaction on this account type is never treated as a completed reversal.");

   g_isOwner = CFlashOwnership::TryClaim(_Symbol, g_config.FlashMagicNumber, ChartID());
   if(!g_isOwner)
   {
      g_ownershipBlocked = true;
      g_state.TransitionTo(FLASH_STATE_TRADING_BLOCKED, "ownership conflict - another Flash instance active on this symbol/magic");
      CFlashLogger::Log("INIT", "Flash EA initialization halted by ownership conflict. Will retry the claim each tick; no orders will be placed until it succeeds.");
      return INIT_SUCCEEDED;
   }

   g_timeframe.Init(_Symbol);
   g_timeframe.LogSnapshot();

   SFlashRecoverySnapshot recovery = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);
   HandleStartupRecovery(recovery);

   // Phase 3 Stage 3.1 - an additional, more general reconciliation pass
   // on top of Phase 2's own startup classifier above. This never
   // overrides a decision HandleStartupRecovery already made in this
   // same OnInit; it only escalates further (to RECOVERY_REQUIRED /
   // TRADING_BLOCKED) if IT independently finds a state HandleStartupRecovery
   // does not already cover (an orphaned order, an exposure discrepancy,
   // or an ownership ambiguity), and it never de-escalates a block that
   // Phase 2 already applied.
   RunReconciliationCheck("INIT");

   CFlashLogger::Log("INIT",
      StringFormat("Flash EA Phase 2+3 initialization complete | state=%s | magic=%d | symbol=%s | timeframe=%s | reversalEnabled=%s | build=%s",
                    g_state.CurrentString(), (int)g_config.FlashMagicNumber, _Symbol, g_timeframe.TimeframeCode(),
                    g_reversalEnabledForAccount ? "true" : "false", FLASH_BUILD_ID));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Phase 3 Stage 3.1 - runs a reconciliation snapshot against live   |
//| broker state and applies only the actions the fixed               |
//| classification-to-action table (FlashReconRequiredAction) permits.|
//| Never opens, closes, or modifies anything itself beyond the two   |
//| narrowly-scoped auto-repairs the table allows (re-attach a known  |
//| SL; cancel a stray/orphaned order) - anything else blocks new     |
//| exposure or escalates, exactly as Stage 3.1.4/3.1.6 require.      |
//+------------------------------------------------------------------+
void RunReconciliationCheck(const string trigger)
{
   bool closeOutstanding = CFlashIntent::CloseIntentOutstanding(_Symbol, g_config.FlashMagicNumber);
   bool cancelOutstanding = CFlashIntent::CancelIntentOutstanding(_Symbol, g_config.FlashMagicNumber);

   SFlashReconSnapshot snap = CFlashReconciliation::Inspect(_Symbol, g_config.FlashMagicNumber, g_isOwner,
      FLASH_BUILD_ID, g_setup.SetupId, g_state.CurrentString(), g_setup.ActiveDirection,
      closeOutstanding, cancelOutstanding);

   if(LogBrokerReconciliationEvents)
      CFlashReconciliation::LogSnapshot(snap);

   ENUM_FLASH_RECON_ACTION action = FlashReconRequiredAction(snap.Status);

   switch(action)
   {
      case RECON_ACTION_PROCEED:
         return;

      case RECON_ACTION_AUTO_REPAIR:
         // Deliberately not implemented as an automatic broker-side
         // write in this integration pass - Stage 3.2.5 requires any
         // restored protection to be validated against actual broker
         // rules and verified afterward, and Stage 2 already has a
         // narrower, proven emergency-SL-repair path inside
         // ManageActiveSetup() for the position-missing-SL case. Rather
         // than run two independent repair paths against the same
         // position, this trigger logs the finding and defers the
         // actual repair to that existing, already-tested path, and to
         // the existing orphaned-order cancellation already present in
         // HandleStartupRecovery for the pending-order case. This is an
         // explicit, disclosed limitation, not a silent no-op.
         CFlashLogger::Log("RECONCILE",
            StringFormat("[%s] Reconciliation found %s (auto-repair eligible) - deferring to the existing Phase 2 repair path rather than acting twice on the same condition.",
                         trigger, FlashReconStatusToString(snap.Status)));
         return;

      case RECON_ACTION_BLOCK_NEW_EXPOSURE:
         if(g_state.Current() != FLASH_STATE_RECOVERY_REQUIRED && g_state.Current() != FLASH_STATE_TRADING_BLOCKED
            && g_state.Current() != FLASH_STATE_REVERSAL_RECONCILING)
         {
            CFlashLogger::Error("RECONCILE",
               StringFormat("[%s] Reconciliation requires blocking new exposure: %s. Existing state machine logic must resolve this before further entries.", trigger, FlashReconStatusToString(snap.Status)));
         }
         return;

      case RECON_ACTION_ESCALATE:
      default:
         if(g_state.Current() != FLASH_STATE_RECOVERY_REQUIRED)
         {
            CFlashLogger::Error("RECONCILE",
               StringFormat("[%s] Reconciliation escalation: %s | %s. Blocking all further automated action pending operator review.",
                            trigger, FlashReconStatusToString(snap.Status), snap.AmbiguityReason));
            CFlashIntent::SaveRecoveryReasonCode(_Symbol, g_config.FlashMagicNumber, FlashReconStatusToString(snap.Status));
            g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "Phase 3 reconciliation escalation: " + FlashReconStatusToString(snap.Status));
         }
         return;
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   if(g_ownershipBlocked)
   {
      if(CFlashOwnership::TryClaim(_Symbol, g_config.FlashMagicNumber, ChartID()))
      {
         g_isOwner = true;
         g_ownershipBlocked = false;
         CFlashLogger::Log("OWNERSHIP", "Conflict cleared - this instance now owns the symbol/magic. Re-running startup recovery.");
         SFlashRecoverySnapshot recovery = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);
         HandleStartupRecovery(recovery);
      }
      return; // still blocked (or just reclaimed and will act from next tick)
   }

   if(g_isOwner)
      CFlashOwnership::Heartbeat(_Symbol, g_config.FlashMagicNumber, ChartID());

   ENUM_FLASH_STATE state = g_state.Current();

   if(state == FLASH_STATE_TRADING_BLOCKED)
      return;

   bool isNewBar = g_timeframe.IsNewBar();

   if(isNewBar)
      CFlashLogger::Debug("TICK",
         StringFormat("New %s bar | state=%s | Bid=%s Ask=%s",
                       g_timeframe.TimeframeCode(), g_state.CurrentString(),
                       DoubleToString(g_symbol.Bid(), g_symbol.Digits()),
                       DoubleToString(g_symbol.Ask(), g_symbol.Digits())));

   if(state == FLASH_STATE_RECOVERY_REQUIRED)
      return; // Flash does not auto-retry recovery; requires review, see Journal RECOVERY entries

   if(state == FLASH_STATE_WAITING_FOR_ENTRY)
   {
      // Only one active logical setup at a time - guaranteed by state:
      // arming only happens from WAITING_FOR_ENTRY, which is only reached
      // once any prior setup is fully resolved.
      PlaceOrRefreshSetup(false);
      return;
   }

   if(state == FLASH_STATE_ORDERS_ARMED)
   {
      if(!NewExposurePermittedNow())
      {
         CFlashLogger::Log("ENTRY", "New exposure no longer permitted (session ended or a daily limit was reached) - cancelling the untriggered initial pending pair");
         if(CFlashOrders::CancelGroup(g_setup.BuyStopTickets) && CFlashOrders::CancelGroup(g_setup.SellStopTickets))
         {
            g_setup.Reset();
            g_state.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "untriggered pending pair cancelled - exposure no longer permitted");
         }
         else
         {
            CFlashLogger::Error("ENTRY", "Could not verify cancellation of the untriggered pending pair - entering recovery");
            g_state.TransitionTo(FLASH_STATE_RECOVERY_REQUIRED, "pending pair cancellation unverified after exposure permission withdrawn");
         }
         return;
      }

      CheckForFillAndHandle();
      if(g_state.Current() == FLASH_STATE_ORDERS_ARMED && isNewBar && g_timeframe.RefreshOwedForCurrentBar())
         PlaceOrRefreshSetup(true);
      return;
   }

   if(state == FLASH_STATE_POSITION_ACTIVE)
   {
      ManageActiveSetup();
      return;
   }

   if(state == FLASH_STATE_REVERSAL_RECONCILING)
   {
      ReconcileReversal();
      return;
   }

   if(state == FLASH_STATE_SETUP_EXIT)
   {
      HandleSetupExit();
      return;
   }
}

//+------------------------------------------------------------------+
//| Trade transaction event handler - visibility only. Reconciliation |
//| is driven by the verified polling in CheckForFillAndHandle() /    |
//| ManageActiveSetup() / ReconcileReversal() / HandleSetupExit(),    |
//| never by assumed transaction ordering.                             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   CFlashLogger::Debug("TXN",
      StringFormat("OnTradeTransaction | type=%d | order=%I64u | position=%I64u",
                    (int)trans.type, trans.order, trans.position));

   // Phase 3 Stage 3.1 - re-run reconciliation on the transaction types
   // that can change what the broker actually holds: a deal being added
   // (a fill, full or partial), a position being modified (e.g. an SL
   // change succeeding or failing to apply), or a history add (an order
   // being finally removed/filled/cancelled). Placing/updating a pending
   // order (TRADE_TRANSACTION_ORDER_ADD/UPDATE) alone does not yet change
   // broker exposure, so it does not trigger a re-check on its own.
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || trans.type == TRADE_TRANSACTION_POSITION
      || trans.type == TRADE_TRANSACTION_HISTORY_ADD)
   {
      RunReconciliationCheck("TXN");
   }
}

//+------------------------------------------------------------------+
//| Expert deinitialization function - logs only. Never closes        |
//| positions or removes protective stops on detachment. Persisted    |
//| Phase 2 metadata is deliberately left intact so a restart can      |
//| reconcile against it - it is only cleared once a setup is fully   |
//| and verifiably closed.                                             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CFlashLogger::Log("DEINIT", StringFormat("Flash EA deinitializing | reason=%d | last state=%s",
                                             reason, g_state.CurrentString()));
   if(g_isOwner)
      CFlashOwnership::Release(_Symbol, g_config.FlashMagicNumber, ChartID());
}

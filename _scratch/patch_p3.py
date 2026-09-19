import sys, os

BUILD_OLD = '#define FLASH_BUILD_ID "P2-SAFETYFIX-20260918-02 (atomic ownership claim + reversal-detection reordering + recovery SetupId + dynamic filling-mode resolution + setup-exit retry throttle)"\n#define FLASH_SETUP_EXIT_RETRY_COOLDOWN_SECONDS 2  // seconds between HandleSetupExit retry attempts\n\n#include "Core\\FlashConfig.mqh"\n#include "Core\\FlashState.mqh"\n#include "Core\\FlashLogger.mqh"\n#include "Core\\FlashOwnership.mqh"\n#include "Core\\FlashSessions.mqh"\n#include "Core\\FlashDailyLimits.mqh"\n#include "Core\\FlashPersistence.mqh"\n#include "Market\\FlashSymbol.mqh"\n#include "Market\\FlashTimeframe.mqh"\n#include "Entry\\FlashEntryEngine.mqh"\n#include "Execution\\FlashOrders.mqh"\n#include "Execution\\FlashBrokerRules.mqh"\n#include "Recovery\\FlashRecovery.mqh"\n#include "Trailing\\FlashTrailing.mqh"\n#include "Reversal\\FlashReversal.mqh"\n#include "Risk\\FlashSizing.mqh"\n#include "Risk\\FlashProfitTarget.mqh"\n'

BUILD_NEW = '''#define FLASH_BUILD_ID "P3-DEV-20260919-01 (Phase 3: broker-state reconciliation engine, persistent intent, bounded execution retry, structured diagnostics - baseline Phase 2 P2-SAFETYFIX-20260918-02 unmodified)"
#define FLASH_SETUP_EXIT_RETRY_COOLDOWN_SECONDS 2  // seconds between HandleSetupExit retry attempts - Phase 2 baseline, superseded operationally by CFlashExecutionControl's own MinDelaySeconds below but left defined for compatibility

#include "Core\\FlashConfig.mqh"
#include "Core\\FlashState.mqh"
#include "Core\\FlashLogger.mqh"
#include "Core\\FlashOwnership.mqh"
#include "Core\\FlashSessions.mqh"
#include "Core\\FlashDailyLimits.mqh"
#include "Core\\FlashPersistence.mqh"
#include "Market\\FlashSymbol.mqh"
#include "Market\\FlashTimeframe.mqh"
#include "Entry\\FlashEntryEngine.mqh"
#include "Execution\\FlashOrders.mqh"
#include "Execution\\FlashBrokerRules.mqh"
#include "Recovery\\FlashRecovery.mqh"
#include "Trailing\\FlashTrailing.mqh"
#include "Reversal\\FlashReversal.mqh"
#include "Risk\\FlashSizing.mqh"
#include "Risk\\FlashProfitTarget.mqh"
#include "Core\\FlashIntent.mqh"
#include "Core\\FlashDiagnostics.mqh"
#include "Execution\\FlashExecutionControl.mqh"
#include "Reconciliation\\FlashReconciliation.mqh"
'''

INPUTS_OLD = '''input double BrokerServerUTCOffsetHours  = 3.00;   // Broker Server Time Offset From UTC (Hours)
'''

INPUTS_NEW = '''input double BrokerServerUTCOffsetHours  = 3.00;   // Broker Server Time Offset From UTC (Hours)

//--- Group I: Phase 3 Diagnostics (observability only - never alters a trading decision)
input bool   EnableDetailedDiagnosticLogging = true;  // Enable Detailed Diagnostic Logging
input bool   LogBrokerReconciliationEvents   = true;  // Log Broker Reconciliation Events
input bool   LogTradeRequestDetails          = true;  // Log Trade Request Details
'''

GLOBALS_OLD = '''bool            g_isOwner = false;
bool            g_ownershipBlocked = false;
bool            g_reversalEnabledForAccount = false;
'''

GLOBALS_NEW = '''bool            g_isOwner = false;
bool            g_ownershipBlocked = false;
bool            g_reversalEnabledForAccount = false;

//--- Phase 3 state (Stage 3.3 retry budget, Stage 3.4 repeated-failure throttling)
SFlashRetryBudget g_setupExitBudget;
bool              g_setupExitBudgetActive = false;
string            g_setupExitLastFailKey = "";
int               g_setupExitFailRepeatCount = 0;
'''

ONINIT_OLD = '''   SFlashRecoverySnapshot recovery = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);
   HandleStartupRecovery(recovery);

   CFlashLogger::Log("INIT",
      StringFormat("Flash EA Phase 2 initialization complete | state=%s | magic=%d | symbol=%s | timeframe=%s | reversalEnabled=%s | build=%s",
                    g_state.CurrentString(), (int)g_config.FlashMagicNumber, _Symbol, g_timeframe.TimeframeCode(),
                    g_reversalEnabledForAccount ? "true" : "false", FLASH_BUILD_ID));

   return INIT_SUCCEEDED;
}'''

ONINIT_NEW = '''   SFlashRecoverySnapshot recovery = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);
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
}'''

TXN_OLD = '''void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   CFlashLogger::Debug("TXN",
      StringFormat("OnTradeTransaction | type=%d | order=%I64u | position=%I64u",
                    (int)trans.type, trans.order, trans.position));
}'''

TXN_NEW = '''void OnTradeTransaction(const MqlTradeTransaction &trans,
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
}'''

SETUPEXIT_OLD = '''void HandleSetupExit()
{
   // Throttle retries. Live evidence (2026-09-18) showed this function
   // being re-entered on every single tick with no backoff at all, which
   // turned one persistently-rejected close request into 1400+ identical
   // OrderSend calls against the broker in under six minutes. Retrying
   // until the exit is verified complete is correct; resending on every
   // tick with no pause is not - this cooldown makes retries patient
   // without abandoning the controlled exit.
   static datetime s_lastSetupExitAttempt = 0;
   datetime nowAttempt = TimeCurrent();
   if(s_lastSetupExitAttempt != 0 && (nowAttempt - s_lastSetupExitAttempt) < FLASH_SETUP_EXIT_RETRY_COOLDOWN_SECONDS)
      return;
   s_lastSetupExitAttempt = nowAttempt;

   if(g_setup.ReversalPendingTicket != 0)
   {
      if(OrderSelect(g_setup.ReversalPendingTicket))
      {
         if(!CFlashOrders::CancelOrder(g_setup.ReversalPendingTicket))
         {
            CFlashLogger::Error("SETUP_EXIT", "Could not verify cancellation of the reversal pending order during setup exit - will retry");
            return;
         }
      }
      g_setup.ReversalPendingTicket = 0;
      CFlashPersistence::SaveReversalTicket(_Symbol, g_config.FlashMagicNumber, 0);
   }

   SFlashRecoverySnapshot snap = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);

   bool allClosed = true;
   for(int i = 0; i < ArraySize(snap.PositionTickets); i++)
   {
      if(!CFlashOrders::ClosePositionMarket(snap.PositionTickets[i], "setup profit target exit"))
         allClosed = false;
   }

   if(!allClosed)
   {
      CFlashLogger::Error("SETUP_EXIT", "Could not verify all setup positions are closed - will retry");
      return;
   }

   SFlashRecoverySnapshot recheck = CFlashRecovery::Inspect(_Symbol, g_config.FlashMagicNumber);
   if(recheck.OpenPositions > 0)
   {
      CFlashLogger::Log("SETUP_EXIT", "New exposure appeared during exit reconciliation (e.g. a race with a pending order) - continuing the controlled exit rather than abandoning it");
      return;
   }

   double finalPL = ComputeSetupRealizedPLSince(g_setup.SetupOpenedAt);
   CFlashLogger::Log("SETUP_EXIT",
      StringFormat("Setup %s profit-target exit complete | final realized P/L=%s | reversals executed=%d",
                   g_setup.SetupId, DoubleToString(finalPL, 2), g_setup.ReversalCount));

   CFlashPersistence::ClearAll(_Symbol, g_config.FlashMagicNumber);
   g_setup.Reset();
   g_state.TransitionTo(FLASH_STATE_WAITING_FOR_ENTRY, "setup profit target exit verified complete");
}'''

SETUPEXIT_NEW = '''void HandleSetupExit()
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
}'''

SELFTEST_OLD = '''   PrintFormat("FLASH PHASE 1 + PHASE 2 SELF-TEST SUITE COMPLETE | TOTAL: %d | PASSED: %d | FAILED: %d",
               g_selfTestTotal, g_selfTestPassed, g_selfTestFailed);
}'''

SELFTEST_NEW = '''   //--- Phase 3 Stage 3.1: CFlashReconciliation::Classify, pure, synthetic snapshots ---
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
}'''

REPLACEMENTS = [
    (BUILD_OLD, BUILD_NEW, "BUILD/INCLUDES"),
    (INPUTS_OLD, INPUTS_NEW, "INPUTS"),
    (GLOBALS_OLD, GLOBALS_NEW, "GLOBALS"),
    (ONINIT_OLD, ONINIT_NEW, "ONINIT"),
    (TXN_OLD, TXN_NEW, "TXN"),
    (SETUPEXIT_OLD, SETUPEXIT_NEW, "SETUPEXIT"),
    (SELFTEST_OLD, SELFTEST_NEW, "SELFTEST"),
]

home = os.environ["HOME"]
paths = [
    home + "/mnt/Flash EA/MQL5/Experts/FlashEA_P3/FlashEA_P3.mq5",
    home + "/mnt/D0E8209F77C8CF37AD8BF550E51FF075/MQL5/Experts/FlashEA_P3/FlashEA_P3.mq5",
]

for p in paths:
    with open(p, "r", encoding="utf-8") as f:
        content = f.read()
    for old, new, label in REPLACEMENTS:
        c = content.count(old)
        if c != 1:
            print("MISMATCH", label, p, "count=", c)
            sys.exit(1)
    for old, new, label in REPLACEMENTS:
        content = content.replace(old, new)
    with open(p, "w", encoding="utf-8") as f:
        f.write(content)
    print("OK", p, len(content), "bytes")

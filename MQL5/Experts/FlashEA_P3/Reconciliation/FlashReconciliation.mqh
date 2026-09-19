//+------------------------------------------------------------------+
//| FlashReconciliation.mqh                                          |
//| Phase 3 Stage 3.1 - Broker-State Reconciliation Engine            |
//|                                                                    |
//| Compares Flash's internal setup state against actual MT5 broker   |
//| inventory (positions, pending orders, and recent history) and     |
//| classifies the result before Flash is permitted to make another   |
//| exposure-increasing decision. This does not replace the Phase 2   |
//| startup classifier (Recovery/FlashRecovery.mqh, six scenarios,    |
//| startup-only) - it generalizes the same discipline (never trust   |
//| an internal ticket array alone; always re-read the broker) into a |
//| check that can run on initial attachment, restart, ownership      |
//| takeover, and after any relevant trade transaction, and it adds   |
//| the discrepancy/orphan/ambiguity classes Recovery does not cover. |
//|                                                                    |
//| Ownership is precise: a ticket is "Flash's own" only when its     |
//| POSITION_SYMBOL/ORDER_SYMBOL and POSITION_MAGIC/ORDER_MAGIC match |
//| the configured symbol and magic exactly. A shared symbol with a   |
//| different or zero magic is counted separately, for visibility     |
//| only, and is never adopted, closed, trailed, or modified by       |
//| anything in this file.                                             |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"

//------------------------------------------------------------------
// Classification result. Mirrors the table in the Stage 3.1 brief.
//------------------------------------------------------------------
enum ENUM_FLASH_RECON_STATUS
{
   FLASH_RECON_NO_EXPOSURE = 0,               // nothing under this symbol/magic - fine if internal state agrees
   FLASH_RECON_MATCHED_ACTIVE_SETUP,          // expected protected position(s) exist and match internal setup
   FLASH_RECON_MATCHED_ARMED_SETUP,           // expected two-sided pending pair exists and matches internal setup
   FLASH_RECON_INCOMPLETE_PENDING_SETUP,      // only one initial pending order remains
   FLASH_RECON_UNPROTECTED_EXPOSURE,          // Flash position exists without SL
   FLASH_RECON_REVERSAL_RECONCILIATION_REQUIRED, // reversal fill exists but internal state still refers to old position
   FLASH_RECON_POSSIBLE_COMPLETED_OR_MISSING_SETUP, // internal state says active, no related broker exposure found
   FLASH_RECON_UNRESOLVED_EXIT,               // a close/cancel was requested but broker state has not confirmed it
   FLASH_RECON_EXPOSURE_DISCREPANCY,          // an unexpected additional Flash-owned position exists
   FLASH_RECON_ORPHANED_ORDER,                // a Flash-owned pending order remains after setup closure
   FLASH_RECON_OWNERSHIP_AMBIGUITY            // ownership of the relevant ticket(s) cannot be established reliably
};

// What Flash is permitted to do about a given classification. Never
// "repair" an unknown state by opening a new trade - RECON_ACTION_BLOCK
// or RECON_ACTION_ESCALATE are the only options when confidence is low.
enum ENUM_FLASH_RECON_ACTION
{
   RECON_ACTION_PROCEED = 0,      // matches expectation, no action needed
   RECON_ACTION_AUTO_REPAIR,      // Flash may attempt an automatic, narrowly-scoped repair (e.g. re-attach a known SL)
   RECON_ACTION_BLOCK_NEW_EXPOSURE, // do not arm/open/reverse further; existing risk-reducing actions may continue
   RECON_ACTION_ESCALATE          // requires operator intervention; block all further automated action
};

string FlashReconStatusToString(const ENUM_FLASH_RECON_STATUS s)
{
   switch(s)
   {
      case FLASH_RECON_NO_EXPOSURE:                       return "NO_EXPOSURE";
      case FLASH_RECON_MATCHED_ACTIVE_SETUP:               return "MATCHED_ACTIVE_SETUP";
      case FLASH_RECON_MATCHED_ARMED_SETUP:                return "MATCHED_ARMED_SETUP";
      case FLASH_RECON_INCOMPLETE_PENDING_SETUP:           return "INCOMPLETE_PENDING_SETUP";
      case FLASH_RECON_UNPROTECTED_EXPOSURE:               return "UNPROTECTED_EXPOSURE";
      case FLASH_RECON_REVERSAL_RECONCILIATION_REQUIRED:   return "REVERSAL_RECONCILIATION_REQUIRED";
      case FLASH_RECON_POSSIBLE_COMPLETED_OR_MISSING_SETUP:return "POSSIBLE_COMPLETED_OR_MISSING_SETUP";
      case FLASH_RECON_UNRESOLVED_EXIT:                    return "UNRESOLVED_EXIT";
      case FLASH_RECON_EXPOSURE_DISCREPANCY:                return "EXPOSURE_DISCREPANCY";
      case FLASH_RECON_ORPHANED_ORDER:                     return "ORPHANED_ORDER";
      case FLASH_RECON_OWNERSHIP_AMBIGUITY:                return "OWNERSHIP_AMBIGUITY";
      default:                                             return "UNKNOWN";
   }
}

// Fixed mapping from classification to the permitted action, defined
// once here so no call site can independently decide to auto-repair a
// state this table marks as block/escalate-only.
ENUM_FLASH_RECON_ACTION FlashReconRequiredAction(const ENUM_FLASH_RECON_STATUS s)
{
   switch(s)
   {
      case FLASH_RECON_NO_EXPOSURE:
      case FLASH_RECON_MATCHED_ACTIVE_SETUP:
      case FLASH_RECON_MATCHED_ARMED_SETUP:
         return RECON_ACTION_PROCEED;

      case FLASH_RECON_UNPROTECTED_EXPOSURE:
         return RECON_ACTION_AUTO_REPAIR; // narrowly scoped: attempt to re-attach a known-good SL only, per Stage 3.2.5

      case FLASH_RECON_INCOMPLETE_PENDING_SETUP:
      case FLASH_RECON_ORPHANED_ORDER:
         return RECON_ACTION_AUTO_REPAIR; // narrowly scoped: cancel the stray/orphaned order only, never open a new one

      case FLASH_RECON_REVERSAL_RECONCILIATION_REQUIRED:
      case FLASH_RECON_UNRESOLVED_EXIT:
      case FLASH_RECON_POSSIBLE_COMPLETED_OR_MISSING_SETUP:
         return RECON_ACTION_BLOCK_NEW_EXPOSURE; // existing reconciliation logic must resolve this first

      case FLASH_RECON_EXPOSURE_DISCREPANCY:
      case FLASH_RECON_OWNERSHIP_AMBIGUITY:
      default:
         return RECON_ACTION_ESCALATE; // unknown/unexplained state - operator review required, never guessed
   }
}

//------------------------------------------------------------------
// One Flash-owned ticket's inventory line (position or pending order).
//------------------------------------------------------------------
struct SFlashInventoryLine
{
   ulong    Ticket;
   int      TypeCode;      // ENUM_POSITION_TYPE or ENUM_ORDER_TYPE, caller interprets per IsPosition
   bool     IsPosition;    // true = open position, false = pending order
   double   Volume;
   double   PriceOpenOrPending;
   double   StopLoss;
   double   TakeProfit;
   string   Comment;
};

//------------------------------------------------------------------
// Full snapshot. Identity fields are recorded explicitly rather than
// inferred from array position or the currently selected chart, per
// Stage 3.1.3 - every ticket line below carries its own ticket number,
// never a positional index as identity.
//------------------------------------------------------------------
struct SFlashReconSnapshot
{
   // Identity
   long     AccountLogin;
   string   AccountServer;
   string   Symbol;
   long     Magic;
   bool     IsOwner;
   string   BuildId;
   datetime SnapshotTime;

   // Internal state, as supplied by the caller (never re-derived here)
   string   InternalSetupId;
   string   InternalStateName;
   string   InternalActiveDirection;

   // Flash-owned broker inventory (ownership-precise: symbol+magic exact match)
   SFlashInventoryLine Positions[];
   SFlashInventoryLine PendingOrders[];
   int      OpenPositionCount;
   int      PendingOrderCount;
   bool     AnyPositionUnprotected;
   string   BrokerActiveDirection; // "", "BUY", "SELL", or "MIXED"

   // Non-Flash exposure sharing the same symbol - counted for
   // visibility only, per Stage 3.1.2's example (position B, magic 0;
   // position C, a different magic). Never touched by anything here.
   int      OtherOwnerPositionCount;
   int      OtherOwnerPendingCount;

   // Outstanding intent (Stage 3.2 coupling), supplied by the caller
   bool     CloseIntentOutstanding;
   bool     CancelIntentOutstanding;

   // Result
   ENUM_FLASH_RECON_STATUS Status;
   string   AmbiguityReason; // populated only when Status implies ambiguity/discrepancy/escalation
};

class CFlashReconciliation
{
public:
   //------------------------------------------------------------------
   // Builds the snapshot from live broker state. Pure with respect to
   // classification (Classify() below is a separate pure function so
   // it can be exercised by the self-test suite with synthetic
   // snapshots, exactly like FlashRecovery::Classify already is).
   //------------------------------------------------------------------
   static SFlashReconSnapshot Inspect(const string symbol, const long magic, const bool isOwner,
                                       const string buildId, const string internalSetupId,
                                       const string internalStateName, const string internalActiveDirection,
                                       const bool closeIntentOutstanding, const bool cancelIntentOutstanding)
   {
      SFlashReconSnapshot snap;
      snap.AccountLogin = AccountInfoInteger(ACCOUNT_LOGIN);
      snap.AccountServer = AccountInfoString(ACCOUNT_SERVER);
      snap.Symbol = symbol;
      snap.Magic = magic;
      snap.IsOwner = isOwner;
      snap.BuildId = buildId;
      snap.SnapshotTime = TimeCurrent();
      snap.InternalSetupId = internalSetupId;
      snap.InternalStateName = internalStateName;
      snap.InternalActiveDirection = internalActiveDirection;
      snap.OpenPositionCount = 0;
      snap.PendingOrderCount = 0;
      snap.AnyPositionUnprotected = false;
      snap.BrokerActiveDirection = "";
      snap.OtherOwnerPositionCount = 0;
      snap.OtherOwnerPendingCount = 0;
      snap.CloseIntentOutstanding = closeIntentOutstanding;
      snap.CancelIntentOutstanding = cancelIntentOutstanding;
      snap.AmbiguityReason = "";
      ArrayFree(snap.Positions);
      ArrayFree(snap.PendingOrders);

      int totalPositions = PositionsTotal();
      for(int i = 0; i < totalPositions; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

         long posMagic = PositionGetInteger(POSITION_MAGIC);
         if(posMagic != magic)
         {
            // Ownership-precise: a different magic (including 0, i.e. a
            // manual order) is never Flash's own, regardless of symbol.
            snap.OtherOwnerPositionCount++;
            continue;
         }

         SFlashInventoryLine line;
         line.Ticket = ticket;
         line.IsPosition = true;
         line.TypeCode = (int)PositionGetInteger(POSITION_TYPE);
         line.Volume = PositionGetDouble(POSITION_VOLUME);
         line.PriceOpenOrPending = PositionGetDouble(POSITION_PRICE_OPEN);
         line.StopLoss = PositionGetDouble(POSITION_SL);
         line.TakeProfit = PositionGetDouble(POSITION_TP);
         line.Comment = PositionGetString(POSITION_COMMENT);

         int n = ArraySize(snap.Positions);
         ArrayResize(snap.Positions, n + 1);
         snap.Positions[n] = line;
         snap.OpenPositionCount++;

         if(line.StopLoss == 0.0)
            snap.AnyPositionUnprotected = true;

         string dir = (line.TypeCode == POSITION_TYPE_BUY) ? "BUY" : "SELL";
         if(snap.BrokerActiveDirection == "")
            snap.BrokerActiveDirection = dir;
         else if(snap.BrokerActiveDirection != dir)
            snap.BrokerActiveDirection = "MIXED";
      }

      int totalOrders = OrdersTotal();
      for(int i = 0; i < totalOrders; i++)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0 || !OrderSelect(ticket)) continue;
         if(OrderGetString(ORDER_SYMBOL) != symbol) continue;

         long ordMagic = OrderGetInteger(ORDER_MAGIC);
         if(ordMagic != magic)
         {
            snap.OtherOwnerPendingCount++;
            continue;
         }

         SFlashInventoryLine line;
         line.Ticket = ticket;
         line.IsPosition = false;
         line.TypeCode = (int)OrderGetInteger(ORDER_TYPE);
         line.Volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
         line.PriceOpenOrPending = OrderGetDouble(ORDER_PRICE_OPEN);
         line.StopLoss = OrderGetDouble(ORDER_SL);
         line.TakeProfit = OrderGetDouble(ORDER_TP);
         line.Comment = OrderGetString(ORDER_COMMENT);

         int n = ArraySize(snap.PendingOrders);
         ArrayResize(snap.PendingOrders, n + 1);
         snap.PendingOrders[n] = line;
         snap.PendingOrderCount++;
      }

      snap.Status = Classify(snap);
      if(snap.Status == FLASH_RECON_EXPOSURE_DISCREPANCY || snap.Status == FLASH_RECON_OWNERSHIP_AMBIGUITY)
         snap.AmbiguityReason = BuildAmbiguityReason(snap);

      return snap;
   }

   //------------------------------------------------------------------
   // Pure classification, exercised directly by the self-test suite.
   // Does not read the broker or any global state - operates only on
   // the fields already populated in the snapshot, so it is safe to
   // call repeatedly and safe to test with synthetic inputs.
   //------------------------------------------------------------------
   static ENUM_FLASH_RECON_STATUS Classify(const SFlashReconSnapshot &snap)
   {
      // Ownership must be established before anything else is trusted.
      if(!snap.IsOwner)
         return FLASH_RECON_OWNERSHIP_AMBIGUITY;

      bool hasInternalSetup = (StringLen(snap.InternalSetupId) > 0);

      // A close or cancel was requested but broker state has not yet
      // confirmed the corresponding change - this takes priority over
      // the shape-based classifications below, because "how many
      // positions/orders exist" is not yet the final word while a
      // request is still in flight.
      if(snap.CloseIntentOutstanding || snap.CancelIntentOutstanding)
         return FLASH_RECON_UNRESOLVED_EXIT;

      // Reversal reconciliation still pending: internal state names a
      // direction but the broker's actual direction disagrees, and a
      // setup is recorded - the same-tick reversal case (Stage 3.1.5).
      if(hasInternalSetup && StringLen(snap.InternalActiveDirection) > 0
         && snap.OpenPositionCount > 0 && snap.BrokerActiveDirection != "MIXED"
         && snap.BrokerActiveDirection != snap.InternalActiveDirection)
         return FLASH_RECON_REVERSAL_RECONCILIATION_REQUIRED;

      if(snap.OpenPositionCount == 0 && snap.PendingOrderCount == 0)
      {
         if(hasInternalSetup)
            return FLASH_RECON_POSSIBLE_COMPLETED_OR_MISSING_SETUP; // must check history, never assumed
         return FLASH_RECON_NO_EXPOSURE;
      }

      if(snap.OpenPositionCount > 0)
      {
         if(snap.AnyPositionUnprotected)
            return FLASH_RECON_UNPROTECTED_EXPOSURE;

         if(!hasInternalSetup)
            return FLASH_RECON_EXPOSURE_DISCREPANCY; // broker shows Flash exposure the EA has no record of

         if(snap.OpenPositionCount > 1 && snap.BrokerActiveDirection == "MIXED")
            return FLASH_RECON_EXPOSURE_DISCREPANCY; // positions in both directions under one setup is not an authorized shape

         // A Flash-owned pending order left over once a position is
         // already active is only expected during the brief entry
         // window (cancelling the opposite initial order) or while a
         // reversal is armed; if internal state agrees the setup is
         // simply active with no reversal armed and no pending count
         // recorded, one stray order counts as orphaned.
         if(snap.PendingOrderCount > 0 && snap.InternalStateName != "POSITION_ACTIVE"
            && snap.InternalStateName != "CANCELLING_OPPOSITE")
            return FLASH_RECON_ORPHANED_ORDER;

         return FLASH_RECON_MATCHED_ACTIVE_SETUP;
      }

      // No open positions, pending orders only.
      if(snap.PendingOrderCount == 1)
         return FLASH_RECON_INCOMPLETE_PENDING_SETUP;

      if(snap.PendingOrderCount == 2)
      {
         if(!hasInternalSetup)
            return FLASH_RECON_ORPHANED_ORDER;
         return FLASH_RECON_MATCHED_ARMED_SETUP;
      }

      // More than two Flash-owned pending orders under one magic is not
      // an authorized shape under the current strategy (single
      // consolidated pair) - flag rather than guess which are valid.
      return FLASH_RECON_EXPOSURE_DISCREPANCY;
   }

   static string BuildAmbiguityReason(const SFlashReconSnapshot &snap)
   {
      if(!snap.IsOwner)
         return "This instance does not currently hold the ownership lock; reconciliation cannot be trusted from a non-owner.";
      if(snap.OpenPositionCount > 1 && snap.BrokerActiveDirection == "MIXED")
         return "Flash-owned positions exist in both directions simultaneously, which is not an authorized shape under the current strategy.";
      if(snap.PendingOrderCount > 2)
         return StringFormat("%d Flash-owned pending orders found under one magic; the strategy only ever arms one consolidated pair.", snap.PendingOrderCount);
      if(snap.OpenPositionCount > 0 && StringLen(snap.InternalSetupId) == 0)
         return "Broker shows Flash-owned open exposure but no internal setup record exists for it.";
      return "Unclassified discrepancy between broker inventory and internal state.";
   }

   //------------------------------------------------------------------
   // Structured log line for the [FLASH][RECONCILE] category (Stage 3.4).
   //------------------------------------------------------------------
   static void LogSnapshot(const SFlashReconSnapshot &snap)
   {
      CFlashLogger::Log("RECONCILE",
         StringFormat("build=%s symbol=%s magic=%d owner=%s setupId=%s internalState=%s internalDir=%s | broker: positions=%d pendingOrders=%d unprotected=%s brokerDir=%s otherOwnerPositions=%d otherOwnerPending=%d | intent: closeOutstanding=%s cancelOutstanding=%s | status=%s action=%s%s",
            snap.BuildId, snap.Symbol, (int)snap.Magic, snap.IsOwner ? "true" : "false",
            snap.InternalSetupId, snap.InternalStateName, snap.InternalActiveDirection,
            snap.OpenPositionCount, snap.PendingOrderCount, snap.AnyPositionUnprotected ? "true" : "false",
            snap.BrokerActiveDirection, snap.OtherOwnerPositionCount, snap.OtherOwnerPendingCount,
            snap.CloseIntentOutstanding ? "true" : "false", snap.CancelIntentOutstanding ? "true" : "false",
            FlashReconStatusToString(snap.Status), EnumToString(FlashReconRequiredAction(snap.Status)),
            (StringLen(snap.AmbiguityReason) > 0) ? (" reason=" + snap.AmbiguityReason) : ""));
   }
};

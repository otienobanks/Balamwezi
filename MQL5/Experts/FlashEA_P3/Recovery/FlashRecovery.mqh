//+------------------------------------------------------------------+
//| FlashRecovery.mqh                                                |
//| Owner: Phase 1, Stage 1.4/1.5 - Restart, Reattachment, Recovery   |
//|                                                                    |
//| Inspects the account for existing orders and positions carrying   |
//| this EA's magic number on this symbol, using ACTUAL broker        |
//| orders/positions (never in-memory state alone, since that is      |
//| lost on restart, and never order comments alone, since a broker   |
//| may truncate or alter them). Classifies what was found into one   |
//| of the recovery scenarios in Section 10.1 of the Phase 1 build    |
//| prompt so OnInit can decide, correctly, whether it is safe to     |
//| consider a new setup.                                              |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"

enum ENUM_FLASH_RECOVERY_SCENARIO
{
   FLASH_RECOVERY_NONE = 0,                  // no Flash orders or positions - safe to arm a new setup
   FLASH_RECOVERY_VALID_PENDING_PAIR,        // both a Buy Stop and a Sell Stop group present, no fill yet
   FLASH_RECOVERY_INCOMPLETE_PENDING,        // only one side of the pending pair present
   FLASH_RECOVERY_ACTIVE_PROTECTED,          // one direction's position(s) open, all protected by an SL
   FLASH_RECOVERY_ACTIVE_UNPROTECTED,        // a Flash position exists with no SL - emergency
   FLASH_RECOVERY_UNEXPECTED_OPPOSITE        // positions/orders in both directions simultaneously - not an authorized state
};

struct SFlashRecoverySnapshot
{
   int    PendingBuyStops;
   int    PendingSellStops;
   int    OpenPositions;
   ulong  BuyStopTickets[];
   ulong  SellStopTickets[];
   ulong  PositionTickets[];
   ulong  FirstPositionTicket;   // 0 if none
   string ActiveDirection;       // "BUY", "SELL", "", or "MIXED" if both (unexpected)
   bool   AnyPositionUnprotected;
   ENUM_FLASH_RECOVERY_SCENARIO Scenario;
};

class CFlashRecovery
{
public:
   static string ScenarioToString(const ENUM_FLASH_RECOVERY_SCENARIO s)
   {
      switch(s)
      {
         case FLASH_RECOVERY_NONE:               return "NONE";
         case FLASH_RECOVERY_VALID_PENDING_PAIR:  return "VALID_PENDING_PAIR";
         case FLASH_RECOVERY_INCOMPLETE_PENDING:  return "INCOMPLETE_PENDING";
         case FLASH_RECOVERY_ACTIVE_PROTECTED:    return "ACTIVE_PROTECTED";
         case FLASH_RECOVERY_ACTIVE_UNPROTECTED:  return "ACTIVE_UNPROTECTED";
         case FLASH_RECOVERY_UNEXPECTED_OPPOSITE: return "UNEXPECTED_OPPOSITE";
         default:                                 return "UNKNOWN";
      }
   }

   // Full inspection: gathers actual tickets (not just counts), so a
   // caller can act on the exposure it finds (cancel a stray order,
   // re-attach a missing SL) rather than only knowing it exists.
   static SFlashRecoverySnapshot Inspect(const string symbol, const long magicNumber)
   {
      SFlashRecoverySnapshot snap;
      snap.PendingBuyStops = 0;
      snap.PendingSellStops = 0;
      snap.OpenPositions = 0;
      snap.FirstPositionTicket = 0;
      snap.ActiveDirection = "";
      snap.AnyPositionUnprotected = false;
      ArrayFree(snap.BuyStopTickets);
      ArrayFree(snap.SellStopTickets);
      ArrayFree(snap.PositionTickets);

      // Pending orders
      int totalOrders = OrdersTotal();
      for(int i = 0; i < totalOrders; i++)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0) continue;
         if(!OrderSelect(ticket)) continue;

         if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
         if(OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;

         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type == ORDER_TYPE_BUY_STOP)
         {
            snap.PendingBuyStops++;
            int n = ArraySize(snap.BuyStopTickets);
            ArrayResize(snap.BuyStopTickets, n + 1);
            snap.BuyStopTickets[n] = ticket;
         }
         if(type == ORDER_TYPE_SELL_STOP)
         {
            snap.PendingSellStops++;
            int n = ArraySize(snap.SellStopTickets);
            ArrayResize(snap.SellStopTickets, n + 1);
            snap.SellStopTickets[n] = ticket;
         }
      }

      // Open positions
      int totalPositions = PositionsTotal();
      for(int i = 0; i < totalPositions; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;

         if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;

         snap.OpenPositions++;
         int n = ArraySize(snap.PositionTickets);
         ArrayResize(snap.PositionTickets, n + 1);
         snap.PositionTickets[n] = ticket;

         if(snap.FirstPositionTicket == 0)
            snap.FirstPositionTicket = ticket;

         if(PositionGetDouble(POSITION_SL) == 0.0)
            snap.AnyPositionUnprotected = true;

         string dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
         if(snap.ActiveDirection == "")
            snap.ActiveDirection = dir;
         else if(snap.ActiveDirection != dir)
            snap.ActiveDirection = "MIXED";
      }

      snap.Scenario = Classify(snap);

      CFlashLogger::Log("RECOVERY",
         StringFormat("Snapshot | pendingBuyStops=%d pendingSellStops=%d openPositions=%d direction=%s unprotected=%s scenario=%s",
                       snap.PendingBuyStops, snap.PendingSellStops, snap.OpenPositions, snap.ActiveDirection,
                       snap.AnyPositionUnprotected ? "true" : "false", ScenarioToString(snap.Scenario)));

      return snap;
   }

   // Pure classification, exercised directly by the self-test suite with
   // synthetic snapshots (no live broker state required).
   static ENUM_FLASH_RECOVERY_SCENARIO Classify(const SFlashRecoverySnapshot &snap)
   {
      bool hasBuyPending  = snap.PendingBuyStops > 0;
      bool hasSellPending = snap.PendingSellStops > 0;
      bool hasPosition    = snap.OpenPositions > 0;

      if(!hasBuyPending && !hasSellPending && !hasPosition)
         return FLASH_RECOVERY_NONE;

      if(hasPosition && snap.ActiveDirection == "MIXED")
         return FLASH_RECOVERY_UNEXPECTED_OPPOSITE;

      if(hasPosition)
      {
         if(snap.AnyPositionUnprotected)
            return FLASH_RECOVERY_ACTIVE_UNPROTECTED;
         return FLASH_RECOVERY_ACTIVE_PROTECTED;
      }

      // No position yet, only pending orders
      if(hasBuyPending && hasSellPending)
         return FLASH_RECOVERY_VALID_PENDING_PAIR;

      return FLASH_RECOVERY_INCOMPLETE_PENDING;
   }
};

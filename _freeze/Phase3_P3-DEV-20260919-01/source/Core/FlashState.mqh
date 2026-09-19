//+------------------------------------------------------------------+
//| FlashState.mqh                                                   |
//| Phase 1 core + Phase 2 trailing/reversal/setup-exit extensions    |
//|                                                                    |
//| Owns the explicit state machine and the SFlashSetup record that   |
//| identifies one logical two-sided setup, now extended to track a   |
//| setup across repeated reversals. A broker request being SENT is   |
//| never sufficient grounds for a transition; every transition into  |
//| an execution-confirming state must be driven by verified broker  |
//| state - this file only enforces which transitions are legal and   |
//| logs every one that happens.                                       |
//+------------------------------------------------------------------+
#property strict
#include "FlashLogger.mqh"

enum ENUM_FLASH_STATE
{
   FLASH_STATE_INITIALIZING = 0,
   FLASH_STATE_WAITING_FOR_ENTRY,
   FLASH_STATE_PLACING_ORDERS,
   FLASH_STATE_ORDERS_ARMED,
   FLASH_STATE_ENTRY_DETECTED,
   FLASH_STATE_CANCELLING_OPPOSITE,
   FLASH_STATE_POSITION_ACTIVE,
   FLASH_STATE_REVERSAL_RECONCILING,   // Phase 2: a reversal execution was detected and is being reconciled
   FLASH_STATE_SETUP_EXIT,             // Phase 2: setup profit target reached, controlled exit in progress
   FLASH_STATE_RECOVERY_REQUIRED,
   FLASH_STATE_TRADING_BLOCKED
};

// One logical Flash setup: the pair (or group) of initial pending orders and
// whatever they resolve into, extended in Phase 2 to persist across
// repeated reversals - a reversal never starts a new logical setup.
struct SFlashSetup
{
   string   SetupId;             // e.g. "20260917-0001"
   long     MagicNumber;
   string   Symbol;
   ENUM_TIMEFRAMES Timeframe;
   ENUM_FLASH_ENTRY_METHOD EntryMethod;

   double   OriginalBuyStopPrice;
   double   OriginalSellStopPrice;
   double   InitialBuySL;         // = OriginalSellStopPrice
   double   InitialSellSL;        // = OriginalBuyStopPrice

   ulong    BuyStopTickets[];
   ulong    SellStopTickets[];
   ulong    PositionTickets[];    // filled positions belonging to the CURRENT active direction

   string   ActiveDirection;      // "BUY", "SELL", or "" if none yet
   double   RequestedVolume;      // total requested volume for the triggered direction
   double   FilledVolume;         // total actually filled volume so far
   double   FirstFillPrice;       // actual price of the first fill in the current active direction

   datetime CreatedAt;

   // Phase 2 - sizing
   double   VolumePerPosition;    // volume actually used per position for this setup (fixed or risk-derived)

   // Phase 2 - trailing
   bool     TrailingActive;
   double   LastConfirmedSL;              // last broker-verified SL for the current open direction
   double   LastConfirmedTrailingReference; // reference price used for reversal placement once trailing

   // Phase 2 - reversal
   ulong    ReversalPendingTicket;    // 0 if no reversal order currently armed
   string   ReversalPendingDirection; // "BUY" or "SELL" - direction of the armed reversal order
   double   ReversalPendingPrice;
   int      ReversalCount;            // number of reversals executed so far in this logical setup

   // Phase 2 - combined setup P/L, never reset except on final setup close
   double   SetupRealizedPL;      // realized profit+commission+swap of all closed legs of this setup so far
   datetime SetupOpenedAt;

   void Reset()
   {
      SetupId = "";
      MagicNumber = 0;
      Symbol = "";
      Timeframe = PERIOD_CURRENT;
      EntryMethod = FLASH_ENTRY_FIXED_PRICE_DISTANCE;
      OriginalBuyStopPrice = 0.0;
      OriginalSellStopPrice = 0.0;
      InitialBuySL = 0.0;
      InitialSellSL = 0.0;
      ArrayFree(BuyStopTickets);
      ArrayFree(SellStopTickets);
      ArrayFree(PositionTickets);
      ActiveDirection = "";
      RequestedVolume = 0.0;
      FilledVolume = 0.0;
      FirstFillPrice = 0.0;
      CreatedAt = 0;
      VolumePerPosition = 0.0;
      TrailingActive = false;
      LastConfirmedSL = 0.0;
      LastConfirmedTrailingReference = 0.0;
      ReversalPendingTicket = 0;
      ReversalPendingDirection = "";
      ReversalPendingPrice = 0.0;
      ReversalCount = 0;
      SetupRealizedPL = 0.0;
      SetupOpenedAt = 0;
   }

   // Reversal reset: called when a reversal completes - clears only the
   // per-leg trailing/reversal-arming fields, NEVER SetupRealizedPL,
   // ReversalCount, SetupId, or SetupOpenedAt, which must survive intact.
   void ResetForNewLeg()
   {
      ArrayFree(PositionTickets);
      FirstFillPrice = 0.0;
      FilledVolume = 0.0;
      TrailingActive = false;
      LastConfirmedSL = 0.0;
      LastConfirmedTrailingReference = 0.0;
      ReversalPendingTicket = 0;
      ReversalPendingDirection = "";
      ReversalPendingPrice = 0.0;
   }

   bool HasUnresolvedExposure() const
   {
      return (ArraySize(BuyStopTickets) > 0 || ArraySize(SellStopTickets) > 0 ||
              ArraySize(PositionTickets) > 0 || ReversalPendingTicket != 0);
   }
};

class CFlashState
{
private:
   ENUM_FLASH_STATE m_state;

   static string StateToString(const ENUM_FLASH_STATE s)
   {
      switch(s)
      {
         case FLASH_STATE_INITIALIZING:         return "INITIALIZING";
         case FLASH_STATE_WAITING_FOR_ENTRY:    return "WAITING_FOR_ENTRY";
         case FLASH_STATE_PLACING_ORDERS:       return "PLACING_ORDERS";
         case FLASH_STATE_ORDERS_ARMED:         return "ORDERS_ARMED";
         case FLASH_STATE_ENTRY_DETECTED:       return "ENTRY_DETECTED";
         case FLASH_STATE_CANCELLING_OPPOSITE:  return "CANCELLING_OPPOSITE";
         case FLASH_STATE_POSITION_ACTIVE:      return "POSITION_ACTIVE";
         case FLASH_STATE_REVERSAL_RECONCILING: return "REVERSAL_RECONCILING";
         case FLASH_STATE_SETUP_EXIT:           return "SETUP_EXIT";
         case FLASH_STATE_RECOVERY_REQUIRED:    return "RECOVERY_REQUIRED";
         case FLASH_STATE_TRADING_BLOCKED:      return "TRADING_BLOCKED";
         default:                               return "UNKNOWN";
      }
   }

   // Legal transition table. Anything not listed here is rejected, logged,
   // and does not change m_state - callers must handle that return value
   // rather than assuming the transition happened.
   bool IsLegalTransition(const ENUM_FLASH_STATE from, const ENUM_FLASH_STATE to)
   {
      // RECOVERY_REQUIRED and TRADING_BLOCKED are reachable from any state -
      // both are safety states a fault can be detected from at any point.
      if(to == FLASH_STATE_RECOVERY_REQUIRED || to == FLASH_STATE_TRADING_BLOCKED)
         return true;

      switch(from)
      {
         case FLASH_STATE_INITIALIZING:
            return (to == FLASH_STATE_WAITING_FOR_ENTRY);

         case FLASH_STATE_WAITING_FOR_ENTRY:
            return (to == FLASH_STATE_PLACING_ORDERS);

         case FLASH_STATE_PLACING_ORDERS:
            return (to == FLASH_STATE_ORDERS_ARMED || to == FLASH_STATE_WAITING_FOR_ENTRY);

         case FLASH_STATE_ORDERS_ARMED:
            return (to == FLASH_STATE_ENTRY_DETECTED || to == FLASH_STATE_PLACING_ORDERS);

         case FLASH_STATE_ENTRY_DETECTED:
            return (to == FLASH_STATE_CANCELLING_OPPOSITE);

         case FLASH_STATE_CANCELLING_OPPOSITE:
            return (to == FLASH_STATE_POSITION_ACTIVE);

         case FLASH_STATE_POSITION_ACTIVE:
            return (to == FLASH_STATE_WAITING_FOR_ENTRY ||       // after full reconciliation of closure (no reversal)
                    to == FLASH_STATE_REVERSAL_RECONCILING ||    // reversal execution detected
                    to == FLASH_STATE_SETUP_EXIT);                // setup profit target reached

         case FLASH_STATE_REVERSAL_RECONCILING:
            return (to == FLASH_STATE_POSITION_ACTIVE ||   // reversal reconciled, continuing same setup
                    to == FLASH_STATE_WAITING_FOR_ENTRY);   // reversal reconciled into a fully closed setup

         case FLASH_STATE_SETUP_EXIT:
            return (to == FLASH_STATE_WAITING_FOR_ENTRY);   // exit fully verified, setup closed

         case FLASH_STATE_RECOVERY_REQUIRED:
            return (to == FLASH_STATE_WAITING_FOR_ENTRY ||
                    to == FLASH_STATE_POSITION_ACTIVE ||
                    to == FLASH_STATE_REVERSAL_RECONCILING ||
                    to == FLASH_STATE_SETUP_EXIT);

         case FLASH_STATE_TRADING_BLOCKED:
            return false; // requires restart / explicit re-init to leave

         default:
            return false;
      }
   }

public:
   CFlashState() { m_state = FLASH_STATE_INITIALIZING; }

   ENUM_FLASH_STATE Current() const { return m_state; }
   string CurrentString() const { return StateToString(m_state); }

   // Returns true and applies the transition if legal; otherwise logs the
   // rejection and leaves state unchanged.
   bool TransitionTo(const ENUM_FLASH_STATE to, const string reason)
   {
      if(!IsLegalTransition(m_state, to))
      {
         CFlashLogger::Error("STATE",
            StringFormat("Rejected illegal transition %s -> %s (reason=%s)",
                         StateToString(m_state), StateToString(to), reason));
         return false;
      }

      CFlashLogger::StateTransition(StateToString(m_state), StateToString(to), reason);
      m_state = to;
      return true;
   }
};

//+------------------------------------------------------------------+
//| FlashProfitTarget.mqh                                            |
//| Phase 2 Stage 2.3 - Combined Setup Net Profit Target              |
//|                                                                    |
//| The target aggregates the WHOLE logical setup: realized P/L of    |
//| every closed leg (including prior reversals), plus the current    |
//| floating P/L of open positions. It is a trigger to begin a         |
//| controlled exit, never a guarantee of the final realized amount - |
//| spread, commission, and execution slippage during the exit can    |
//| change the final result. Realized losses from an earlier reversal |
//| leg are never dropped or reset; they always count toward the      |
//| combined figure.                                                   |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"

class CFlashProfitTarget
{
public:
   static double CombinedPL(const double setupRealizedPL, const double currentFloatingPL)
   {
      return setupRealizedPL + currentFloatingPL;
   }

   static bool TargetReached(const bool enabled, const double combinedPL, const double target)
   {
      if(!enabled) return false;
      return combinedPL >= target;
   }

   // Live wrapper - sums floating P/L (profit + swap) across every open
   // position ticket belonging to this setup's current leg. Realized P/L
   // from closed legs must be supplied by the caller from SFlashSetup's
   // persisted SetupRealizedPL, never recomputed here from scratch.
   static double ComputeFloatingPL(const ulong &positionTickets[])
   {
      double total = 0.0;
      for(int i = 0; i < ArraySize(positionTickets); i++)
      {
         if(!PositionSelectByTicket(positionTickets[i])) continue;
         total += PositionGetDouble(POSITION_PROFIT);
         total += PositionGetDouble(POSITION_SWAP);
      }
      return total;
   }
};

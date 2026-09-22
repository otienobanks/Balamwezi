//+------------------------------------------------------------------+
//| FlashDailyLimits.mqh                                             |
//| Phase 2 Stage 2.4 - Daily realized P/L ledger and limits          |
//|                                                                    |
//| Daily realized P/L is reconstructed from broker deal history on   |
//| every check, keyed to this EA's magic number and symbol, never    |
//| relying solely on an in-memory running total that would be lost   |
//| on restart. The Kenya calendar day (00:00:00 EAT) is the ledger's |
//| boundary, computed via CFlashSessions using the same configured   |
//| broker-to-UTC offset used by the session filter.                  |
//+------------------------------------------------------------------+
#property strict
#include "FlashLogger.mqh"
#include "FlashSessions.mqh"

class CFlashDailyLimits
{
public:
   //------------------------------------------------------------------
   // Pure decision functions
   //------------------------------------------------------------------

   static bool ProfitLimitReached(const bool enabled, const double dailyRealizedPL, const double limit)
   {
      if(!enabled) return false;
      return dailyRealizedPL >= limit;
   }

   static bool LossLimitReached(const bool enabled, const double dailyRealizedPL, const double limit)
   {
      if(!enabled) return false;
      return dailyRealizedPL <= -MathAbs(limit);
   }

   static bool NewExposurePermitted(const bool profitEnabled, const double dailyPL, const double profitLimit,
                                     const bool lossEnabled, const double lossLimit)
   {
      if(ProfitLimitReached(profitEnabled, dailyPL, profitLimit)) return false;
      if(LossLimitReached(lossEnabled, dailyPL, lossLimit)) return false;
      return true;
   }

   //------------------------------------------------------------------
   // Live wrapper - reconstructs today's realized P/L attributable to
   // this magic number/symbol from actual closed deals in history.
   //------------------------------------------------------------------
   static double ComputeTodayRealizedPL(const string symbol, const long magic, const double brokerOffsetHours)
   {
      int offsetSeconds = (int)MathRound(brokerOffsetHours * 3600.0);
      datetime dayStartBroker = CFlashSessions::KenyaDayStartInBrokerTime(TimeCurrent(), offsetSeconds);
      datetime now = TimeCurrent();

      if(!HistorySelect(dayStartBroker, now))
      {
         CFlashLogger::Error("DAILY_LIMITS", "HistorySelect failed - cannot reconstruct today's realized P/L");
         return 0.0;
      }

      double total = 0.0;
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != symbol) continue;
         if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != magic) continue;

         long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT) continue; // only realized closes count

         total += HistoryDealGetDouble(ticket, DEAL_PROFIT);
         total += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         total += HistoryDealGetDouble(ticket, DEAL_SWAP);
      }
      return total;
   }
};

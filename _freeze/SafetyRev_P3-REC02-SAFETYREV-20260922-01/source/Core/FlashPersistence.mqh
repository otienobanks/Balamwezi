//+------------------------------------------------------------------+
//| FlashPersistence.mqh                                             |
//| Phase 2 Stage 2.5 - Trailing/reversal restart persistence         |
//|                                                                    |
//| MT5 GlobalVariables are terminal-wide doubles, already the        |
//| mechanism the Phase 1 ownership lock uses because it survives an  |
//| EA restart/reattachment. Phase 2 reuses the same mechanism to     |
//| persist trailing activation status, the last confirmed trailing   |
//| reference, the armed reversal ticket, the reversal count, and the |
//| setup's accumulated realized P/L, keyed by symbol and magic       |
//| number so restart recovery can reconcile against actual broker    |
//| state rather than reinitializing an active setup as a fresh one.  |
//| GlobalVariables cannot hold strings, so SetupId itself is not     |
//| persisted here - recovery re-derives setup identity from actual   |
//| broker exposure, per FlashRecovery.mqh.                            |
//+------------------------------------------------------------------+
#property strict
#include "FlashLogger.mqh"

class CFlashPersistence
{
private:
   static string Key(const string field, const string symbol, const long magic)
   {
      return "FLASH_P2_" + field + "_" + symbol + "_" + IntegerToString((int)magic);
   }

public:
   static void SaveTrailingActive(const string symbol, const long magic, const bool active)
   {
      GlobalVariableSet(Key("TRAILING_ACTIVE", symbol, magic), active ? 1.0 : 0.0);
   }
   static bool LoadTrailingActive(const string symbol, const long magic)
   {
      return GlobalVariableCheck(Key("TRAILING_ACTIVE", symbol, magic)) &&
             GlobalVariableGet(Key("TRAILING_ACTIVE", symbol, magic)) > 0.5;
   }

   static void SaveLastConfirmedSL(const string symbol, const long magic, const double sl)
   {
      GlobalVariableSet(Key("LAST_SL", symbol, magic), sl);
   }
   static double LoadLastConfirmedSL(const string symbol, const long magic)
   {
      if(!GlobalVariableCheck(Key("LAST_SL", symbol, magic))) return 0.0;
      return GlobalVariableGet(Key("LAST_SL", symbol, magic));
   }

   static void SaveTrailingReference(const string symbol, const long magic, const double refPrice)
   {
      GlobalVariableSet(Key("TRAILING_REF", symbol, magic), refPrice);
   }
   static double LoadTrailingReference(const string symbol, const long magic)
   {
      if(!GlobalVariableCheck(Key("TRAILING_REF", symbol, magic))) return 0.0;
      return GlobalVariableGet(Key("TRAILING_REF", symbol, magic));
   }

   static void SaveReversalTicket(const string symbol, const long magic, const ulong ticket)
   {
      GlobalVariableSet(Key("REV_TICKET", symbol, magic), (double)ticket);
   }
   static ulong LoadReversalTicket(const string symbol, const long magic)
   {
      if(!GlobalVariableCheck(Key("REV_TICKET", symbol, magic))) return 0;
      return (ulong)GlobalVariableGet(Key("REV_TICKET", symbol, magic));
   }

   static void SaveReversalCount(const string symbol, const long magic, const int count)
   {
      GlobalVariableSet(Key("REV_COUNT", symbol, magic), (double)count);
   }
   static int LoadReversalCount(const string symbol, const long magic)
   {
      if(!GlobalVariableCheck(Key("REV_COUNT", symbol, magic))) return 0;
      return (int)GlobalVariableGet(Key("REV_COUNT", symbol, magic));
   }

   static void SaveSetupRealizedPL(const string symbol, const long magic, const double pl)
   {
      GlobalVariableSet(Key("SETUP_PL", symbol, magic), pl);
   }
   static double LoadSetupRealizedPL(const string symbol, const long magic)
   {
      if(!GlobalVariableCheck(Key("SETUP_PL", symbol, magic))) return 0.0;
      return GlobalVariableGet(Key("SETUP_PL", symbol, magic));
   }

   static void SaveSetupOpenedAt(const string symbol, const long magic, const datetime t)
   {
      GlobalVariableSet(Key("SETUP_OPENED", symbol, magic), (double)t);
   }
   static datetime LoadSetupOpenedAt(const string symbol, const long magic)
   {
      if(!GlobalVariableCheck(Key("SETUP_OPENED", symbol, magic))) return 0;
      return (datetime)GlobalVariableGet(Key("SETUP_OPENED", symbol, magic));
   }

   // Direction is persisted as a double since GlobalVariables cannot hold
   // strings: 1.0 = BUY, -1.0 = SELL, 0.0 = none.
   static void SaveActiveDirection(const string symbol, const long magic, const string direction)
   {
      double v = 0.0;
      if(direction == "BUY") v = 1.0;
      else if(direction == "SELL") v = -1.0;
      GlobalVariableSet(Key("ACTIVE_DIR", symbol, magic), v);
   }
   static string LoadActiveDirection(const string symbol, const long magic)
   {
      if(!GlobalVariableCheck(Key("ACTIVE_DIR", symbol, magic))) return "";
      double v = GlobalVariableGet(Key("ACTIVE_DIR", symbol, magic));
      if(v > 0.5) return "BUY";
      if(v < -0.5) return "SELL";
      return "";
   }

   // Clears all Phase 2 persisted metadata for this symbol/magic - called
   // once a logical setup is fully closed and reconciled (WAITING_FOR_ENTRY
   // reached with zero unresolved exposure), never before that.
   static void ClearAll(const string symbol, const long magic)
   {
      GlobalVariableDel(Key("TRAILING_ACTIVE", symbol, magic));
      GlobalVariableDel(Key("LAST_SL", symbol, magic));
      GlobalVariableDel(Key("TRAILING_REF", symbol, magic));
      GlobalVariableDel(Key("REV_TICKET", symbol, magic));
      GlobalVariableDel(Key("REV_COUNT", symbol, magic));
      GlobalVariableDel(Key("SETUP_PL", symbol, magic));
      GlobalVariableDel(Key("SETUP_OPENED", symbol, magic));
      GlobalVariableDel(Key("ACTIVE_DIR", symbol, magic));
      CFlashLogger::Log("PERSISTENCE", "Phase 2 persisted setup metadata cleared - setup fully closed");
   }
};

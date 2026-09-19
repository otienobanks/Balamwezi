//+------------------------------------------------------------------+
//| FlashEntryEngine.mqh                                             |
//| Owner: Phase 1, Stage 1.3 - Universal Entry Calculation           |
//|                                                                    |
//| Calculates the two-sided pending entry pair and each side's       |
//| initial protective stop loss. Both entry methods (Fixed Price     |
//| Distance and Previous Candle) are implemented as pure functions   |
//| that take plain prices and return a plain result, so the exact    |
//| arithmetic can be exercised by the self-test suite without a      |
//| live broker connection.                                           |
//|                                                                    |
//| The initial SL is never a separately configured distance - it is  |
//| always the OTHER side's original pending price (Section 8.4 of    |
//| the Phase 1 build prompt), fixed at calculation time and never     |
//| recalculated from a later quote once a position is open.          |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"
#include "..\Core\FlashConfig.mqh"
#include "..\Market\FlashTimeframe.mqh"

struct SFlashEntryPair
{
   bool   valid;
   string rejectReason;
   double buyStopPrice;
   double sellStopPrice;
   double buyInitialSL;     // = sellStopPrice
   double sellInitialSL;    // = buyStopPrice
};

class CFlashEntryEngine
{
public:
   //------------------------------------------------------------------
   // Pure calculation - Entry Method A: Fixed Price Distance
   //------------------------------------------------------------------
   static SFlashEntryPair CalculateFixedDistance(const double bid, const double ask, const double entryDistance)
   {
      SFlashEntryPair pair;
      pair.buyStopPrice  = ask + entryDistance;
      pair.sellStopPrice = bid - entryDistance;
      pair.buyInitialSL  = pair.sellStopPrice;
      pair.sellInitialSL = pair.buyStopPrice;
      pair.valid = true;
      pair.rejectReason = "";
      return pair;
   }

   //------------------------------------------------------------------
   // Pure calculation - Entry Method B: Previous Completed Candle
   //------------------------------------------------------------------
   static SFlashEntryPair CalculatePreviousCandle(const double prevHigh, const double prevLow, const double buffer)
   {
      SFlashEntryPair pair;
      pair.buyStopPrice  = prevHigh + buffer;
      pair.sellStopPrice = prevLow  - buffer;
      pair.buyInitialSL  = pair.sellStopPrice;
      pair.sellInitialSL = pair.buyStopPrice;
      pair.valid = true;
      pair.rejectReason = "";
      return pair;
   }

   // Rejects a pair whose levels have already been crossed by the current
   // market, per Section 8.3 - never converts to a market order and never
   // silently moves the level to make it valid again.
   static bool RejectIfAlreadyCrossed(SFlashEntryPair &pair, const double bid, const double ask)
   {
      if(pair.buyStopPrice <= ask)
      {
         pair.valid = false;
         pair.rejectReason = "Calculated Buy Stop is at or below current Ask - entry cycle rejected";
         return false;
      }
      if(pair.sellStopPrice >= bid)
      {
         pair.valid = false;
         pair.rejectReason = "Calculated Sell Stop is at or above current Bid - entry cycle rejected";
         return false;
      }
      return true;
   }

   //------------------------------------------------------------------
   // Live wrapper - dispatches on the configured entry method, pulls a
   // coherent market/candle snapshot, and applies the already-crossed
   // check before returning.
   //------------------------------------------------------------------
   static SFlashEntryPair Calculate(const SFlashConfig &cfg, const string symbol, const CFlashTimeframe &tf)
   {
      SFlashEntryPair pair;
      pair.valid = false;
      pair.rejectReason = "";
      pair.buyStopPrice = 0; pair.sellStopPrice = 0; pair.buyInitialSL = 0; pair.sellInitialSL = 0;

      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

      if(bid <= 0.0 || ask <= 0.0)
      {
         pair.rejectReason = "No valid market quote available";
         CFlashLogger::Error("ENTRY", pair.rejectReason);
         return pair;
      }

      if(cfg.EntryMethod == FLASH_ENTRY_FIXED_PRICE_DISTANCE)
      {
         pair = CalculateFixedDistance(bid, ask, cfg.EntryDistancePrice);
      }
      else
      {
         double prevHigh, prevLow;
         if(!tf.GetPreviousCompletedCandle(prevHigh, prevLow))
         {
            pair.rejectReason = "Previous completed candle data not available";
            CFlashLogger::Error("ENTRY", pair.rejectReason);
            return pair;
         }
         pair = CalculatePreviousCandle(prevHigh, prevLow, cfg.PreviousCandleEntryBuffer);
      }

      if(!RejectIfAlreadyCrossed(pair, bid, ask))
      {
         CFlashLogger::Error("ENTRY", pair.rejectReason);
         return pair;
      }

      CFlashLogger::Log("ENTRY",
         StringFormat("Method=%s | BuyStop=%s BuySL=%s | SellStop=%s SellSL=%s",
                      CFlashConfig::EntryMethodToString(cfg.EntryMethod),
                      DoubleToString(pair.buyStopPrice, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                      DoubleToString(pair.buyInitialSL, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                      DoubleToString(pair.sellStopPrice, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                      DoubleToString(pair.sellInitialSL, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS))));

      return pair;
   }
};

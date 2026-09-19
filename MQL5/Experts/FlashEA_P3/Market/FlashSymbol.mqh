//+------------------------------------------------------------------+
//| FlashSymbol.mqh                                                  |
//| Phase 1, Stage 1.1 - Basic symbol identification                 |
//|                                                                    |
//| Stage 1.1 scope only: confirm the chart's symbol is tradeable and |
//| expose current quote/point data for logging. Full broker-rule     |
//| validation (StopsLevel, FreezeLevel, volume step, margin, price   |
//| normalization) is Stage 1.2's job and belongs in                  |
//| FlashBrokerRules.mqh, not here - this file does not decide        |
//| whether an order is legal, only what the symbol currently is.     |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"

class CFlashSymbol
{
private:
   string m_symbol;

public:
   void Init(const string symbol) { m_symbol = symbol; }

   string Name() const { return m_symbol; }

   // Basic tradeability check for Stage 1.1's OnInit gate. This is NOT the
   // full Stage 1.2 broker validation pass - it only rejects symbols that
   // are obviously unusable (unknown to the terminal, or trading disabled).
   bool IsBasicallyTradeable() const
   {
      if(!SymbolSelect(m_symbol, true))
      {
         CFlashLogger::Error("MARKET", StringFormat("Symbol %s could not be selected in Market Watch", m_symbol));
         return false;
      }

      long tradeMode = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE);
      if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
      {
         CFlashLogger::Error("MARKET", StringFormat("Symbol %s has trading disabled", m_symbol));
         return false;
      }

      return true;
   }

   double Bid() const { return SymbolInfoDouble(m_symbol, SYMBOL_BID); }
   double Ask() const { return SymbolInfoDouble(m_symbol, SYMBOL_ASK); }
   int    Digits() const { return (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS); }
   double Point() const { return SymbolInfoDouble(m_symbol, SYMBOL_POINT); }
   double SpreadPrice() const { return Ask() - Bid(); }

   void LogSnapshot() const
   {
      CFlashLogger::Log("MARKET",
         StringFormat("%s | Bid=%s Ask=%s Spread=%s Digits=%d",
                       m_symbol,
                       DoubleToString(Bid(), Digits()),
                       DoubleToString(Ask(), Digits()),
                       DoubleToString(SpreadPrice(), Digits()),
                       Digits()));
   }
};

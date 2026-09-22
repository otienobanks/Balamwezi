//+------------------------------------------------------------------+
//| FlashBrokerRules.mqh                                             |
//| Owner: Phase 1, Stage 1.2 - Broker Validation Engine             |
//|                                                                    |
//| Determines whether Flash's intended orders and protective stops   |
//| are legal BEFORE any trading request is sent. Every check here   |
//| reads real broker/symbol values - nothing is hard-coded for      |
//| XAUUSD's contract size, point size, tick size, or minimum stop    |
//| distance, because different brokers report different values for  |
//| the same underlying instrument.                                   |
//|                                                                    |
//| Design: every decision is implemented as a pure function first    |
//| (SpreadOk, VolumeOk, PendingDistanceOk, NormalizeToTick) that      |
//| takes plain numbers and returns a plain answer, with a thin       |
//| wrapper that supplies real SymbolInfo/AccountInfo values and      |
//| logs. This keeps the actual decision logic testable without a     |
//| live broker connection, the same pattern Stage 1.1 used for       |
//| CFlashConfig::Validate.                                            |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"

// Explicit, controlled list of XAUUSD symbol name variants Flash supports.
// A broker-specific suffix/prefix must be added here deliberately - Flash
// never accepts a symbol merely because its name contains a similar
// sequence of letters, and never silently changes the chart symbol.
static const string g_flashSupportedGoldSymbols[] =
{
   "XAUUSD", "XAUUSD.a", "XAUUSD.b", "XAUUSD.c", "XAUUSDm", "XAUUSDc", "GOLD", "GOLD.a"
};

struct SBrokerSpecs
{
   double point;
   double tickSize;
   int    digits;
   double stopsLevelPrice;    // SYMBOL_TRADE_STOPS_LEVEL converted to a price distance
   double freezeLevelPrice;   // SYMBOL_TRADE_FREEZE_LEVEL converted to a price distance
   double volumeMin;
   double volumeMax;
   double volumeStep;
   double contractSize;
   bool   tradeAllowed;
   bool   valid;              // false if retrieval itself failed
};

class CFlashBrokerRules
{
public:
   //------------------------------------------------------------------
   // Pure decision functions - no SymbolInfo/AccountInfo calls, fully
   // deterministic given their inputs, and exercised directly by the
   // self-test suite.
   //------------------------------------------------------------------

   static bool SpreadOk(const double bid, const double ask, const double maxAllowedSpread, double &outSpread)
   {
      outSpread = ask - bid;
      return (outSpread <= maxAllowedSpread + 1e-8);  // epsilon tolerance for floating-point Ask-Bid boundary cases
   }

   static double NormalizeToTick(const double price, const double tickSize)
   {
      if(tickSize <= 0.0)
         return price;
      return MathRound(price / tickSize) * tickSize;
   }

   static bool VolumeOk(const double volume, const double volMin, const double volMax, const double volStep)
   {
      if(volume < volMin - 1e-8) return false;
      if(volume > volMax + 1e-8) return false;
      if(volStep <= 0.0) return true;

      double steps = (volume - volMin) / volStep;
      double rounded = MathRound(steps);
      return (MathAbs(steps - rounded) < 1e-6);
   }

   // Pending distance check: Buy Stop must clear Ask by at least
   // minDistance; Sell Stop must clear Bid by at least minDistance.
   static bool PendingDistanceOk(const ENUM_ORDER_TYPE orderType, const double price,
                                  const double bid, const double ask, const double minDistance)
   {
      if(orderType == ORDER_TYPE_BUY_STOP)
         return (price - ask) >= minDistance - 1e-8;
      if(orderType == ORDER_TYPE_SELL_STOP)
         return (bid - price) >= minDistance - 1e-8;
      return false;
   }

   static bool SymbolNameSupported(const string symbol)
   {
      for(int i = 0; i < ArraySize(g_flashSupportedGoldSymbols); i++)
         if(symbol == g_flashSupportedGoldSymbols[i])
            return true;
      return false;
   }

   //------------------------------------------------------------------
   // Live wrappers - pull real broker/symbol values, apply the pure
   // functions above, and log the outcome with a reason.
   //------------------------------------------------------------------

   static bool GetSpecs(const string symbol, SBrokerSpecs &specs)
   {
      specs.valid = false;

      if(!SymbolSelect(symbol, true))
      {
         CFlashLogger::Error("BROKER_RULES", StringFormat("Symbol %s could not be selected", symbol));
         return false;
      }

      specs.point         = SymbolInfoDouble(symbol, SYMBOL_POINT);
      specs.digits        = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      specs.volumeMin      = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      specs.volumeMax      = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      specs.volumeStep     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      specs.contractSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);

      double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      specs.tickSize = (tickSize > 0.0) ? tickSize : specs.point;

      long stopsLevelPoints  = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      long freezeLevelPoints = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      specs.stopsLevelPrice  = stopsLevelPoints  * specs.point;
      specs.freezeLevelPrice = freezeLevelPoints * specs.point;

      long tradeMode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
      specs.tradeAllowed = (tradeMode == SYMBOL_TRADE_MODE_FULL || tradeMode == SYMBOL_TRADE_MODE_LONGONLY
                            || tradeMode == SYMBOL_TRADE_MODE_SHORTONLY);

      if(specs.point <= 0.0 || specs.volumeMin <= 0.0)
      {
         CFlashLogger::Error("BROKER_RULES", StringFormat("Symbol %s returned unusable specification data", symbol));
         return false;
      }

      specs.valid = true;
      return true;
   }

   static bool ValidateSymbolSupported(const string symbol)
   {
      if(!SymbolNameSupported(symbol))
      {
         CFlashLogger::Error("BROKER_RULES",
            StringFormat("Symbol %s is not an explicitly supported XAUUSD variant. Trading blocked.", symbol));
         return false;
      }
      return true;
   }

   // Blocks a NEW setup only. Emergency protective action on an existing
   // position must never be gated by this check - callers managing an
   // already-open position must not call this function.
   static bool ValidateSpreadForNewSetup(const string symbol, const double maxAllowedSpread)
   {
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double spread;
      bool ok = SpreadOk(bid, ask, maxAllowedSpread, spread);

      if(!ok)
         CFlashLogger::Log("BROKER_RULES",
            StringFormat("New entry blocked: Current spread %s exceeds maximum allowed spread %s.",
                         DoubleToString(spread, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                         DoubleToString(maxAllowedSpread, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS))));
      return ok;
   }

   static double NormalizePrice(const string symbol, const double price, const SBrokerSpecs &specs)
   {
      return NormalizeToTick(price, specs.tickSize);
   }

   static bool ValidatePendingDistance(const string symbol, const ENUM_ORDER_TYPE orderType,
                                        const double price, const SBrokerSpecs &specs)
   {
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double minDistance = MathMax(specs.stopsLevelPrice, 0.0);

      bool ok = PendingDistanceOk(orderType, price, bid, ask, minDistance);
      if(!ok)
         CFlashLogger::Error("BROKER_RULES",
            StringFormat("%s at %s fails broker minimum distance requirement (%s)",
                         EnumToString(orderType), DoubleToString(price, specs.digits),
                         DoubleToString(minDistance, specs.digits)));
      return ok;
   }

   static bool ValidateVolume(const double volume, const SBrokerSpecs &specs)
   {
      bool ok = VolumeOk(volume, specs.volumeMin, specs.volumeMax, specs.volumeStep);
      if(!ok)
         CFlashLogger::Error("BROKER_RULES",
            StringFormat("Lot Size Per Position %s is invalid for this symbol (min=%s max=%s step=%s)",
                         DoubleToString(volume, 2), DoubleToString(specs.volumeMin, 2),
                         DoubleToString(specs.volumeMax, 2), DoubleToString(specs.volumeStep, 2)));
      return ok;
   }

   // Conservative margin check: assumes BOTH directions of the initial
   // setup could execute before opposite-order cancellation completes, per
   // Phase 1 build prompt Section 7.8 - never assumes the broker cancels
   // the opposite side before it can fill.
   static bool ValidateMarginForBothSides(const string symbol, const double volumePerSide, const double price)
   {
      double marginBuy = 0.0, marginSell = 0.0;
      bool gotBuy  = OrderCalcMargin(ORDER_TYPE_BUY,  symbol, volumePerSide, price, marginBuy);
      bool gotSell = OrderCalcMargin(ORDER_TYPE_SELL, symbol, volumePerSide, price, marginSell);

      if(!gotBuy || !gotSell)
      {
         CFlashLogger::Error("BROKER_RULES", "Margin calculation failed - cannot verify affordability");
         return false;
      }

      double required = marginBuy + marginSell;
      double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

      if(required > free)
      {
         CFlashLogger::Error("BROKER_RULES",
            StringFormat("Insufficient margin: requires %s, free margin %s",
                         DoubleToString(required, 2), DoubleToString(free, 2)));
         return false;
      }
      return true;
   }

   static bool IsHedgingAccount()
   {
      return (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
   }

   // Multiple independent positions per setup require a hedging account.
   // On a netting account, PositionsPerSetup must be exactly 1 - Flash
   // must reject the configuration rather than silently aggregate it.
   static bool ValidateAccountCompatibility(const int positionsPerSetup)
   {
      if(positionsPerSetup > 1 && !IsHedgingAccount())
      {
         CFlashLogger::Error("BROKER_RULES",
            "Number of Positions Per Setup > 1 requires a hedging account. This account nets positions. Trading blocked.");
         return false;
      }
      return true;
   }
};

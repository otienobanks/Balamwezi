//+------------------------------------------------------------------+
//| FlashSizing.mqh                                                  |
//| Phase 2 Stage 2.3 - Position Sizing                              |
//|                                                                    |
//| Two sizing methods: Fixed Lot Size (Lot Size Per Position times   |
//| Number of Positions Per Setup) and Percentage of Equity, where    |
//| the configured risk percentage applies to the WHOLE setup's       |
//| initial position group, never per-position independently. The     |
//| monetary loss of the actual proposed entry-to-SL distance is       |
//| computed via OrderCalcProfit against the real broker contract      |
//| specification - never a fixed assumed dollar-per-lot-per-$1-move. |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"

struct SFlashSizingResult
{
   bool   valid;
   double volumePerPosition;
   double totalVolume;
   string rejectReason;
};

class CFlashSizing
{
public:
   //------------------------------------------------------------------
   // Pure functions
   //------------------------------------------------------------------

   static SFlashSizingResult FixedLot(const double lotSizePerPosition, const int positionsPerSetup,
                                       const double volMin, const double volMax, const double volStep)
   {
      SFlashSizingResult r;
      r.valid = false; r.volumePerPosition = 0.0; r.totalVolume = 0.0; r.rejectReason = "";

      if(!VolumeValid(lotSizePerPosition, volMin, volMax, volStep))
      {
         r.rejectReason = "Lot Size Per Position is invalid for this symbol's volume constraints";
         return r;
      }

      r.valid = true;
      r.volumePerPosition = lotSizePerPosition;
      r.totalVolume = lotSizePerPosition * positionsPerSetup;
      return r;
   }

   // riskBudget = equity * (riskPercentPerSetup / 100). lossPerLotAtDistance
   // is the monetary loss of ONE lot moving from the proposed entry to the
   // proposed SL, computed by the caller via OrderCalcProfit against the
   // real contract specification - this function never assumes a fixed
   // dollar figure per lot per unit price move.
   static SFlashSizingResult PercentEquity(const double equity, const double riskPercentPerSetup,
                                            const int positionsPerSetup, const double lossPerLotAtDistance,
                                            const double volMin, const double volMax, const double volStep)
   {
      SFlashSizingResult r;
      r.valid = false; r.volumePerPosition = 0.0; r.totalVolume = 0.0; r.rejectReason = "";

      if(lossPerLotAtDistance <= 0.0)
      {
         r.rejectReason = "Non-positive computed loss-per-lot at the proposed entry-to-SL distance";
         return r;
      }
      if(positionsPerSetup < 1)
      {
         r.rejectReason = "Number of Positions Per Setup must be at least 1";
         return r;
      }

      double riskBudget = equity * (riskPercentPerSetup / 100.0);
      double maxTotalVolume = riskBudget / lossPerLotAtDistance;

      double steppedTotal = (volStep > 0.0) ? MathFloor(maxTotalVolume / volStep) * volStep : maxTotalVolume;
      if(steppedTotal < volMin - 1e-8)
      {
         r.rejectReason = "Equity risk budget is insufficient to reach the broker's minimum volume for this setup";
         return r;
      }

      double perPosition = (volStep > 0.0)
         ? MathFloor((steppedTotal / positionsPerSetup) / volStep) * volStep
         : (steppedTotal / positionsPerSetup);

      if(perPosition < volMin - 1e-8)
      {
         r.rejectReason = "Equity risk budget divided across the requested positions falls below the broker's minimum volume per position";
         return r;
      }
      if(perPosition > volMax + 1e-8)
         perPosition = MathFloor(volMax / volStep) * volStep;

      r.valid = true;
      r.volumePerPosition = perPosition;
      r.totalVolume = perPosition * positionsPerSetup;
      return r;
   }

   static bool VolumeValid(const double volume, const double volMin, const double volMax, const double volStep)
   {
      if(volume < volMin - 1e-8) return false;
      if(volume > volMax + 1e-8) return false;
      if(volStep <= 0.0) return true;
      double steps = (volume - volMin) / volStep;
      double rounded = MathRound(steps);
      return (MathAbs(steps - rounded) < 1e-6);
   }

   //------------------------------------------------------------------
   // Live wrapper - computes loss-per-lot for the proposed entry/SL pair
   // using OrderCalcProfit, MT5's own profit-calculation method, then
   // dispatches to the configured sizing method.
   //------------------------------------------------------------------
   static bool ComputeLossPerLot(const string symbol, const bool isBuyDirection,
                                  const double entryPrice, const double slPrice, double &outLossPerLot)
   {
      double profit = 0.0;
      ENUM_ORDER_TYPE calcType = isBuyDirection ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      bool ok = OrderCalcProfit(calcType, symbol, 1.0, entryPrice, slPrice, profit);
      if(!ok)
      {
         CFlashLogger::Error("SIZING", "OrderCalcProfit failed while computing loss-per-lot for percentage-of-equity sizing");
         return false;
      }
      outLossPerLot = MathAbs(profit);
      return true;
   }
};

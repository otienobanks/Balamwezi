//+------------------------------------------------------------------+
//| FlashTrailing.mqh                                                |
//| Phase 2 Stage 2.1 - Trailing Stop Engine                         |
//|                                                                    |
//| Activation and ratchet formulas use the ACTUAL filled entry       |
//| price, never the originally requested pending price. Before       |
//| activation the original Phase 1 SL is left completely unchanged;  |
//| if it hits before activation, that is a normal finished setup,    |
//| not a reversal trigger. The ratchet never moves a stop backward,  |
//| and a broker-rejected modification never widens the current SL,   |
//| never silently changes the configured trailing distance, and      |
//| always retains the last confirmed SL.                              |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"
#include "..\Execution\FlashBrokerRules.mqh"
#include "..\Execution\FlashOrders.mqh"

class CFlashTrailing
{
public:
   //------------------------------------------------------------------
   // Pure functions - exercised directly by the self-test suite.
   //------------------------------------------------------------------

   static double FavorableMovementBuy(const double currentBid, const double actualEntryPrice)
   {
      return currentBid - actualEntryPrice;
   }

   static double FavorableMovementSell(const double actualEntryPrice, const double currentAsk)
   {
      return actualEntryPrice - currentAsk;
   }

   static bool ActivationReached(const double favorableMovement, const double activationDistance)
   {
      return favorableMovement >= activationDistance;
   }

   static double CandidateBuySL(const double currentBid, const double trailingStopDistance)
   {
      return currentBid - trailingStopDistance;
   }

   static double CandidateSellSL(const double currentAsk, const double trailingStopDistance)
   {
      return currentAsk + trailingStopDistance;
   }

   // Ratchet-only: never moves the stop backward for its direction.
   static double NewBuySL(const double currentSL, const double candidateSL)
   {
      return MathMax(currentSL, candidateSL);
   }
   static double NewSellSL(const double currentSL, const double candidateSL)
   {
      return MathMin(currentSL, candidateSL);
   }

   static bool MeetsMinimumUpdate(const double newSL, const double lastConfirmedSL, const double minimumUpdate,
                                   const bool isBuyDirection)
   {
      double improvement = isBuyDirection ? (newSL - lastConfirmedSL) : (lastConfirmedSL - newSL);
      return improvement >= minimumUpdate - 1e-8;
   }

   //------------------------------------------------------------------
   // Live wrapper - evaluates one setup's trailing state against real
   // broker quotes/specs and verified actual position SLs, and only
   // updates SFlashSetup's persisted fields from BROKER-CONFIRMED values,
   // never from the requested candidate alone.
   //
   // Returns true if the state was updated (activation, or a confirmed SL
   // ratchet); logs and returns false on any broker rejection or unmet
   // minimum-update threshold, without altering LastConfirmedSL.
   //------------------------------------------------------------------
   static bool UpdateSetup(const string symbol, const bool isBuyDirection, const double actualEntryPrice,
                            const double trailingActivationDistance, const double trailingStopDistance,
                            const double minimumTrailingUpdate, const SBrokerSpecs &specs,
                            ulong &positionTickets[], bool &trailingActive, double &lastConfirmedSL,
                            double &lastConfirmedTrailingReference)
   {
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

      if(!trailingActive)
      {
         double movement = isBuyDirection ? FavorableMovementBuy(bid, actualEntryPrice)
                                           : FavorableMovementSell(actualEntryPrice, ask);
         if(!ActivationReached(movement, trailingActivationDistance))
            return false; // original Phase 1 SL remains in force - not an error

         trailingActive = true;
         CFlashLogger::Log("TRAILING",
            StringFormat("Activation reached (%s direction, favorable movement=%s >= activation distance=%s)",
                         isBuyDirection ? "BUY" : "SELL", DoubleToString(movement, specs.digits),
                         DoubleToString(trailingActivationDistance, specs.digits)));

         // Seed lastConfirmedSL from the position's actual current SL so the
         // very first ratchet compares against reality, not zero.
         if(ArraySize(positionTickets) > 0 && PositionSelectByTicket(positionTickets[0]))
            lastConfirmedSL = PositionGetDouble(POSITION_SL);
      }

      double candidate = isBuyDirection ? CandidateBuySL(bid, trailingStopDistance)
                                         : CandidateSellSL(ask, trailingStopDistance);
      double proposedNewSL = isBuyDirection ? NewBuySL(lastConfirmedSL, candidate)
                                             : NewSellSL(lastConfirmedSL, candidate);

      if(!MeetsMinimumUpdate(proposedNewSL, lastConfirmedSL, minimumTrailingUpdate, isBuyDirection))
         return false; // below minimum update - not an error, simply not yet due

      double normalizedSL = CFlashBrokerRules::NormalizeToTick(proposedNewSL, specs.tickSize);

      // Legality: distance from current price to the new SL must clear the
      // broker's StopsLevel. Never widen: if illegal, retain lastConfirmedSL.
      double distanceFromPrice = isBuyDirection ? (bid - normalizedSL) : (normalizedSL - ask);
      if(distanceFromPrice < specs.stopsLevelPrice - 1e-8)
      {
         CFlashLogger::Error("TRAILING",
            StringFormat("Proposed SL %s fails broker StopsLevel distance - retaining last confirmed SL %s",
                         DoubleToString(normalizedSL, specs.digits), DoubleToString(lastConfirmedSL, specs.digits)));
         return false;
      }

      bool allModified = true;
      for(int i = 0; i < ArraySize(positionTickets); i++)
      {
         if(!PositionSelectByTicket(positionTickets[i])) continue; // already closed, skip
         double currentActualSL = PositionGetDouble(POSITION_SL);
         // Verify this individual position's actual SL still needs the move
         // (never move backward even if another leg's state differs).
         bool needsMove = isBuyDirection ? (normalizedSL > currentActualSL + 1e-8)
                                          : (normalizedSL < currentActualSL - 1e-8);
         if(!needsMove) continue;

         if(!CFlashOrders::SetPositionSL(positionTickets[i], normalizedSL))
            allModified = false;
      }

      if(!allModified)
      {
         CFlashLogger::Error("TRAILING", "Partial trailing SL modification across the setup's positions - reconciling actual individual stops before any reversal action");
         return false;
      }

      lastConfirmedSL = normalizedSL;
      lastConfirmedTrailingReference = normalizedSL;
      CFlashLogger::Log("TRAILING", StringFormat("Trailing SL confirmed at %s", DoubleToString(normalizedSL, specs.digits)));
      return true;
   }
};

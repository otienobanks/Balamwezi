//+------------------------------------------------------------------+
//| FlashReversal.mqh                                                |
//| Phase 2 Stage 2.2 - Reversal Decision Functions                  |
//|                                                                    |
//| Reversal execution is NOT atomic on any broker: the trailing SL   |
//| hitting and the opposite pending order filling are two separate  |
//| transactions. This file holds the pure gating/decision functions |
//| for the reversal protocol; the multi-step execution and           |
//| transaction-driven reconciliation sequence itself (arming,         |
//| detecting execution, closing remaining old-direction exposure,    |
//| verifying flat, protecting the new direction) is orchestrated in  |
//| FlashEA.mq5 because it must coordinate live setup state that      |
//| cannot be captured as a pure function.                             |
//|                                                                    |
//| Reversal is implemented and validated ONLY on a hedging account.  |
//| On a netting account, Flash never arms a reversal order at all -  |
//| a flattening transaction on a netting account must never be       |
//| silently treated as a completed reversal.                          |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"

class CFlashReversal
{
public:
   //------------------------------------------------------------------
   // Pure functions
   //------------------------------------------------------------------

   // The opposite pending order's reference price is the confirmed
   // trailing SL of the direction being reversed away from - never a
   // separately invented level.
   static double ReversalReferencePrice(const double confirmedTrailingSL)
   {
      return confirmedTrailingSL;
   }

   // Sequencing gate: a reversal order may only be armed after the
   // initial fill is confirmed, the initial opposite pending order is
   // cancelled, the initial SL is verified present, trailing has
   // activated, AND the trailing SL modification itself is confirmed -
   // never merely requested.
   static bool EligibleToArm(const bool initialFillConfirmed, const bool oppositeCancelled,
                              const bool initialSLVerified, const bool trailingActivated,
                              const bool trailingSLConfirmed)
   {
      return initialFillConfirmed && oppositeCancelled && initialSLVerified &&
             trailingActivated && trailingSLConfirmed;
   }

   // The intended new-direction volume after a reversal is the setup's
   // permitted volume under the current sizing policy for a fresh leg -
   // never the old exposure doubled, and never accumulated across legs.
   static double IntendedReversalVolume(const double permittedSetupVolume)
   {
      return permittedSetupVolume;
   }

   static bool OldExposureFullyClosed(const double remainingOldVolume)
   {
      return remainingOldVolume <= 0.0000001;
   }

   static bool NewExposureMatchesTarget(const double actualNewVolume, const double targetVolume, const double volumeStep)
   {
      double tolerance = (volumeStep > 0.0) ? (volumeStep / 2.0) : 0.0000001;
      return MathAbs(actualNewVolume - targetVolume) < tolerance;
   }

   // Protective stop for the NEW direction after a reversal fill. This
   // deliberately does not reuse the frozen Phase 1 "original opposite
   // entry level" - that level belongs only to the initial setup. Instead
   // it applies the same configured Trailing Stop Distance as a fresh
   // protective distance from the new leg's actual fill price, giving
   // every reversal leg a defined, documented, non-zero initial stop.
   //   new BUY leg (reversal from SELL):  SL = actualNewFillPrice - trailingStopDistance
   //   new SELL leg (reversal from BUY):  SL = actualNewFillPrice + trailingStopDistance
   static double ProtectiveStopForNewDirection(const bool newDirectionIsBuy, const double actualNewFillPrice,
                                                const double trailingStopDistance)
   {
      return newDirectionIsBuy ? (actualNewFillPrice - trailingStopDistance)
                                : (actualNewFillPrice + trailingStopDistance);
   }
};

//+------------------------------------------------------------------+
//| FlashExecutionControl.mqh                                        |
//| Phase 3 Stage 3.3 - Execution Failure Control and Safety States   |
//|                                                                    |
//| Replaces the Phase 2 approach of "wait a fixed cooldown, then     |
//| resend the identical request forever" (the mechanism behind the   |
//| 1,418-request retcode-10030 incident) with an explicit, bounded,  |
//| observable retry policy that first classifies WHY a request       |
//| failed before deciding whether resending it, unchanged, could      |
//| ever succeed.                                                      |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"

//------------------------------------------------------------------
// Outcome classification. Distinct from the raw MQL5 retcode: this is
// what the retcode MEANS for retry purposes, decided once here so no
// call site has to re-derive it.
//------------------------------------------------------------------
enum ENUM_FLASH_EXEC_OUTCOME
{
   FLASH_EXEC_FULL_SUCCESS = 0,
   FLASH_EXEC_PARTIAL_SUCCESS,
   FLASH_EXEC_PENDING_CONFIRMATION,     // request accepted, final state not yet knowable from this response alone
   FLASH_EXEC_TEMP_MARKET_CLOSED,
   FLASH_EXEC_INVALID_FILLING_POLICY,
   FLASH_EXEC_INVALID_STOPS_OR_PRICE,
   FLASH_EXEC_INSUFFICIENT_MARGIN,
   FLASH_EXEC_TRADING_DISABLED,
   FLASH_EXEC_CONNECTION_UNCERTAIN,
   FLASH_EXEC_OTHER_REJECTED
};

enum ENUM_FLASH_RETRY_DECISION
{
   FLASH_RETRY_RETRY_NOW = 0,       // within budget and past the minimum delay - safe to attempt again
   FLASH_RETRY_WAIT,                // within budget but the minimum delay has not elapsed yet
   FLASH_RETRY_ESCALATE_EXHAUSTED,  // retryable outcome, but the attempt budget or time window is used up
   FLASH_RETRY_ESCALATE_NOT_RETRYABLE, // outcome is deterministic/configuration-related - resending unchanged cannot help
   FLASH_RETRY_ALREADY_ESCALATED    // this operation has already been escalated; do not act again silently
};

string FlashExecOutcomeToString(const ENUM_FLASH_EXEC_OUTCOME o)
{
   switch(o)
   {
      case FLASH_EXEC_FULL_SUCCESS:            return "FULL_SUCCESS";
      case FLASH_EXEC_PARTIAL_SUCCESS:         return "PARTIAL_SUCCESS";
      case FLASH_EXEC_PENDING_CONFIRMATION:    return "PENDING_CONFIRMATION";
      case FLASH_EXEC_TEMP_MARKET_CLOSED:      return "TEMP_MARKET_CLOSED";
      case FLASH_EXEC_INVALID_FILLING_POLICY:  return "INVALID_FILLING_POLICY";
      case FLASH_EXEC_INVALID_STOPS_OR_PRICE:  return "INVALID_STOPS_OR_PRICE";
      case FLASH_EXEC_INSUFFICIENT_MARGIN:     return "INSUFFICIENT_MARGIN";
      case FLASH_EXEC_TRADING_DISABLED:        return "TRADING_DISABLED";
      case FLASH_EXEC_CONNECTION_UNCERTAIN:    return "CONNECTION_UNCERTAIN";
      default:                                 return "OTHER_REJECTED";
   }
}

//------------------------------------------------------------------
// Retry budget for one in-flight operation (e.g. one setup's exit
// attempt, one specific pending-order cancellation). Caller owns the
// struct's lifetime; DecideNextAction never persists anything itself -
// persistence of the surrounding intent is Stage 3.2's job.
//------------------------------------------------------------------
struct SFlashRetryBudget
{
   string   OperationTag;      // e.g. "SETUP_EXIT:2026.09.18 07:14:18-999002"
   int      AttemptCount;
   datetime FirstAttemptAt;
   datetime LastAttemptAt;
   int      MaxAttempts;
   int      MinDelaySeconds;
   int      MaxWindowSeconds;
   bool     Escalated;

   void Init(const string tag)
   {
      OperationTag = tag;
      AttemptCount = 0;
      FirstAttemptAt = 0;
      LastAttemptAt = 0;
      // Defaults below are this project's own judgment call, not a
      // universal broker guarantee - documented in SPECIFICATION.md /
      // the Phase 3 report rather than claimed safe for every broker.
      // MaxAttempts=5: enough to absorb a short burst of transient
      // rejections (a momentary requote, a brief connection blip)
      // without approaching anything like the 1,418-attempt incident.
      // MinDelaySeconds=2: unchanged from the Phase 2 throttle that is
      // already live-proven not to overwhelm the trade server.
      // MaxWindowSeconds=30: bounds total wall-clock retry exposure to
      // a window well under typical broker reconnection/session-reset
      // timers, while still allowing all 5 attempts at the minimum
      // spacing (5 x 2s = 10s) plus margin for slower responses.
      MaxAttempts = 5;
      MinDelaySeconds = 2;
      MaxWindowSeconds = 30;
      Escalated = false;
   }
};

class CFlashExecutionControl
{
public:
   //------------------------------------------------------------------
   // Pure retcode classifier. Inspects the immediate trade-server
   // response only; the caller is responsible for also checking actual
   // broker state afterward per Stage 3.3.2's instruction that an
   // accepted request may still require reconciliation.
   //------------------------------------------------------------------
   static ENUM_FLASH_EXEC_OUTCOME ClassifyResult(const bool sendReturnedTrue, const uint retcode, const double dealVolume, const double requestedVolume)
   {
      if(sendReturnedTrue && retcode == TRADE_RETCODE_DONE)
      {
         if(requestedVolume > 0.0 && dealVolume > 0.0 && dealVolume < requestedVolume - 0.0000001)
            return FLASH_EXEC_PARTIAL_SUCCESS;
         return FLASH_EXEC_FULL_SUCCESS;
      }
      if(retcode == TRADE_RETCODE_DONE_PARTIAL)
         return FLASH_EXEC_PARTIAL_SUCCESS;

      switch(retcode)
      {
         case TRADE_RETCODE_PLACED:
            return FLASH_EXEC_PENDING_CONFIRMATION;
         case TRADE_RETCODE_MARKET_CLOSED:
            return FLASH_EXEC_TEMP_MARKET_CLOSED;
         case TRADE_RETCODE_INVALID_FILL:
            return FLASH_EXEC_INVALID_FILLING_POLICY;
         case TRADE_RETCODE_INVALID_STOPS:
         case TRADE_RETCODE_INVALID_PRICE:
         case TRADE_RETCODE_INVALID:
            return FLASH_EXEC_INVALID_STOPS_OR_PRICE;
         case TRADE_RETCODE_NO_MONEY:
            return FLASH_EXEC_INSUFFICIENT_MARGIN;
         case TRADE_RETCODE_TRADE_DISABLED:
         case 10027: // "AutoTrading disabled by client" - observed live, 2026-09-18
            return FLASH_EXEC_TRADING_DISABLED;
         case TRADE_RETCODE_REQUOTE:
         case TRADE_RETCODE_PRICE_OFF:
         case TRADE_RETCODE_TIMEOUT:
         case TRADE_RETCODE_CONNECTION:
         case TRADE_RETCODE_TOO_MANY_REQUESTS:
            return FLASH_EXEC_CONNECTION_UNCERTAIN;
         default:
            return FLASH_EXEC_OTHER_REJECTED;
      }
   }

   // Deterministic, configuration-related outcomes are never retryable
   // unchanged - a different filling mode, corrected stops, or an
   // operator/account-level change is required, not a resend.
   static bool IsRetryable(const ENUM_FLASH_EXEC_OUTCOME outcome)
   {
      switch(outcome)
      {
         case FLASH_EXEC_TEMP_MARKET_CLOSED:
         case FLASH_EXEC_CONNECTION_UNCERTAIN:
            return true;
         default:
            return false; // includes INVALID_FILLING_POLICY - the caller must change the filling mode, not blindly resend
      }
   }

   //------------------------------------------------------------------
   // Pure decision function - given a budget and the just-observed
   // outcome, decide what happens next. Does not send anything itself.
   //------------------------------------------------------------------
   static ENUM_FLASH_RETRY_DECISION DecideNextAction(const SFlashRetryBudget &budget, const ENUM_FLASH_EXEC_OUTCOME outcome, const datetime now)
   {
      if(budget.Escalated)
         return FLASH_RETRY_ALREADY_ESCALATED;

      if(!IsRetryable(outcome))
         return FLASH_RETRY_ESCALATE_NOT_RETRYABLE;

      if(budget.AttemptCount >= budget.MaxAttempts)
         return FLASH_RETRY_ESCALATE_EXHAUSTED;

      if(budget.FirstAttemptAt != 0 && (now - budget.FirstAttemptAt) > budget.MaxWindowSeconds)
         return FLASH_RETRY_ESCALATE_EXHAUSTED;

      if(budget.LastAttemptAt != 0 && (now - budget.LastAttemptAt) < budget.MinDelaySeconds)
         return FLASH_RETRY_WAIT;

      return FLASH_RETRY_RETRY_NOW;
   }

   // Records an attempt into the budget. Caller calls this immediately
   // before sending, so FirstAttemptAt/LastAttemptAt/AttemptCount stay
   // accurate even if the send itself throws or the terminal restarts
   // mid-request.
   static void RecordAttempt(SFlashRetryBudget &budget, const datetime now)
   {
      if(budget.AttemptCount == 0)
         budget.FirstAttemptAt = now;
      budget.AttemptCount++;
      budget.LastAttemptAt = now;
   }

   static void LogDecision(const SFlashRetryBudget &budget, const ENUM_FLASH_EXEC_OUTCOME outcome, const ENUM_FLASH_RETRY_DECISION decision)
   {
      CFlashLogger::Log("SAFETY",
         StringFormat("ExecutionControl | op=%s attempt=%d/%d window=%ds outcome=%s decision=%s",
            budget.OperationTag, budget.AttemptCount, budget.MaxAttempts, budget.MaxWindowSeconds,
            FlashExecOutcomeToString(outcome), EnumToString(decision)));
   }
};

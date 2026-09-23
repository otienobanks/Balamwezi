//+------------------------------------------------------------------+
//| FlashIntent.mqh                                                  |
//| Phase 3 Stage 3.2 - Persistent Intent and Restart Recovery        |
//|                                                                    |
//| A requested action is not the same as a completed action. This    |
//| file persists that distinction (CLOSE_REQUESTED vs               |
//| POSITION_CONFIRMED_CLOSED; CANCEL_REQUESTED vs                    |
//| ORDER_CONFIRMED_CANCELLED) using the same GlobalVariable-per-field|
//| mechanism Phase 2's Core/FlashPersistence.mqh already uses, keyed |
//| by symbol and magic, so it is compatible with the existing        |
//| architecture rather than introducing a new storage layer.         |
//|                                                                    |
//| Storage properties, documented per Stage 3.2.3's requirement:      |
//| - Atomicity: each individual GlobalVariableSet() call is atomic   |
//|   at the terminal level. A group of related fields (e.g. setting  |
//|   CloseIntentState, CloseIntentTicket, and CloseIntentVolume      |
//|   together) is NOT atomic as a group - a crash between two of     |
//|   those three writes is possible. Recovery code must therefore    |
//|   treat CloseIntentState as the field that governs whether the    |
//|   other fields are meaningful (state is always written first),   |
//|   and must re-read live broker state rather than trusting the     |
//|   persisted volume/ticket alone if anything looks inconsistent.   |
//| - Durability: survives EA reattachment, terminal restart, and     |
//|   power loss, because MT5 GlobalVariables are written to disk     |
//|   periodically and on terminal shutdown. A hard crash between the |
//|   periodic disk flush and the in-memory write is a real, if rare, |
//|   gap - not eliminated by this design, only reduced to the same   |
//|   residual risk Phase 2's existing persistence already accepts.   |
//| - Naming: "FLASH_P3_INTENT_<field>_<symbol>_<magic>", parallel to |
//|   Phase 2's "FLASH_P2_<field>_<symbol>_<magic>" convention.       |
//| - Cleanup: cleared only once the corresponding action is          |
//|   confirmed (never on a mere timeout), by ClearCloseIntent /       |
//|   ClearCancelIntent, called from the same reconciliation point     |
//|   that already calls FlashPersistence::ClearAll.                   |
//| - Account isolation: GlobalVariables are terminal-wide, not        |
//|   account-wide. If the SAME terminal is later logged into a        |
//|   DIFFERENT account while these keys still exist, stale intent     |
//|   from the previous account could be read as if it belonged to    |
//|   the new one. This is an inherited property of Phase 2's own      |
//|   persistence design (not a new gap introduced here) and is        |
//|   flagged here per the instruction to document rather than          |
//|   silently resolve an ambiguity: no fix is applied in Phase 3       |
//|   without separate authorization, since scoping one (e.g. keying   |
//|   by account login as well) is itself a design decision.           |
//+------------------------------------------------------------------+
#property strict
#include "FlashLogger.mqh"

enum ENUM_FLASH_INTENT_STATE
{
   FLASH_INTENT_NONE = 0,
   FLASH_INTENT_CLOSE_REQUESTED,
   FLASH_INTENT_POSITION_CONFIRMED_CLOSED,
   FLASH_INTENT_CANCEL_REQUESTED,
   FLASH_INTENT_ORDER_CONFIRMED_CANCELLED
};

enum ENUM_FLASH_CLOSE_OUTCOME
{
   FLASH_CLOSE_OUTCOME_FULLY_CLOSED = 0,
   FLASH_CLOSE_OUTCOME_PARTIALLY_CLOSED,
   FLASH_CLOSE_OUTCOME_NOT_CLOSED
};

class CFlashIntent
{
private:
   static string Key(const string field, const string symbol, const long magic)
   {
      return "FLASH_P3_INTENT_" + field + "_" + symbol + "_" + IntegerToString((int)magic);
   }

public:
   //------------------------------------------------------------------
   // Close intent
   //------------------------------------------------------------------
   static void RequestClose(const string symbol, const long magic, const ulong ticket, const double requestedVolume)
   {
      // State is written FIRST and separately, per the atomicity note
      // above - if the process dies immediately after this line, a
      // subsequent read sees CLOSE_REQUESTED with a still-zero ticket,
      // which recovery code must treat as "unresolved, re-derive from
      // broker state" rather than trusting the zero ticket literally.
      GlobalVariableSet(Key("CLOSE_STATE", symbol, magic), (double)FLASH_INTENT_CLOSE_REQUESTED);
      GlobalVariableSet(Key("CLOSE_TICKET", symbol, magic), (double)ticket);
      GlobalVariableSet(Key("CLOSE_VOLUME", symbol, magic), requestedVolume);
      GlobalVariableSet(Key("CLOSE_AT", symbol, magic), (double)TimeCurrent());
      CFlashLogger::Log("RECONCILE", StringFormat("Intent persisted: CLOSE_REQUESTED ticket=%I64u volume=%s", ticket, DoubleToString(requestedVolume, 2)));
   }

   static void ConfirmClosed(const string symbol, const long magic)
   {
      GlobalVariableSet(Key("CLOSE_STATE", symbol, magic), (double)FLASH_INTENT_POSITION_CONFIRMED_CLOSED);
      CFlashLogger::Log("RECONCILE", "Intent confirmed: POSITION_CONFIRMED_CLOSED");
   }

   static void ClearCloseIntent(const string symbol, const long magic)
   {
      GlobalVariableDel(Key("CLOSE_STATE", symbol, magic));
      GlobalVariableDel(Key("CLOSE_TICKET", symbol, magic));
      GlobalVariableDel(Key("CLOSE_VOLUME", symbol, magic));
      GlobalVariableDel(Key("CLOSE_AT", symbol, magic));
   }

   static ENUM_FLASH_INTENT_STATE LoadCloseState(const string symbol, const long magic)
   {
      string k = Key("CLOSE_STATE", symbol, magic);
      if(!GlobalVariableCheck(k)) return FLASH_INTENT_NONE;
      return (ENUM_FLASH_INTENT_STATE)(int)GlobalVariableGet(k);
   }

   static ulong LoadCloseTicket(const string symbol, const long magic)
   {
      string k = Key("CLOSE_TICKET", symbol, magic);
      return GlobalVariableCheck(k) ? (ulong)GlobalVariableGet(k) : 0;
   }

   static double LoadCloseVolume(const string symbol, const long magic)
   {
      string k = Key("CLOSE_VOLUME", symbol, magic);
      return GlobalVariableCheck(k) ? GlobalVariableGet(k) : 0.0;
   }

   static datetime LoadCloseRequestedAt(const string symbol, const long magic)
   {
      string k = Key("CLOSE_AT", symbol, magic);
      return GlobalVariableCheck(k) ? (datetime)GlobalVariableGet(k) : 0;
   }

   static bool CloseIntentOutstanding(const string symbol, const long magic)
   {
      return LoadCloseState(symbol, magic) == FLASH_INTENT_CLOSE_REQUESTED;
   }

   //------------------------------------------------------------------
   // Cancel intent (same pattern, for pending-order cancellation)
   //------------------------------------------------------------------
   static void RequestCancel(const string symbol, const long magic, const ulong ticket)
   {
      GlobalVariableSet(Key("CANCEL_STATE", symbol, magic), (double)FLASH_INTENT_CANCEL_REQUESTED);
      GlobalVariableSet(Key("CANCEL_TICKET", symbol, magic), (double)ticket);
      GlobalVariableSet(Key("CANCEL_AT", symbol, magic), (double)TimeCurrent());
      CFlashLogger::Log("RECONCILE", StringFormat("Intent persisted: CANCEL_REQUESTED ticket=%I64u", ticket));
   }

   static void ConfirmCancelled(const string symbol, const long magic)
   {
      GlobalVariableSet(Key("CANCEL_STATE", symbol, magic), (double)FLASH_INTENT_ORDER_CONFIRMED_CANCELLED);
      CFlashLogger::Log("RECONCILE", "Intent confirmed: ORDER_CONFIRMED_CANCELLED");
   }

   static void ClearCancelIntent(const string symbol, const long magic)
   {
      GlobalVariableDel(Key("CANCEL_STATE", symbol, magic));
      GlobalVariableDel(Key("CANCEL_TICKET", symbol, magic));
      GlobalVariableDel(Key("CANCEL_AT", symbol, magic));
   }

   static ENUM_FLASH_INTENT_STATE LoadCancelState(const string symbol, const long magic)
   {
      string k = Key("CANCEL_STATE", symbol, magic);
      if(!GlobalVariableCheck(k)) return FLASH_INTENT_NONE;
      return (ENUM_FLASH_INTENT_STATE)(int)GlobalVariableGet(k);
   }

   static ulong LoadCancelTicket(const string symbol, const long magic)
   {
      string k = Key("CANCEL_TICKET", symbol, magic);
      return GlobalVariableCheck(k) ? (ulong)GlobalVariableGet(k) : 0;
   }

   static bool CancelIntentOutstanding(const string symbol, const long magic)
   {
      return LoadCancelState(symbol, magic) == FLASH_INTENT_CANCEL_REQUESTED;
   }

   //------------------------------------------------------------------
   // Recovery reason (why Flash is in RECOVERY_REQUIRED / blocked),
   // persisted as a short code string so a restart can log WHY it is
   // still blocked rather than only THAT it is blocked.
   //------------------------------------------------------------------
   static void SaveRecoveryReasonCode(const string symbol, const long magic, const string code)
   {
      // GlobalVariables cannot hold strings; encode via a small lookup
      // is unnecessary complexity for a code meant only for logging, so
      // this one field is written to a plain text file in the EA's own
      // sandboxed Files folder instead of a GlobalVariable double. This
      // is diagnostic-only and is never read back to make a trading
      // decision - decisions are made from live broker state, not from
      // a remembered reason string.
      int h = FileOpen("FlashP3_RecoveryReason_" + symbol + "_" + IntegerToString((int)magic) + ".txt",
                        FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(h != INVALID_HANDLE)
      {
         FileWriteString(h, code);
         FileClose(h);
      }
   }

   //------------------------------------------------------------------
   // Phase 3 REC01 - conditional auto-recovery eligibility.
   //
   // Set ONLY at the one HandleSetupExit escalation site, ONLY when that
   // escalation was specifically caused by a retryable-in-nature outcome
   // (temporary market closure, connection uncertainty) exhausting its
   // bounded retry budget - never for a hard or ambiguous rejection.
   // TryAutoRecoverFromRoutineExit() is the only reader of this flag; it
   // is a no-op whenever this is false. Persisted as a GlobalVariable
   // (not an in-memory flag) so it survives a terminal/EA restart while
   // Flash is sitting in RECOVERY_REQUIRED - required for the restart-
   // during-recovery self-test, since a restart must not force a routine,
   // otherwise-resolvable episode back into permanent manual review just
   // because the process happened to restart.
   //------------------------------------------------------------------
   static void SetRoutineExitRecoveryEligible(const string symbol, const long magic, const bool eligible)
   {
      GlobalVariableSet(Key("ROUTINE_EXIT_RECOVERY_ELIGIBLE", symbol, magic), eligible ? 1.0 : 0.0);
   }

   static bool IsRoutineExitRecoveryEligible(const string symbol, const long magic)
   {
      string k = Key("ROUTINE_EXIT_RECOVERY_ELIGIBLE", symbol, magic);
      return GlobalVariableCheck(k) && GlobalVariableGet(k) != 0.0;
   }

   static void ClearRoutineExitRecoveryEligible(const string symbol, const long magic)
   {
      GlobalVariableDel(Key("ROUTINE_EXIT_RECOVERY_ELIGIBLE", symbol, magic));
   }

   //------------------------------------------------------------------
   // Pure functions - independently testable, no broker/global state.
   //------------------------------------------------------------------

   // Idempotency guard: a request should be skipped, not resent, if an
   // identical one is already outstanding and still within the
   // reasonable window for a broker response to arrive. This is what
   // makes "restart three times mid-request" not send three requests -
   // recovery re-reads this state before deciding to act again.
   static bool ShouldSkipDuplicateRequest(const ENUM_FLASH_INTENT_STATE state, const datetime requestedAt,
                                           const datetime now, const int reconciliationGraceSeconds)
   {
      if(state != FLASH_INTENT_CLOSE_REQUESTED && state != FLASH_INTENT_CANCEL_REQUESTED)
         return false; // nothing outstanding, no duplicate risk
      return (now - requestedAt) < reconciliationGraceSeconds;
   }

   // Given what was requested and what the broker actually shows now,
   // determine the outcome - never assumed from arithmetic alone
   // without the broker-confirmed remaining volume as input.
   static ENUM_FLASH_CLOSE_OUTCOME ResolveCloseOutcome(const double requestedVolume,
                                                        const double actualRemainingVolume,
                                                        const double volumeStep)
   {
      double tolerance = (volumeStep > 0.0) ? (volumeStep / 2.0) : 0.0000001;
      if(actualRemainingVolume <= tolerance)
         return FLASH_CLOSE_OUTCOME_FULLY_CLOSED;
      if(actualRemainingVolume >= requestedVolume - tolerance)
         return FLASH_CLOSE_OUTCOME_NOT_CLOSED;
      return FLASH_CLOSE_OUTCOME_PARTIALLY_CLOSED;
   }
};

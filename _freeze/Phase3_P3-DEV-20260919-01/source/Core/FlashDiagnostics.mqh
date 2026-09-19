//+------------------------------------------------------------------+
//| FlashDiagnostics.mqh                                             |
//| Phase 3 Stage 3.4 - Observability and Test Evidence               |
//|                                                                    |
//| Structured event helpers on top of the existing CFlashLogger, so  |
//| every important transition connects decision -> request -> broker |
//| response -> resulting account state, and so persistent failures   |
//| produce bounded, summarized log output rather than one line per   |
//| tick forever. Categories match Stage 3.4.2 exactly:                |
//| [FLASH][BUILD] [FLASH][OWNER] [FLASH][SETUP] [FLASH][ENTRY]       |
//| [FLASH][TRAIL] [FLASH][REVERSAL] [FLASH][EXIT] [FLASH][RECOVERY]  |
//| [FLASH][RECONCILE] [FLASH][SAFETY]                                 |
//| (Existing Phase 1/2 code already uses ORDERS/OWNERSHIP/TRAILING/  |
//| PERSISTENCE/etc as categories; this file does not rename those -  |
//| it is additive vocabulary for Phase 3's own new transitions, not  |
//| a retroactive rename of Phase 2 log lines, since renaming would   |
//| break every existing evidence extraction pattern in the freeze     |
//| archive's grep-based tooling.)                                     |
//+------------------------------------------------------------------+
#property strict
#include "FlashLogger.mqh"

class CFlashDiagnostics
{
public:
   //------------------------------------------------------------------
   // Intention-vs-confirmation pattern (Stage 3.4.3)
   //------------------------------------------------------------------
   static void LogActionRequested(const string category, const string action, const string setupId,
                                   const string buildId, const long magic)
   {
      CFlashLogger::Log(category, StringFormat("build=%s magic=%d setup=%s | %s requested", buildId, (int)magic, setupId, action));
   }

   static void LogBrokerResponse(const string category, const ulong ticket, const uint retcode, const string comment)
   {
      CFlashLogger::Log(category, StringFormat("Broker response; ticket=%I64u; retcode=%u; comment=%s", ticket, retcode, comment));
   }

   static void LogReconciledVolume(const string category, const double remainingVolume)
   {
      CFlashLogger::Log(category, StringFormat("Reconciled; remaining position volume=%s", DoubleToString(remainingVolume, 2)));
   }

   static void LogFinalConfirmation(const string category, const string setupId, const int positionCount, const int pendingCount)
   {
      // Emitted ONLY after checking actual broker state - callers must
      // not call this from a request-accepted callback alone.
      CFlashLogger::Log(category, StringFormat("Confirmed complete; setup=%s positions=%d related pending orders=%d", setupId, positionCount, pendingCount));
   }

   //------------------------------------------------------------------
   // Bounded/rate-limited logging for persistent failures (Stage 3.4.4).
   // Logs: the first occurrence, any materially different occurrence
   // (different retcode/outcome string), and then only every Nth
   // repeat of the SAME outcome after that - never one line per tick
   // for an unchanged condition, and never by sending another trade
   // request merely to generate a log line.
   //------------------------------------------------------------------
   static void LogRepeatedFailure(const string category, string &lastKey, int &repeatCount,
                                   const string key, const string message, const int aggregateEvery = 10)
   {
      if(key != lastKey)
      {
         lastKey = key;
         repeatCount = 1;
         CFlashLogger::Log(category, message);
         return;
      }
      repeatCount++;
      if(repeatCount == 2)
      {
         // Announce the transition into "this is now repeating" once,
         // distinctly from either the first line or a future aggregate.
         CFlashLogger::Log(category, "Repeating: " + message);
         return;
      }
      if(repeatCount % aggregateEvery == 0)
         CFlashLogger::Log(category, StringFormat("Still unresolved after %d occurrences: %s", repeatCount, message));
   }

   //------------------------------------------------------------------
   // Evidence export (Stage 3.4.6). Appends one CSV row per completed
   // or terminally-classified test to a stable-schema file in the EA's
   // own sandboxed Files folder (MQL5/Files/), which is the only
   // location EA code is permitted to write to - never the Logs folder
   // itself, consistent with the standing project rule that EA code
   // must never attempt to touch the terminal's own log files.
   //------------------------------------------------------------------
   static void ExportTestEvidenceRow(const string testName, const string buildId, const datetime startTime,
                                      const datetime endTime, const string accountMode, const string symbol,
                                      const string inputsSummary, const string ticketsSummary,
                                      const string expectedOutcome, const string observedOutcome,
                                      const string result, const string unresolvedReason)
   {
      string filename = "FlashPhase3_TestEvidence.csv";
      bool exists = FileIsExist(filename);
      int h = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
      if(h == INVALID_HANDLE)
      {
         CFlashLogger::Error("RECONCILE", "Could not open " + filename + " for evidence export.");
         return;
      }
      if(!exists)
      {
         FileSeek(h, 0, SEEK_END);
         FileWrite(h, "TestName", "BuildId", "StartTime", "EndTime", "AccountMode", "Symbol",
                    "InputsSummary", "TicketsSummary", "ExpectedOutcome", "ObservedOutcome", "Result", "UnresolvedReason");
      }
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, testName, buildId, TimeToString(startTime, TIME_DATE | TIME_SECONDS),
                 TimeToString(endTime, TIME_DATE | TIME_SECONDS), accountMode, symbol,
                 inputsSummary, ticketsSummary, expectedOutcome, observedOutcome, result, unresolvedReason);
      FileClose(h);
      CFlashLogger::Log("RECONCILE", StringFormat("Evidence row appended to %s | test=%s result=%s", filename, testName, result));
   }
};

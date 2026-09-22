//+------------------------------------------------------------------+
//| FlashMarketWait.mqh                                              |
//| Phase 3 REC02 - Market-Closed Awareness And No-Spam Recovery     |
//|                                                                    |
//| A broker-confirmed market-closed rejection (or any rejection that |
//| classifies as FLASH_EXEC_TEMP_MARKET_CLOSED) must never be        |
//| resubmitted on every tick. This module separates CHECKING whether |
//| a retry is due from SUBMITTING the retry: callers ask IsBlocked() |
//| before attempting a broker request at all, and only call          |
//| RecordMarketClosed() after an actual rejection to arm/extend the  |
//| next allowed probe time. Nothing here submits an order itself -   |
//| it is a read-only gate plus persisted bookkeeping.                |
//|                                                                    |
//| All fields are GlobalVariable-persisted, scoped per symbol+magic, |
//| so the waiting condition survives ticks, timer events, trade      |
//| transactions, EA reattachment, and terminal restart exactly like  |
//| CFlashIntent's close-intent fields do.                             |
//|                                                                    |
//| A published trading-session schedule (SymbolInfoSessionTrade) is  |
//| used only as a TIMING signal to decide when a retry becomes       |
//| worth attempting - never as proof the broker will accept it. The  |
//| session-derived candidate is only ever allowed to push the next   |
//| probe LATER than the bounded fallback ladder already would, never |
//| earlier - so a symbol whose schedule confirms it is still closed  |
//| for hours does not get probed every few minutes for no reason,    |
//| but a schedule saying "open" is never trusted to skip the bounded |
//| ladder floor.                                                      |
//+------------------------------------------------------------------+
#property strict
#include "FlashLogger.mqh"

#define FLASH_MKTWAIT_MAX_SESSION_PUSH_SECONDS (8 * 86400) // 8-day bounded lookahead, matches NextKnownSessionOpen's own cap

// Bounded fallback probe ladder - pure and independently testable.
// probeCount is the number of probes already made (0 before the first).
// Returns the delay, in seconds, before the NEXT probe becomes due.
// Across a two-hour closed window this yields roughly 14 probes total
// (60 + 120 + 300 seconds, then ~600-second steps for the remainder),
// versus the ~650 recovery-cycle / ~1,900 rejected-request behavior this
// module replaces.
int FlashMarketWaitFallbackDelaySeconds(const int probeCount)
{
   if(probeCount <= 0) return 60;
   if(probeCount == 1) return 120;
   if(probeCount == 2) return 300;
   return 600; // capped
}

class CFlashMarketWait
{
private:
   static string KeyActive(const string symbol, const long magic)   { return StringFormat("FLASH_P3_MKTWAIT_ACTIVE_%s_%d", symbol, (int)magic); }
   static string KeyNextProbe(const string symbol, const long magic){ return StringFormat("FLASH_P3_MKTWAIT_NEXT_PROBE_AT_%s_%d", symbol, (int)magic); }
   static string KeyProbeCount(const string symbol, const long magic){ return StringFormat("FLASH_P3_MKTWAIT_PROBE_COUNT_%s_%d", symbol, (int)magic); }
   static string KeyFirstDetected(const string symbol, const long magic){ return StringFormat("FLASH_P3_MKTWAIT_FIRST_DETECTED_AT_%s_%d", symbol, (int)magic); }
   static string KeyOrigin(const string symbol, const long magic){ return StringFormat("FLASH_P3_MKTWAIT_ORIGIN_%s_%d", symbol, (int)magic); }

   // Session-derived candidate is capped at this many seconds ahead so a
   // misread or missing session table can never silently strand the EA for
   // an unbounded time - it can only ever push a probe out to at most this
   // far, never further, regardless of what SymbolInfoSessionTrade reports.
   // (A #define rather than an in-class static const initializer - MQL5
   // does not support inline initialization of a static class member.)

public:
   static bool IsActive(const string symbol, const long magic)
   {
      string key = KeyActive(symbol, magic);
      if(!GlobalVariableCheck(key)) return false;
      return GlobalVariableGet(key) != 0.0;
   }

   static datetime NextProbeAt(const string symbol, const long magic)
   {
      string key = KeyNextProbe(symbol, magic);
      if(!GlobalVariableCheck(key)) return 0;
      return (datetime)GlobalVariableGet(key);
   }

   static int ProbeCount(const string symbol, const long magic)
   {
      string key = KeyProbeCount(symbol, magic);
      if(!GlobalVariableCheck(key)) return 0;
      return (int)GlobalVariableGet(key);
   }

   static datetime FirstDetectedAt(const string symbol, const long magic)
   {
      string key = KeyFirstDetected(symbol, magic);
      if(!GlobalVariableCheck(key)) return 0;
      return (datetime)GlobalVariableGet(key);
   }

   // Origin identifies which call path armed the current wait, so
   // HandleWaitingForMarket() knows which state to resume into once a
   // retry is due: 1 = HandleSetupExit's outstanding close, 2 =
   // ReconcileReversal's old-direction-exposure close. 0 = unknown/none.
   static int Origin(const string symbol, const long magic)
   {
      string key = KeyOrigin(symbol, magic);
      if(!GlobalVariableCheck(key)) return 0;
      return (int)GlobalVariableGet(key);
   }

   // True when a market-closed wait is active AND the next permitted probe
   // has not yet arrived - callers must skip submitting the broker request
   // entirely while this is true, exactly as they would check an ordinary
   // retry-budget WAIT decision.
   static bool IsBlocked(const string symbol, const long magic, const datetime now)
   {
      if(!IsActive(symbol, magic)) return false;
      return now < NextProbeAt(symbol, magic);
   }

   // Pure decision helper - given the current probe count and the two
   // candidate next-probe times, returns which one to use. Exposed
   // separately from RecordMarketClosed so the self-test suite can drive
   // it with synthetic inputs without touching GlobalVariables at all.
   static datetime ChooseNextProbeAt(const datetime now, const int probeCountBeforeThisProbe,
                                      const datetime sessionCandidate)
   {
      datetime fallbackCandidate = now + FlashMarketWaitFallbackDelaySeconds(probeCountBeforeThisProbe);
      datetime cappedSession = 0;
      if(sessionCandidate > now)
      {
         datetime cap = now + FLASH_MKTWAIT_MAX_SESSION_PUSH_SECONDS;
         cappedSession = (sessionCandidate > cap) ? cap : sessionCandidate;
      }
      // The schedule may only push the next probe LATER than the bounded
      // fallback floor - never sooner. A schedule that says "open already"
      // (sessionCandidate <= now) is not trusted to bypass the ladder.
      return (cappedSession > fallbackCandidate) ? cappedSession : fallbackCandidate;
   }

   // Called immediately after a broker-confirmed market-closed rejection.
   // Arms the waiting state if not already active (recording FirstDetectedAt
   // once, never overwritten while still active - this is what keeps the
   // outstanding condition identifiable as ONE episode rather than a fresh
   // one every tick), then advances the probe count and computes the next
   // permitted probe time.
   static void RecordMarketClosed(const string symbol, const long magic, const datetime now, const string context, const int origin = 0)
   {
      bool wasActive = IsActive(symbol, magic);
      int probeCountBefore = wasActive ? ProbeCount(symbol, magic) : 0;

      if(!wasActive)
      {
         GlobalVariableSet(KeyFirstDetected(symbol, magic), (double)now);
         CFlashLogger::Log("MKTWAIT", StringFormat("Market-closed wait ENTERED for %s magic=%d (%s)", symbol, (int)magic, context));
      }

      GlobalVariableSet(KeyActive(symbol, magic), 1.0);
      if(origin != 0)
         GlobalVariableSet(KeyOrigin(symbol, magic), (double)origin);

      datetime sessionCandidate = NextKnownSessionOpen(symbol, now);
      datetime nextProbe = ChooseNextProbeAt(now, probeCountBefore, sessionCandidate);

      GlobalVariableSet(KeyProbeCount(symbol, magic), (double)(probeCountBefore + 1));
      GlobalVariableSet(KeyNextProbe(symbol, magic), (double)nextProbe);

      CFlashLogger::Log("MKTWAIT",
         StringFormat("Market-closed rejection recorded for %s magic=%d (%s) | probeCount=%d | nextProbeAt=%s | sessionCandidate=%s",
                       symbol, (int)magic, context, probeCountBefore + 1,
                       TimeToString(nextProbe, TIME_DATE | TIME_SECONDS),
                       sessionCandidate > 0 ? TimeToString(sessionCandidate, TIME_DATE | TIME_SECONDS) : "unavailable"));
   }

   // Clears the waiting state entirely - only ever called after
   // reconciliation confirms the underlying condition is actually
   // resolved (either the outstanding exit succeeded, or the position
   // closed on its own and was fully reconciled). Never cleared merely
   // because a probe was attempted.
   static void Clear(const string symbol, const long magic)
   {
      if(!IsActive(symbol, magic)) return;
      GlobalVariableSet(KeyActive(symbol, magic), 0.0);
      GlobalVariableDel(KeyNextProbe(symbol, magic));
      GlobalVariableDel(KeyProbeCount(symbol, magic));
      GlobalVariableDel(KeyFirstDetected(symbol, magic));
      GlobalVariableDel(KeyOrigin(symbol, magic));
      CFlashLogger::Log("MKTWAIT", StringFormat("Market-closed wait CLEARED for %s magic=%d", symbol, (int)magic));
   }

   // Read-only session-schedule lookahead. Walks forward from `from`, day
   // by day, up to an 8-day bound, reading each day's published trading
   // sessions for `symbol` via SymbolInfoSessionTrade and returning the
   // earliest absolute datetime at or after `from` that falls inside a
   // published session window. Returns 0 if the symbol exposes no session
   // data at all within the lookahead window (unsupported/unavailable),
   // so callers must treat 0 as "no schedule signal" and fall back to the
   // bounded ladder alone - this function never submits anything and never
   // itself asserts trading is actually possible, only that a schedule
   // exists saying so.
   static datetime NextKnownSessionOpen(const string symbol, const datetime from)
   {
      for(int dayOffset = 0; dayOffset <= 8; dayOffset++)
      {
         datetime probeDay = from + dayOffset * 86400;
         MqlDateTime dt;
         TimeToStruct(probeDay, dt);
         dt.hour = 0; dt.min = 0; dt.sec = 0;
         datetime dayStart = StructToTime(dt);
         ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dt.day_of_week;

         for(int sessionIndex = 0; sessionIndex < 8; sessionIndex++)
         {
            datetime sessFrom = 0, sessTo = 0;
            if(!SymbolInfoSessionTrade(symbol, dow, sessionIndex, sessFrom, sessTo))
               break; // no more sessions defined for this day

            // sessFrom/sessTo are seconds-since-midnight for that weekday,
            // not absolute epoch values - anchor them onto this day's date.
            datetime absFrom = (datetime)((long)dayStart + (long)sessFrom);
            datetime absTo   = (datetime)((long)dayStart + (long)sessTo);

            if(absTo <= from) continue;          // this window already fully elapsed
            if(absFrom >= from) return absFrom;   // next window starts at or after 'from'
            return from;                          // 'from' already falls inside this window
         }
      }
      return 0; // no session data found within the bounded lookahead
   }
};

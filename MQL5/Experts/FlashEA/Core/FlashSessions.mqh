//+------------------------------------------------------------------+
//| FlashSessions.mqh                                                |
//| Phase 2 Stage 2.4 - Kenya-Time (EAT, UTC+3) Session Engine        |
//|                                                                    |
//| MT5 has no reliable built-in API to read a broker's server-time   |
//| UTC offset, especially inside Strategy Tester where TimeGMT() is  |
//| driven by the local machine clock, not simulated time. Flash      |
//| therefore takes the broker's UTC offset as an explicit input      |
//| (BrokerServerUTCOffsetHours) rather than guessing it - this must  |
//| be set and re-checked by the user against the broker's own        |
//| documented time zone, including around DST changes.                |
//|                                                                    |
//| The session filter controls PERMISSION TO CREATE NEW EXPOSURE     |
//| only (new initial setups and new reversal orders). It never        |
//| liquidates an existing position when a session ends.               |
//+------------------------------------------------------------------+
#property strict
#include "FlashLogger.mqh"

struct SFlashSessionWindow
{
   bool enabled;
   int  startMinutes;  // minutes since Kenya midnight, inclusive
   int  endMinutes;    // minutes since Kenya midnight, exclusive
};

// Minimal flattened view of the session-related config fields, avoiding a
// hard dependency on the full SFlashConfig struct's include order.
struct SFlashConfigSessionsView
{
   bool   filterEnabled;
   bool   earlyEnabled;   int earlyStart;   int earlyEnd;
   bool   middayEnabled;  int middayStart;  int middayEnd;
   bool   eveningEnabled; int eveningStart; int eveningEnd;
   double brokerOffsetHours;
};

class CFlashSessions
{
public:
   //------------------------------------------------------------------
   // Pure functions - exercised directly by the self-test suite.
   //------------------------------------------------------------------

   // Parses a plain "HH:MM" input string into minutes-of-day. Returns -1
   // on any malformed input so the caller can fail validation loudly
   // rather than silently defaulting to midnight.
   static int ParseHHMM(const string hhmm)
   {
      string parts[];
      int n = StringSplit(hhmm, ':', parts);
      if(n != 2) return -1;
      if(StringLen(parts[0]) == 0 || StringLen(parts[1]) == 0) return -1;
      int hour = (int)StringToInteger(parts[0]);
      int minute = (int)StringToInteger(parts[1]);
      if(hour < 0 || hour > 23) return -1;
      if(minute < 0 || minute > 59) return -1;
      return hour * 60 + minute;
   }

   static int MinutesOfDay(const int hour, const int minute)
   {
      return hour * 60 + minute;
   }

   // Start inclusive, end exclusive.
   static bool InWindow(const int nowMinutes, const SFlashSessionWindow &w)
   {
      if(!w.enabled) return false;
      return (nowMinutes >= w.startMinutes && nowMinutes < w.endMinutes);
   }

   // Disabled session filter switch never blocks entries.
   static bool NewEntryPermitted(const bool sessionFilterEnabled, const int nowMinutesKenya,
                                  const SFlashSessionWindow &early, const SFlashSessionWindow &midday,
                                  const SFlashSessionWindow &evening)
   {
      if(!sessionFilterEnabled) return true;
      return InWindow(nowMinutesKenya, early) || InWindow(nowMinutesKenya, midday) || InWindow(nowMinutesKenya, evening);
   }

   // brokerTime is the platform's TimeCurrent()/TimeTradeServer() value.
   // brokerToUtcOffsetSeconds = broker server time minus UTC, in seconds
   // (e.g. a broker running UTC+2 passes 7200). Kenya is fixed UTC+3.
   static datetime BrokerTimeToKenya(const datetime brokerTime, const int brokerToUtcOffsetSeconds)
   {
      return brokerTime - brokerToUtcOffsetSeconds + 3 * 3600;
   }

   static int MinutesOfDayFromDatetime(const datetime t)
   {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      return dt.hour * 60 + dt.min;
   }

   // Kenya calendar-day start (00:00:00 EAT), expressed back in broker
   // server time, for daily-ledger boundary computation.
   static datetime KenyaDayStartInBrokerTime(const datetime brokerNow, const int brokerToUtcOffsetSeconds)
   {
      datetime kenyaNow = BrokerTimeToKenya(brokerNow, brokerToUtcOffsetSeconds);
      MqlDateTime dt;
      TimeToStruct(kenyaNow, dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime kenyaMidnight = StructToTime(dt);
      return kenyaMidnight + brokerToUtcOffsetSeconds - 3 * 3600;
   }

   //------------------------------------------------------------------
   // Live wrapper
   //------------------------------------------------------------------

   static bool NewEntryPermittedNow(const SFlashConfigSessionsView &cfg)
   {
      int offsetSeconds = (int)MathRound(cfg.brokerOffsetHours * 3600.0);
      datetime kenyaNow = BrokerTimeToKenya(TimeCurrent(), offsetSeconds);
      int nowMinutes = MinutesOfDayFromDatetime(kenyaNow);

      SFlashSessionWindow early;   early.enabled = cfg.earlyEnabled;   early.startMinutes = cfg.earlyStart;   early.endMinutes = cfg.earlyEnd;
      SFlashSessionWindow midday;  midday.enabled = cfg.middayEnabled; midday.startMinutes = cfg.middayStart; midday.endMinutes = cfg.middayEnd;
      SFlashSessionWindow evening; evening.enabled = cfg.eveningEnabled; evening.startMinutes = cfg.eveningStart; evening.endMinutes = cfg.eveningEnd;

      bool permitted = NewEntryPermitted(cfg.filterEnabled, nowMinutes, early, midday, evening);

      if(!permitted && cfg.filterEnabled)
         CFlashLogger::Debug("SESSIONS",
            StringFormat("New exposure blocked outside enabled Kenya-time session windows (Kenya time-of-day minutes=%d)", nowMinutes));

      return permitted;
   }
};


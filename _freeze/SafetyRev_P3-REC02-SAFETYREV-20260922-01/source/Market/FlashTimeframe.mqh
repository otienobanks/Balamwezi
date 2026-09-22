//+------------------------------------------------------------------+
//| FlashTimeframe.mqh                                               |
//| Phase 1 - Universal timeframe detection                          |
//|                                                                    |
//| The EA's working timeframe has exactly one source of truth: the   |
//| chart it is attached to. Every later module (Stage 1.3 entry      |
//| calc, Stage 1.4 refresh timing) reads timeframe state through     |
//| this class rather than re-reading _Period itself, so there is     |
//| only ever one place the "which timeframe am I on" decision is     |
//| made. There is deliberately no separate Trading Timeframe input.  |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"

class CFlashTimeframe
{
private:
   string           m_symbol;
   ENUM_TIMEFRAMES  m_timeframe;
   datetime         m_lastSeenBarTime;
   datetime         m_lastRefreshedBarTime;   // last bar time an initial-order refresh was performed for

public:
   void Init(const string symbol)
   {
      m_symbol = symbol;
      m_timeframe = (ENUM_TIMEFRAMES)_Period;      // single source of truth: the attached chart
      m_lastSeenBarTime = 0;
      m_lastRefreshedBarTime = 0;
   }

   ENUM_TIMEFRAMES Timeframe() const { return m_timeframe; }

   string TimeframeCode() const
   {
      switch(m_timeframe)
      {
         case PERIOD_M1:  return "M1";
         case PERIOD_M5:  return "M5";
         case PERIOD_M15: return "M15";
         case PERIOD_M30: return "M30";
         case PERIOD_H1:  return "H1";
         case PERIOD_H4:  return "H4";
         case PERIOD_D1:  return "D1";
         default:         return EnumToString(m_timeframe);
      }
   }

   // Returns true exactly once per new completed candle boundary on the
   // working timeframe. Uses the real current bar's open time (iTime),
   // never wall-clock time, so this stays correct across restarts.
   bool IsNewBar()
   {
      datetime currentBarTime = iTime(m_symbol, m_timeframe, 0);
      if(currentBarTime == 0)
         return false; // no bar data yet

      if(currentBarTime != m_lastSeenBarTime)
      {
         m_lastSeenBarTime = currentBarTime;
         return true;
      }
      return false;
   }

   datetime LastSeenBarTime() const { return m_lastSeenBarTime; }

   // Initial-order refresh must happen at most once per new candle. This
   // reports whether a refresh is still owed for the current bar, and
   // MarkRefreshed() must be called once the refresh actually completes -
   // never called speculatively before the refresh is confirmed done.
   bool RefreshOwedForCurrentBar() const
   {
      return (m_lastSeenBarTime != 0 && m_lastSeenBarTime != m_lastRefreshedBarTime);
   }

   void MarkRefreshed()
   {
      m_lastRefreshedBarTime = m_lastSeenBarTime;
   }

   // Most recently completed candle's high/low on the working timeframe.
   // Index 1 = last fully closed bar (index 0 is the forming bar). Returns
   // false if that bar's data is not available (e.g. insufficient history),
   // in which case out values are left untouched and callers must not trade
   // on zeroes or stale values.
   bool GetPreviousCompletedCandle(double &outHigh, double &outLow) const
   {
      if(Bars(m_symbol, m_timeframe) < 2)
         return false;

      double high = iHigh(m_symbol, m_timeframe, 1);
      double low  = iLow(m_symbol, m_timeframe, 1);

      if(high <= 0.0 || low <= 0.0 || high < low)
         return false;

      outHigh = high;
      outLow  = low;
      return true;
   }

   void LogSnapshot() const
   {
      CFlashLogger::Log("MARKET",
         StringFormat("Attached timeframe = %s (code=%s)", EnumToString(m_timeframe), TimeframeCode()));
   }
};

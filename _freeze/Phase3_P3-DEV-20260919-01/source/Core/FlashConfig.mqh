//+------------------------------------------------------------------+
//| FlashConfig.mqh                                                  |
//| Phase 1 Stage 1.1 core + Phase 2 input groups                    |
//|                                                                    |
//| Phase 2 adds trailing, sizing, setup profit target, daily limits, |
//| and Kenya-time session inputs. All Phase 2 defaults are initial  |
//| engineering settings for testing, not optimized or                |
//| guaranteed-profitable parameters.                                  |
//+------------------------------------------------------------------+
#property strict

enum ENUM_FLASH_ENTRY_METHOD
{
   FLASH_ENTRY_FIXED_PRICE_DISTANCE = 0,   // Fixed Price Distance
   FLASH_ENTRY_PREVIOUS_CANDLE      = 1    // Previous Candle
};

enum ENUM_FLASH_SIZING_METHOD
{
   FLASH_SIZING_FIXED_LOT       = 0,   // Fixed Lot Size
   FLASH_SIZING_PERCENT_EQUITY  = 1    // Percentage of Equity
};

struct SFlashConfig
{
   // Phase 1
   ENUM_FLASH_ENTRY_METHOD EntryMethod;
   double EntryDistancePrice;           // "Entry Distance (Gold Price)"
   double PreviousCandleEntryBuffer;    // "Previous Candle Entry Buffer"
   double LotSizePerPosition;           // "Lot Size Per Position"
   int    PositionsPerSetup;            // "Number of Positions Per Setup"
   double MaximumAllowedSpread;         // "Maximum Allowed Spread (Gold Price)"
   long   FlashMagicNumber;             // "Flash Trade Identification Number"
   bool   EnableDetailedLogging;        // "Enable Detailed Logging"

   // Phase 2 - Trailing
   double TrailingActivationDistance;   // "Trailing Activation Distance (Gold Price)"
   double TrailingStopDistance;         // "Trailing Stop Distance (Gold Price)"
   double MinimumTrailingUpdate;        // "Minimum Trailing Update (Gold Price)"

   // Phase 2 - Position Sizing
   ENUM_FLASH_SIZING_METHOD SizingMethod; // "Position Sizing Method"
   double EquityRiskPercentPerSetup;      // "Equity Risk Per Setup (%)"

   // Phase 2 - Setup Profit Target
   bool   EnableSetupProfitTarget;      // "Enable Setup Profit Target"
   double SetupProfitTarget;            // "Setup Profit Target (Account Currency)"

   // Phase 2 - Daily Limits
   bool   EnableDailyProfitLimit;       // "Enable Daily Profit Limit"
   double DailyProfitLimit;             // "Daily Profit Limit (Account Currency)"
   bool   EnableDailyLossLimit;         // "Enable Daily Loss Limit"
   double DailyLossLimit;               // "Daily Loss Limit (Account Currency)"

   // Phase 2 - Kenya-Time Sessions
   bool   EnableTradingSessions;        // "Enable Trading Sessions"
   bool   EnableEarlySession;           // "Enable Early Session"
   int    EarlySessionStartMinutes;     // "Early Session Start (Kenya Time)" as minutes-of-day
   int    EarlySessionEndMinutes;       // "Early Session End (Kenya Time)" as minutes-of-day
   bool   EnableMiddaySession;          // "Enable Midday Session"
   int    MiddaySessionStartMinutes;
   int    MiddaySessionEndMinutes;
   bool   EnableEveningSession;         // "Enable Evening Session"
   int    EveningSessionStartMinutes;
   int    EveningSessionEndMinutes;
   double BrokerServerUTCOffsetHours;   // "Broker Server Time Offset From UTC (Hours)"
};

class CFlashConfig
{
public:
   static bool Validate(const SFlashConfig &cfg)
   {
      bool ok = true;

      if(cfg.EntryMethod == FLASH_ENTRY_FIXED_PRICE_DISTANCE && cfg.EntryDistancePrice <= 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Entry Distance (Gold Price) must be greater than zero when Entry Method is Fixed Price Distance");
         ok = false;
      }
      if(cfg.PreviousCandleEntryBuffer < 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Previous Candle Entry Buffer cannot be negative");
         ok = false;
      }
      if(cfg.LotSizePerPosition <= 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Lot Size Per Position must be greater than zero");
         ok = false;
      }
      if(cfg.PositionsPerSetup < 1)
      {
         Print("[FLASH][CONFIG][ERROR] Number of Positions Per Setup must be at least 1");
         ok = false;
      }
      if(cfg.MaximumAllowedSpread < 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Maximum Allowed Spread (Gold Price) cannot be negative");
         ok = false;
      }
      if(cfg.FlashMagicNumber <= 0)
      {
         Print("[FLASH][CONFIG][ERROR] Flash Trade Identification Number must be greater than zero");
         ok = false;
      }

      if(cfg.TrailingActivationDistance <= 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Trailing Activation Distance (Gold Price) must be greater than zero");
         ok = false;
      }
      if(cfg.TrailingStopDistance <= 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Trailing Stop Distance (Gold Price) must be greater than zero");
         ok = false;
      }
      if(cfg.MinimumTrailingUpdate < 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Minimum Trailing Update (Gold Price) cannot be negative");
         ok = false;
      }

      if(cfg.SizingMethod == FLASH_SIZING_PERCENT_EQUITY && cfg.EquityRiskPercentPerSetup <= 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Equity Risk Per Setup (%) must be greater than zero when Position Sizing Method is Percentage of Equity");
         ok = false;
      }

      if(cfg.EnableSetupProfitTarget && cfg.SetupProfitTarget <= 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Setup Profit Target (Account Currency) must be greater than zero when enabled");
         ok = false;
      }

      if(cfg.EnableDailyProfitLimit && cfg.DailyProfitLimit <= 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Daily Profit Limit (Account Currency) must be greater than zero when enabled");
         ok = false;
      }
      if(cfg.EnableDailyLossLimit && cfg.DailyLossLimit <= 0.0)
      {
         Print("[FLASH][CONFIG][ERROR] Daily Loss Limit (Account Currency) must be greater than zero when enabled");
         ok = false;
      }

      if(cfg.EnableTradingSessions)
      {
         if(!cfg.EnableEarlySession && !cfg.EnableMiddaySession && !cfg.EnableEveningSession)
         {
            Print("[FLASH][CONFIG][ERROR] Enable Trading Sessions is true but no individual session is enabled");
            ok = false;
         }
         if(cfg.EnableEarlySession && !ValidateWindow(cfg.EarlySessionStartMinutes, cfg.EarlySessionEndMinutes, "Early Session"))
            ok = false;
         if(cfg.EnableMiddaySession && !ValidateWindow(cfg.MiddaySessionStartMinutes, cfg.MiddaySessionEndMinutes, "Midday Session"))
            ok = false;
         if(cfg.EnableEveningSession && !ValidateWindow(cfg.EveningSessionStartMinutes, cfg.EveningSessionEndMinutes, "Evening Session"))
            ok = false;
      }

      return ok;
   }

   static bool ValidateWindow(const int startMinutes, const int endMinutes, const string label)
   {
      bool ok = true;
      if(startMinutes < 0 || startMinutes >= 1440)
      {
         PrintFormat("[FLASH][CONFIG][ERROR] %s start must be a valid time of day", label);
         ok = false;
      }
      if(endMinutes < 0 || endMinutes >= 1440 + 1) // end may equal 1440 only via 24:00 - not used here, keep <1440
      {
         PrintFormat("[FLASH][CONFIG][ERROR] %s end must be a valid time of day", label);
         ok = false;
      }
      if(startMinutes >= endMinutes)
      {
         PrintFormat("[FLASH][CONFIG][ERROR] %s start must be before its end", label);
         ok = false;
      }
      return ok;
   }

   static string EntryMethodToString(const ENUM_FLASH_ENTRY_METHOD method)
   {
      return (method == FLASH_ENTRY_FIXED_PRICE_DISTANCE) ? "Fixed Price Distance" : "Previous Candle";
   }

   static string SizingMethodToString(const ENUM_FLASH_SIZING_METHOD method)
   {
      return (method == FLASH_SIZING_FIXED_LOT) ? "Fixed Lot Size" : "Percentage of Equity";
   }
};

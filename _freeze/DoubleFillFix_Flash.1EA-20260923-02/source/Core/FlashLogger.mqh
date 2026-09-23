//+------------------------------------------------------------------+
//| FlashLogger.mqh                                                  |
//| Phase 1, Stage 1.1 - Shared, phase-tagged logging                |
//|                                                                    |
//| Every log line in the EA goes through this formatter so the      |
//| Journal can be reliably filtered by phase/subsystem and so a     |
//| human reading the Journal can place any line in the architecture |
//| without opening source. Stage 1.1 owns this file; later stages   |
//| call CFlashLogger::Log(...), they do not print raw strings.      |
//+------------------------------------------------------------------+
#property strict

class CFlashLogger
{
private:
   static bool m_detailedLogging;

public:
   static void Init(bool detailedLogging)
   {
      m_detailedLogging = detailedLogging;
   }

   // General-purpose tagged line. tag examples: "INIT", "STATE", "MARKET",
   // "ORDERS", "RECOVERY", "SELFTEST".
   static void Log(const string tag, const string message)
   {
      PrintFormat("[FLASH][%s] %s", tag, message);
   }

   // Detailed/diagnostic line, suppressed unless EnableDetailedLogging=true.
   static void Debug(const string tag, const string message)
   {
      if(m_detailedLogging)
         PrintFormat("[FLASH][%s][DEBUG] %s", tag, message);
   }

   static void Error(const string tag, const string message)
   {
      PrintFormat("[FLASH][%s][ERROR] %s", tag, message);
   }

   static void StateTransition(const string fromState, const string toState, const string reason)
   {
      PrintFormat("[FLASH][STATE] %s -> %s | reason=%s", fromState, toState, reason);
   }
};

bool CFlashLogger::m_detailedLogging = true;

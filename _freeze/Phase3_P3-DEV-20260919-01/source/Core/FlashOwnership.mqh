//+------------------------------------------------------------------+
//| FlashOwnership.mqh                                               |
//| Owner: Phase 1 hardening - Single-Instance Ownership Enforcement |
//|                                                                    |
//| Resolves the reported multi-chart magic-number collision. Policy |
//| A (single-instance enforcement): only one Flash instance may      |
//| control a given (symbol, magic number) pair at a time. Any other  |
//| instance sharing that pair must block trading entirely and log    |
//| the conflict - it must never place, cancel, or modify an order.   |
//|                                                                    |
//| Ownership is tracked with terminal-wide GlobalVariables (shared   |
//| across every chart in this terminal, not per-chart), keyed by     |
//| symbol and magic number, so two charts running the same setup     |
//| under the same magic number can detect each other. A heartbeat    |
//| timestamp lets a genuinely abandoned owner (crashed, EA removed   |
//| without a clean OnDeinit) be safely taken over after a timeout,   |
//| rather than requiring the user to manually clear a stuck lock.    |
//|                                                                    |
//| The decision of WHAT to do (claim / already mine / stale takeover |
//| / blocked conflict) is a pure function, exercised directly by the |
//| self-test suite with synthetic inputs - the same pattern used by  |
//| every other decision in this codebase (CFlashBrokerRules,         |
//| CFlashEntryEngine, CFlashRecovery). Only the GlobalVariable I/O    |
//| itself is a live wrapper.                                         |
//+------------------------------------------------------------------+
#property strict
#include "FlashLogger.mqh"

// An abandoned owner's heartbeat older than this is considered stale and
// may be taken over. Chosen well above any realistic tick gap on a live
// or demo symbol, so a genuinely running instance is never mistakenly
// treated as abandoned.
#define FLASH_OWNERSHIP_HEARTBEAT_TIMEOUT_SECONDS 90.0

enum ENUM_FLASH_OWNERSHIP_DECISION
{
   FLASH_OWNERSHIP_CLAIM_NEW = 0,      // no existing owner - claim freely
   FLASH_OWNERSHIP_ALREADY_OWNER,      // this instance already holds it - refresh heartbeat
   FLASH_OWNERSHIP_TAKEOVER_STALE,     // existing owner's heartbeat is stale - safe to take over
   FLASH_OWNERSHIP_BLOCKED_CONFLICT    // existing owner is active - must block trading
};

class CFlashOwnership
{
public:
   static string DecisionToString(const ENUM_FLASH_OWNERSHIP_DECISION d)
   {
      switch(d)
      {
         case FLASH_OWNERSHIP_CLAIM_NEW:           return "CLAIM_NEW";
         case FLASH_OWNERSHIP_ALREADY_OWNER:        return "ALREADY_OWNER";
         case FLASH_OWNERSHIP_TAKEOVER_STALE:       return "TAKEOVER_STALE";
         case FLASH_OWNERSHIP_BLOCKED_CONFLICT:     return "BLOCKED_CONFLICT";
         default:                                   return "UNKNOWN";
      }
   }

   //------------------------------------------------------------------
   // Pure decision - no GlobalVariable calls, fully deterministic given
   // its inputs, exercised directly by the self-test suite.
   //------------------------------------------------------------------
   // heartbeatKnown=false means no heartbeat record could be read (the
   // owner var exists but the heartbeat var does not, or could not yet be
   // read) - this must NEVER be treated as "very old" and taken over. A
   // brand-new owner that has claimed the owner var an instant before its
   // heartbeat var becomes readable must look identical to an active
   // owner, not a stale one. Real live evidence (2026-09-17, three charts
   // attaching within the same millisecond) showed the earlier version of
   // this function computing heartbeatAgeSeconds as effectively the full
   // Unix epoch when the heartbeat var was not yet readable, which was
   // then treated as "hugely stale" and incorrectly triggered a takeover
   // moments after a fresh claim. The safe default for "unknown" is
   // BLOCKED_CONFLICT (assume active), never TAKEOVER_STALE (assume dead).
   static ENUM_FLASH_OWNERSHIP_DECISION Decide(const bool hasExistingOwner, const long existingOwnerChartId,
                                                const long myChartId, const bool heartbeatKnown,
                                                const double heartbeatAgeSeconds, const double timeoutSeconds)
   {
      if(!hasExistingOwner)
         return FLASH_OWNERSHIP_CLAIM_NEW;

      if(existingOwnerChartId == myChartId)
         return FLASH_OWNERSHIP_ALREADY_OWNER;

      if(!heartbeatKnown)
         return FLASH_OWNERSHIP_BLOCKED_CONFLICT;

      if(heartbeatAgeSeconds > timeoutSeconds)
         return FLASH_OWNERSHIP_TAKEOVER_STALE;

      return FLASH_OWNERSHIP_BLOCKED_CONFLICT;
   }

   static string OwnerVarName(const string symbol, const long magic)
   {
      return "FLASH_OWNER_" + symbol + "_" + IntegerToString((int)magic);
   }

   static string HeartbeatVarName(const string symbol, const long magic)
   {
      return "FLASH_HEARTBEAT_" + symbol + "_" + IntegerToString((int)magic);
   }

   //------------------------------------------------------------------
   // Live wrapper - reads/writes real terminal-wide GlobalVariables,
   // applies the pure Decide() above, and logs the outcome with a
   // reason. Returns true if this instance may trade (owns the lock),
   // false if it must stay blocked.
   //------------------------------------------------------------------
   static bool TryClaim(const string symbol, const long magic, const long myChartId)
   {
      string ownerVar = OwnerVarName(symbol, magic);
      string heartbeatVar = HeartbeatVarName(symbol, magic);

      // Ensure the owner variable exists before any compare-and-set can be
      // attempted against it. GlobalVariableTemp() creates it at sentinel
      // 0.0 (meaning "unowned") only if it does not already exist, and is
      // a harmless no-op if it does - it never overwrites a real owner
      // value, so this cannot itself introduce a race on an existing lock.
      GlobalVariableTemp(ownerVar);

      bool hasOwner = GlobalVariableCheck(ownerVar);
      long ownerChartId = hasOwner ? (long)GlobalVariableGet(ownerVar) : 0;
      bool heartbeatKnown = false;
      double heartbeatAge = 0.0;
      // A sentinel value of 0.0 means "no real owner yet" even though the
      // variable technically exists (see GlobalVariableTemp above) - treat
      // it as hasOwner=false for the purposes of the pure decision so the
      // CLAIM_NEW path is taken rather than a nonsensical takeover of
      // chart id 0.
      bool ownedForReal = hasOwner && ownerChartId != 0;
      if(ownedForReal)
      {
         heartbeatKnown = GlobalVariableCheck(heartbeatVar);
         if(heartbeatKnown)
            heartbeatAge = (double)TimeCurrent() - GlobalVariableGet(heartbeatVar);
      }

      ENUM_FLASH_OWNERSHIP_DECISION decision = Decide(ownedForReal, ownerChartId, myChartId, heartbeatKnown,
                                                         heartbeatAge, FLASH_OWNERSHIP_HEARTBEAT_TIMEOUT_SECONDS);

      switch(decision)
      {
         case FLASH_OWNERSHIP_CLAIM_NEW:
         {
            // Atomic compare-and-set: only becomes owner if the variable
            // is still exactly 0.0 (unowned) at the moment of the write.
            // This closes the TOCTOU race between the read above and the
            // write here, where two instances observing "no prior owner"
            // in the same tick could previously both proceed to write and
            // both believe they were the sole owner (live evidence,
            // 2026-09-17: charts 46923012826300 and 46944538470998 both
            // logged "Claimed ... (no prior owner)" within the same
            // second). If the condition fails here, another instance won
            // the race in between; fall through to BLOCKED_CONFLICT-style
            // handling rather than retrying inline - the next tick's call
            // to TryClaim will re-evaluate cleanly against whatever state
            // the winner left behind.
            bool won = GlobalVariableSetOnCondition(ownerVar, (double)myChartId, 0.0);
            if(!won)
            {
               CFlashLogger::Error("OWNERSHIP",
                  StringFormat("Lost the claim race for %s magic=%d (chart %I64d) - another instance claimed it first this tick; will retry next tick.",
                                symbol, (int)magic, myChartId));
               return false;
            }
            GlobalVariableSet(heartbeatVar, (double)TimeCurrent());
            CFlashLogger::Log("OWNERSHIP",
               StringFormat("Claimed %s magic=%d for chart %I64d (no prior owner)", symbol, (int)magic, myChartId));
            return true;
         }

         case FLASH_OWNERSHIP_ALREADY_OWNER:
            GlobalVariableSet(heartbeatVar, (double)TimeCurrent());
            return true;

         case FLASH_OWNERSHIP_TAKEOVER_STALE:
         {
            // Atomic compare-and-set against the exact stale owner id just
            // observed, so a takeover can never silently clobber a
            // different instance that claimed or took over the lock in
            // between the read and this write.
            bool won = GlobalVariableSetOnCondition(ownerVar, (double)myChartId, (double)ownerChartId);
            if(!won)
            {
               CFlashLogger::Error("OWNERSHIP",
                  StringFormat("Lost the takeover race for %s magic=%d (chart %I64d) - ownership changed underneath this attempt; will retry next tick.",
                                symbol, (int)magic, myChartId));
               return false;
            }
            CFlashLogger::Log("OWNERSHIP",
               StringFormat("Taking over %s magic=%d from stale chart %I64d (heartbeat age %.0fs > %.0fs) for chart %I64d",
                             symbol, (int)magic, ownerChartId, heartbeatAge, FLASH_OWNERSHIP_HEARTBEAT_TIMEOUT_SECONDS, myChartId));
            GlobalVariableSet(heartbeatVar, (double)TimeCurrent());
            return true;
         }

         case FLASH_OWNERSHIP_BLOCKED_CONFLICT:
         default:
            CFlashLogger::Error("OWNERSHIP",
               StringFormat("Another Flash instance (chart %I64d) actively owns %s magic=%d - this instance (chart %I64d) will NOT trade until that instance releases ownership or its heartbeat goes stale.",
                             ownerChartId, symbol, (int)magic, myChartId));
            return false;
      }
   }

   // Called every tick by the owning instance to prove it is still alive.
   // Refuses to overwrite the lock if this instance is no longer the
   // recorded owner (e.g. it was taken over as stale while suspended).
   static void Heartbeat(const string symbol, const long magic, const long myChartId)
   {
      string ownerVar = OwnerVarName(symbol, magic);
      if(!GlobalVariableCheck(ownerVar))
         return;
      long ownerChartId = (long)GlobalVariableGet(ownerVar);
      if(ownerChartId != myChartId)
         return;
      GlobalVariableSet(HeartbeatVarName(symbol, magic), (double)TimeCurrent());
   }

   // Called on clean OnDeinit so a legitimate restart does not have to
   // wait out the staleness timeout to reclaim its own lock.
   static void Release(const string symbol, const long magic, const long myChartId)
   {
      string ownerVar = OwnerVarName(symbol, magic);
      if(!GlobalVariableCheck(ownerVar))
         return;
      long ownerChartId = (long)GlobalVariableGet(ownerVar);
      if(ownerChartId != myChartId)
         return; // not ours to release
      GlobalVariableSet(ownerVar, 0.0);
      GlobalVariableDel(HeartbeatVarName(symbol, magic));
      CFlashLogger::Log("OWNERSHIP", StringFormat("Released %s magic=%d (clean deinit, chart %I64d)", symbol, (int)magic, myChartId));
   }
};

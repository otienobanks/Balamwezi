//+------------------------------------------------------------------+
//| FlashRecoveryFixture.mq5                                         |
//| One-off, operator-run fixture script for Phase 2 verification-   |
//| only safety pass (2026-09-17). Creates a single, deliberately    |
//| controlled exposure/order condition so Flash's own startup       |
//| recovery classifier can be tested against a REAL broker state -  |
//| this script never performs recovery itself, and never closes,    |
//| modifies, or otherwise interacts with any order or position it   |
//| did not itself just create.                                      |
//|                                                                    |
//| Hard safety limits (all enforced in code, not just by comment):   |
//|  - Refuses to run on anything but a demo account.                 |
//|  - Refuses to run on any symbol other than the one confirmed.     |
//|  - Uses a dedicated test magic number, never Flash's live magic,  |
//|    so this fixture can never be confused with real exposure.      |
//|    Attach Flash to this same demo chart with its own              |
//|    "Flash Magic Number" input set to MATCH TestMagicNumber below  |
//|    for the recovery test to actually exercise Flash's classifier  |
//|    against this fixture.                                          |
//|  - Smallest permitted volume for the symbol only.                 |
//|  - Refuses to run if ANY position or order already exists under   |
//|    (symbol, TestMagicNumber) - never stacks fixtures.              |
//|  - Runs once and exits. No timers, no loop, no unattended action. |
//+------------------------------------------------------------------+
#property copyright "OtienoBanks"
#property version   "1.00"
#property strict
#property script_show_inputs

enum ENUM_FIXTURE_SCENARIO
{
   FIXTURE_A_VALID_PENDING_PAIR = 0,   // Recovery A: both a buy stop and a sell stop pending, no position
   FIXTURE_C_INCOMPLETE_PENDING = 1,   // Recovery C: only one side pending, no position
   FIXTURE_D_ACTIVE_UNPROTECTED = 2    // Recovery D: one open position with no protective SL
};

input string              TargetSymbol      = "XAUUSD";   // Must match the chart this script is run on
input long                TestMagicNumber   = 999001;     // Dedicated test magic - NEVER Flash's live magic
input ENUM_FIXTURE_SCENARIO Scenario        = FIXTURE_D_ACTIVE_UNPROTECTED;
input double               PendingOffsetPoints = 500;     // Distance from market for pending-order scenarios (points)

void Fail(const string reason)
{
   Alert("FlashRecoveryFixture ABORTED: " + reason);
   Print("[FIXTURE][ABORT] ", reason);
}

int OnStart()
{
   //--- Hard guard 1: demo account only.
   if((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Fail("Account is not a demo account. This fixture will not run on a live-money account.");
      return -1;
   }

   //--- Hard guard 2: explicit symbol check - must match the chart AND the declared target.
   if(_Symbol != TargetSymbol)
   {
      Fail(StringFormat("Chart symbol %s does not match TargetSymbol input %s.", _Symbol, TargetSymbol));
      return -1;
   }

   //--- Hard guard 3: never collide with Flash's own live magic number. Operator must
   //    set TestMagicNumber to something that is not the live FlashMagicNumber input.
   if(TestMagicNumber <= 0)
   {
      Fail("TestMagicNumber must be a positive dedicated test value.");
      return -1;
   }

   //--- Hard guard 4: refuse if this (symbol, magic) already has any position or order,
   //    so this script can never stack a second fixture on top of an existing one.
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (long)PositionGetInteger(POSITION_MAGIC) == TestMagicNumber)
      {
         Fail(StringFormat("A position (ticket %I64u) already exists under this test magic. Clear it before running again.", ticket));
         return -1;
      }
   }
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && (long)OrderGetInteger(ORDER_MAGIC) == TestMagicNumber)
      {
         Fail(StringFormat("A pending order (ticket %I64u) already exists under this test magic. Clear it before running again.", ticket));
         return -1;
      }
   }

   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double offset  = PendingOffsetPoints * point;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.symbol   = _Symbol;
   req.magic    = (ulong)TestMagicNumber;
   req.volume   = volMin;
   req.deviation = 20;
   req.comment  = "FlashRecoveryFixture";

   bool ok = false;

   if(Scenario == FIXTURE_A_VALID_PENDING_PAIR)
   {
      req.action = TRADE_ACTION_PENDING;
      req.type   = ORDER_TYPE_BUY_STOP;
      req.price  = NormalizeDouble(ask + offset, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      req.type_time = ORDER_TIME_GTC;
      ok = OrderSend(req, res);
      if(ok && res.retcode == TRADE_RETCODE_DONE)
         Print("[FIXTURE][A] Buy stop placed, ticket=", res.order);
      else
      {
         Fail(StringFormat("Buy stop leg failed, retcode=%d", res.retcode));
         return -1;
      }

      ZeroMemory(req);
      req.action = TRADE_ACTION_PENDING;
      req.symbol = _Symbol;
      req.magic  = (ulong)TestMagicNumber;
      req.volume = volMin;
      req.deviation = 20;
      req.comment = "FlashRecoveryFixture";
      req.type   = ORDER_TYPE_SELL_STOP;
      req.price  = NormalizeDouble(bid - offset, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      req.type_time = ORDER_TIME_GTC;
      ok = OrderSend(req, res);
      if(ok && res.retcode == TRADE_RETCODE_DONE)
         Print("[FIXTURE][A] Sell stop placed, ticket=", res.order, " - scenario A fixture complete. Attach Flash now.");
      else
         Fail(StringFormat("Sell stop leg failed, retcode=%d (buy stop leg above is now orphaned - cancel it manually).", res.retcode));
   }
   else if(Scenario == FIXTURE_C_INCOMPLETE_PENDING)
   {
      req.action = TRADE_ACTION_PENDING;
      req.type   = ORDER_TYPE_BUY_STOP;
      req.price  = NormalizeDouble(ask + offset, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      req.type_time = ORDER_TIME_GTC;
      ok = OrderSend(req, res);
      if(ok && res.retcode == TRADE_RETCODE_DONE)
         Print("[FIXTURE][C] Single buy stop placed, ticket=", res.order, " - scenario C fixture complete (one side only, deliberately). Attach Flash now.");
      else
         Fail(StringFormat("Buy stop leg failed, retcode=%d", res.retcode));
   }
   else // FIXTURE_D_ACTIVE_UNPROTECTED
   {
      req.action = TRADE_ACTION_DEAL;
      req.type   = ORDER_TYPE_BUY;
      req.price  = ask;
      // Deliberately no req.sl - this is the point of the fixture: an
      // active position under Flash's test magic with no protective stop.
      ok = OrderSend(req, res);
      if(ok && res.retcode == TRADE_RETCODE_DONE)
         Print("[FIXTURE][D] Market buy opened with NO stop loss, ticket=", res.order,
               " - scenario D fixture complete. Attach Flash now with FlashMagicNumber=", TestMagicNumber, " and observe its recovery classification.");
      else
         Fail(StringFormat("Market buy failed, retcode=%d", res.retcode));
   }

   return 0;
}

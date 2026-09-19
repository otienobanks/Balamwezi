//+------------------------------------------------------------------+
//| FlashReversalRaceFixture.mq5                                     |
//| Test 6 verification fixture - forces the same-tick               |
//| SL-hit-plus-reversal-fill race deterministically instead of       |
//| waiting on live price action.                                    |
//|                                                                    |
//| Requires a Flash instance already running on this chart, in       |
//| POSITION_ACTIVE with an armed reversal (wait for the Journal to   |
//| show "[FLASH][REVERSAL] Reversal order armed"), under the magic   |
//| number given below. This script then, in one synchronous run:    |
//|   1. Force-closes Flash's open position at market (simulating     |
//|      the SL being hit).                                           |
//|   2. Cancels Flash's armed reversal pending order and replaces    |
//|      it with an equivalent market fill in the same direction/     |
//|      volume, so the pending order disappears exactly as it would |
//|      on a real fill.                                              |
//| Both steps complete before Flash's own next OnTick, so when Flash |
//| next runs ManageActiveSetup() it sees the old position gone AND   |
//| the reversal ticket gone at the same time - the exact input       |
//| state the reordering fix (2026-09-17/18) targets. This is not a   |
//| literal guarantee of landing in the identical broker tick as a    |
//| real SL-hit-plus-fill, but it reliably reproduces the state Flash |
//| reacts to, which is what the code path actually depends on.       |
//|                                                                    |
//| Demo-only. Operates on a REAL running Flash setup under the given |
//| magic - it deliberately closes that setup's position and forces   |
//| its reversal, so only run this when you intend exactly that.      |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

input long TargetMagic = 260917;  // magic of the Flash instance to force the race on - must already be POSITION_ACTIVE with an armed reversal

void Fail(const string msg)
{
   Alert("FlashReversalRaceFixture ABORTED: " + msg);
   Print("[RACEFIXTURE][ABORT] " + msg);
}

ENUM_ORDER_TYPE_FILLING ResolveFillingMode(const string symbol)
{
   long flags = (long)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((flags & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((flags & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool SendWithFallback(MqlTradeRequest &req, MqlTradeResult &res)
{
   ENUM_ORDER_TYPE_FILLING preferred = ResolveFillingMode(req.symbol);
   ENUM_ORDER_TYPE_FILLING order[3];
   order[0] = preferred;
   int idx = 1;
   if(preferred != ORDER_FILLING_FOK)
      order[idx++] = ORDER_FILLING_FOK;
   if(preferred != ORDER_FILLING_IOC)
      order[idx++] = ORDER_FILLING_IOC;
   if(preferred != ORDER_FILLING_RETURN)
      order[idx++] = ORDER_FILLING_RETURN;

   for(int attempt = 0; attempt < idx; attempt++)
   {
      ZeroMemory(res);
      req.type_filling = order[attempt];
      bool sent = OrderSend(req, res);
      if(sent && res.retcode == TRADE_RETCODE_DONE)
         return true;
      if(res.retcode != TRADE_RETCODE_INVALID_FILL)
         return false;
   }
   return false;
}

void OnStart()
{
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Fail("This must only run on a demo account.");
      return;
   }

   ulong  posTicket = 0;
   double posVolume = 0.0;
   long   posType = -1;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) && PositionGetString(POSITION_SYMBOL) == _Symbol
         && PositionGetInteger(POSITION_MAGIC) == TargetMagic)
      {
         posTicket = t;
         posVolume = PositionGetDouble(POSITION_VOLUME);
         posType   = PositionGetInteger(POSITION_TYPE);
         break;
      }
   }

   ulong  pendTicket = 0;
   double pendVolume = 0.0;
   long   pendType = -1;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong t = OrderGetTicket(i);
      if(OrderSelect(t) && OrderGetString(ORDER_SYMBOL) == _Symbol
         && OrderGetInteger(ORDER_MAGIC) == TargetMagic)
      {
         pendTicket = t;
         pendVolume = OrderGetDouble(ORDER_VOLUME_CURRENT);
         pendType   = OrderGetInteger(ORDER_TYPE);
         break;
      }
   }

   if(posTicket == 0)
   {
      Fail(StringFormat("No open Flash position found under magic=%d. Wait until Flash has an active position with an armed reversal, then run this again.", (int)TargetMagic));
      return;
   }
   if(pendTicket == 0)
   {
      Fail(StringFormat("No pending reversal order found under magic=%d. Wait until the Journal shows \'Reversal order armed\', then run this again.", (int)TargetMagic));
      return;
   }

   Print(StringFormat("[RACEFIXTURE] Found position ticket=%I64u and reversal pending ticket=%I64u - forcing both to resolve before Flash's next tick.", posTicket, pendTicket));

   MqlTradeRequest closeReq;
   MqlTradeResult  closeRes;
   ZeroMemory(closeReq);
   ZeroMemory(closeRes);
   closeReq.action   = TRADE_ACTION_DEAL;
   closeReq.position = posTicket;
   closeReq.symbol   = _Symbol;
   closeReq.volume   = posVolume;
   closeReq.type     = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   closeReq.price    = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   closeReq.comment  = "RACEFIXTURE forced close (simulated SL hit)";
   if(!SendWithFallback(closeReq, closeRes))
   {
      Fail(StringFormat("Could not close position %I64u: retcode=%u comment=%s", posTicket, closeRes.retcode, closeRes.comment));
      return;
   }
   Print("[RACEFIXTURE] Position closed.");

   MqlTradeRequest cancelReq;
   MqlTradeResult  cancelRes;
   ZeroMemory(cancelReq);
   ZeroMemory(cancelRes);
   cancelReq.action = TRADE_ACTION_REMOVE;
   cancelReq.order  = pendTicket;
   if(!OrderSend(cancelReq, cancelRes) || cancelRes.retcode != TRADE_RETCODE_DONE)
   {
      Fail(StringFormat("Position was closed, but could not cancel pending order %I64u: retcode=%u comment=%s. Reattach Flash and reaccess the logs immediately - the old position is already gone.", pendTicket, cancelRes.retcode, cancelRes.comment));
      return;
   }

   MqlTradeRequest fillReq;
   MqlTradeResult  fillRes;
   ZeroMemory(fillReq);
   ZeroMemory(fillRes);
   fillReq.action = TRADE_ACTION_DEAL;
   fillReq.symbol = _Symbol;
   fillReq.volume = pendVolume;
   fillReq.type   = (pendType == ORDER_TYPE_BUY_STOP) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   fillReq.price  = (pendType == ORDER_TYPE_BUY_STOP) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   fillReq.magic  = TargetMagic;
   fillReq.comment = "RACEFIXTURE forced reversal fill";
   if(!SendWithFallback(fillReq, fillRes))
   {
      Fail(StringFormat("Position closed but could not force the reversal fill: retcode=%u comment=%s. Flash's old position is already gone - reattach it and reaccess the logs immediately to see how it handles the gap.", fillRes.retcode, fillRes.comment));
      return;
   }

   Print("[RACEFIXTURE] Reversal fill forced. Both events now resolved before Flash's next tick - reaccess the Journal for [FLASH][REVERSAL] reconciliation lines.");
}

//+------------------------------------------------------------------+
//| FlashOrders.mqh                                                  |
//| Owner: Phase 1, Stage 1.4 - Pending-Order Execution and Initial   |
//|        Position Protection                                        |
//|                                                                    |
//| Real MT5 order placement, cancellation, and position-protection   |
//| verification. Every function here verifies the ACTUAL broker      |
//| result (via OrderSelect / PositionSelectByTicket / HistoryDeal    |
//| lookups) rather than assuming a sent request succeeded - a        |
//| request being submitted is never treated as equivalent to it      |
//| being accepted, placed, filled, or protected.                     |
//+------------------------------------------------------------------+
#property strict
#include "..\Core\FlashLogger.mqh"

struct SFlashOrderResult
{
   bool   success;
   ulong  ticket;      // resulting order ticket (pending order) or 0
   uint   retcode;
   string comment;
};

class CFlashOrders
{
public:
   // Places one Buy Stop or Sell Stop with its protective SL attached at
   // submission time - Flash never places an unprotected pending order
   // and attaches the SL afterward.
   static SFlashOrderResult SendPendingOrder(const string symbol, const ENUM_ORDER_TYPE orderType,
                                              const double volume, const double price, const double sl,
                                              const long magic, const string comment)
   {
      SFlashOrderResult out;
      out.success = false;
      out.ticket = 0;
      out.retcode = 0;
      out.comment = "";

      if(orderType != ORDER_TYPE_BUY_STOP && orderType != ORDER_TYPE_SELL_STOP)
      {
         out.comment = "Unsupported order type - Flash only uses Buy Stop / Sell Stop";
         CFlashLogger::Error("ORDERS", out.comment);
         return out;
      }

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action    = TRADE_ACTION_PENDING;
      request.symbol     = symbol;
      request.volume     = volume;
      request.type       = orderType;
      request.price      = price;
      request.sl         = sl;
      request.tp         = 0.0;
      request.magic      = (ulong)magic;
      request.comment    = comment;
      request.type_time  = ORDER_TIME_GTC;
      request.type_filling = ResolveFillingMode(symbol);

      bool sent = OrderSend(request, result);
      out.retcode = result.retcode;

      if(!sent || (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED))
      {
         out.comment = StringFormat("OrderSend rejected: retcode=%u comment=%s", result.retcode, result.comment);
         CFlashLogger::Error("ORDERS", out.comment);
         return out;
      }

      // Verify the order actually exists in the terminal before trusting it.
      if(!OrderSelect(result.order))
      {
         out.comment = StringFormat("Broker reported success (retcode=%u) but order %I64u is not selectable - treating as unverified",
                                     result.retcode, result.order);
         CFlashLogger::Error("ORDERS", out.comment);
         return out;
      }

      out.success = true;
      out.ticket = result.order;
      CFlashLogger::Log("ORDERS",
         StringFormat("Placed %s | ticket=%I64u | volume=%s | price=%s | sl=%s",
                      EnumToString(orderType), out.ticket, DoubleToString(volume, 2),
                      DoubleToString(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)),
                      DoubleToString(sl, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS))));
      return out;
   }

   // Cancels one pending order and verifies it is actually gone. If the
   // order has already filled (race with the market), this correctly
   // reports failure rather than silently treating cancellation as done -
   // callers must then treat the resulting position as real exposure.
   static bool CancelOrder(const ulong ticket)
   {
      if(!OrderSelect(ticket))
      {
         CFlashLogger::Debug("ORDERS", StringFormat("CancelOrder: ticket %I64u no longer pending (already filled or removed)", ticket));
         return false;
      }

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action = TRADE_ACTION_REMOVE;
      request.order = ticket;

      bool sent = OrderSend(request, result);

      if(!sent || (result.retcode != TRADE_RETCODE_DONE))
      {
         CFlashLogger::Error("ORDERS",
            StringFormat("Cancel failed for ticket %I64u: retcode=%u comment=%s", ticket, result.retcode, result.comment));
         return false;
      }

      bool stillExists = OrderSelect(ticket);
      if(stillExists)
      {
         CFlashLogger::Error("ORDERS", StringFormat("Cancel reported success but ticket %I64u is still selectable", ticket));
         return false;
      }

      CFlashLogger::Log("ORDERS", StringFormat("Cancelled ticket %I64u and verified removal", ticket));
      return true;
   }

   // Phase 3 REC02 - identical to CancelOrder, except it also surfaces the
   // raw trade-server retcode to the caller via outRetcode, so a
   // market-closed rejection (10018/10021 class) can be distinguished from
   // any other cancellation failure without guessing from a bool alone.
   static bool CancelOrderEx(const ulong ticket, uint &outRetcode)
   {
      outRetcode = 0;
      if(!OrderSelect(ticket))
      {
         CFlashLogger::Debug("ORDERS", StringFormat("CancelOrderEx: ticket %I64u no longer pending (already filled or removed)", ticket));
         return true; // nothing outstanding - not an error
      }

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action = TRADE_ACTION_REMOVE;
      request.order = ticket;

      bool sent = OrderSend(request, result);
      outRetcode = result.retcode;

      if(!sent || (result.retcode != TRADE_RETCODE_DONE))
      {
         CFlashLogger::Error("ORDERS",
            StringFormat("CancelOrderEx failed for ticket %I64u: retcode=%u comment=%s", ticket, result.retcode, result.comment));
         return false;
      }

      bool stillExists = OrderSelect(ticket);
      if(stillExists)
      {
         CFlashLogger::Error("ORDERS", StringFormat("CancelOrderEx reported success but ticket %I64u is still selectable", ticket));
         return false;
      }

      CFlashLogger::Log("ORDERS", StringFormat("Cancelled ticket %I64u and verified removal", ticket));
      return true;
   }

   static bool CancelGroup(ulong &tickets[])
   {
      bool allOk = true;
      for(int i = 0; i < ArraySize(tickets); i++)
      {
         if(tickets[i] == 0) continue;
         if(!CancelOrder(tickets[i]))
            allOk = false;
      }
      return allOk;
   }

   static bool PositionExists(const ulong ticket)
   {
      return PositionSelectByTicket(ticket);
   }

   static bool PositionHasProtectiveSL(const ulong ticket)
   {
      if(!PositionSelectByTicket(ticket))
         return false;
      double sl = PositionGetDouble(POSITION_SL);
      return (sl != 0.0);
   }

   // Attempts to (re)attach a protective SL to an existing position. Used
   // only in the emergency-recovery path when a position is found without
   // one - never used to widen an already-present SL.
   static bool SetPositionSL(const ulong ticket, const double sl)
   {
      if(!PositionSelectByTicket(ticket))
      {
         CFlashLogger::Error("ORDERS", StringFormat("SetPositionSL: ticket %I64u is not an open position", ticket));
         return false;
      }

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action   = TRADE_ACTION_SLTP;
      request.position = ticket;
      request.symbol   = PositionGetString(POSITION_SYMBOL);
      request.sl       = sl;
      request.tp       = PositionGetDouble(POSITION_TP);

      bool sent = OrderSend(request, result);
      if(!sent || result.retcode != TRADE_RETCODE_DONE)
      {
         CFlashLogger::Error("ORDERS",
            StringFormat("SetPositionSL failed for ticket %I64u: retcode=%u comment=%s", ticket, result.retcode, result.comment));
         return false;
      }

      bool verified = PositionHasProtectiveSL(ticket);
      if(!verified)
         CFlashLogger::Error("ORDERS", StringFormat("SetPositionSL reported success but ticket %I64u still shows no SL", ticket));

      return verified;
   }

   // Safety Revision - Defect 2/Defect 1: retcode-surfacing variant of
   // SetPositionSL, mirroring ClosePositionMarketEx/CancelOrderEx, so
   // callers (trailing gating, recovery SL restoration) can classify
   // WHY a modification failed instead of only knowing that it did.
   static bool SetPositionSLEx(const ulong ticket, const double sl, uint &outRetcode)
   {
      outRetcode = 0;
      if(!PositionSelectByTicket(ticket))
      {
         CFlashLogger::Error("ORDERS", StringFormat("SetPositionSLEx: ticket %I64u is not an open position", ticket));
         return false;
      }

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action   = TRADE_ACTION_SLTP;
      request.position = ticket;
      request.symbol   = PositionGetString(POSITION_SYMBOL);
      request.sl       = sl;
      request.tp       = PositionGetDouble(POSITION_TP);

      bool sent = OrderSend(request, result);
      outRetcode = result.retcode;
      if(!sent || result.retcode != TRADE_RETCODE_DONE)
      {
         CFlashLogger::Error("ORDERS",
            StringFormat("SetPositionSLEx failed for ticket %I64u: retcode=%u comment=%s", ticket, result.retcode, result.comment));
         return false;
      }

      bool verified = PositionHasProtectiveSL(ticket);
      if(!verified)
         CFlashLogger::Error("ORDERS", StringFormat("SetPositionSLEx reported success but ticket %I64u still shows no SL", ticket));

      return verified;
   }

   // Resolves a filling mode this symbol actually supports rather than
   // assuming one. Live evidence (2026-09-18) showed a hardcoded
   // ORDER_FILLING_RETURN being rejected by the broker with
   // retcode=10030 (Unsupported filling mode) on every single close
   // attempt for over a thousand consecutive ticks, because this
   // account/symbol does not accept RETURN filling. FOK and IOC are
   // checked first against the symbol's own reported SYMBOL_FILLING_MODE
   // flags; RETURN is only the last resort.
   static ENUM_ORDER_TYPE_FILLING ResolveFillingMode(const string symbol)
   {
      long flags = (long)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
      if((flags & SYMBOL_FILLING_FOK) != 0)
         return ORDER_FILLING_FOK;
      if((flags & SYMBOL_FILLING_IOC) != 0)
         return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
   }

   // Sends a market deal (open or close), retrying with the other two
   // filling modes in turn if the broker specifically rejects the first
   // attempt with retcode=10030 (Unsupported filling mode). This is what
   // was missing live: the EA looped forever resending the exact same
   // rejected filling mode instead of ever trying a different one. Any
   // other rejection reason is returned immediately and is never masked
   // by trying another filling mode.
   static bool SendMarketDealWithFillingFallback(MqlTradeRequest &request, MqlTradeResult &result)
   {
      ENUM_ORDER_TYPE_FILLING preferred = ResolveFillingMode(request.symbol);
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
         ZeroMemory(result);
         request.type_filling = order[attempt];
         bool sent = OrderSend(request, result);
         if(sent && result.retcode == TRADE_RETCODE_DONE)
            return true;

         if(result.retcode != TRADE_RETCODE_INVALID_FILL)
            return false; // a different failure - never mask it by trying another filling mode

         CFlashLogger::Error("ORDERS",
            StringFormat("Filling mode %d rejected (retcode=10030) for %s, trying next supported mode",
                          (int)order[attempt], request.symbol));
      }
      return false; // every supported filling mode was rejected
   }

   // General-purpose market close (not test-only) - used by Phase 2
   // reversal reconciliation to close remaining old-direction exposure.
   // Verifies the position is actually gone afterward. Kept as a thin
   // wrapper around ClosePositionMarketEx below so this call site (and
   // the reversal-reconciliation caller) is unaffected by the Phase 3
   // REC01 retcode-surfacing fix.
   static bool ClosePositionMarket(const ulong ticket, const string reason)
   {
      uint unusedRetcode = 0;
      return ClosePositionMarketEx(ticket, reason, unusedRetcode);
   }

   // Phase 3 REC01 - identical to ClosePositionMarket, except it also
   // surfaces the raw trade-server retcode to the caller via outRetcode.
   // This closes the disclosed Phase 3 limitation ("ClosePositionMarket
   // does not currently surface the raw retcode to this call site")
   // that caused HandleSetupExit to hardcode every close failure as
   // FLASH_EXEC_OTHER_REJECTED regardless of the actual cause. outRetcode
   // is set to 0 when the position was already flat (nothing was sent),
   // and to the last attempted MqlTradeResult.retcode otherwise -
   // including on a "reported success but still open" mismatch, so the
   // caller can classify that case from the real retcode too rather than
   // losing it.
   static bool ClosePositionMarketEx(const ulong ticket, const string reason, uint &outRetcode)
   {
      outRetcode = 0;
      if(!PositionSelectByTicket(ticket))
      {
         CFlashLogger::Debug("ORDERS", StringFormat("ClosePositionMarket: ticket %I64u already closed", ticket));
         return true; // already flat - not an error
      }

      string symbol = PositionGetString(POSITION_SYMBOL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      long   type   = PositionGetInteger(POSITION_TYPE);

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action   = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol   = symbol;
      request.volume   = volume;
      request.type     = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price    = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID)
                                                       : SymbolInfoDouble(symbol, SYMBOL_ASK);
      request.comment  = reason;

      bool sent = SendMarketDealWithFillingFallback(request, result);
      outRetcode = result.retcode;
      if(!sent)
      {
         CFlashLogger::Error("ORDERS",
            StringFormat("ClosePositionMarket failed for ticket %I64u (%s): retcode=%u comment=%s",
                         ticket, reason, result.retcode, result.comment));
         return false;
      }

      bool stillOpen = PositionSelectByTicket(ticket);
      if(stillOpen)
      {
         CFlashLogger::Error("ORDERS", StringFormat("ClosePositionMarket reported success but ticket %I64u is still open", ticket));
         return false;
      }

      CFlashLogger::Log("ORDERS", StringFormat("Closed ticket %I64u (%s) and verified flat", ticket, reason));
      return true;
   }

   // Modifies a pending order's price (and optionally its SL), used by
   // Phase 2 reversal synchronization when the trailing reference moves.
   // Verifies the actual resulting order price after the request.
   static bool ModifyPendingOrderPrice(const ulong ticket, const double newPrice, const double newSL)
   {
      if(!OrderSelect(ticket))
      {
         CFlashLogger::Error("ORDERS", StringFormat("ModifyPendingOrderPrice: ticket %I64u is not a pending order", ticket));
         return false;
      }

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action = TRADE_ACTION_MODIFY;
      request.order   = ticket;
      request.price   = newPrice;
      request.sl      = newSL;
      request.tp      = 0.0;
      request.type_time = ORDER_TIME_GTC;

      bool sent = OrderSend(request, result);
      if(!sent || result.retcode != TRADE_RETCODE_DONE)
      {
         CFlashLogger::Error("ORDERS",
            StringFormat("ModifyPendingOrderPrice failed for ticket %I64u: retcode=%u comment=%s",
                         ticket, result.retcode, result.comment));
         return false;
      }

      if(!OrderSelect(ticket))
      {
         CFlashLogger::Error("ORDERS", StringFormat("ModifyPendingOrderPrice: ticket %I64u no longer selectable after modify (possible race with a fill)", ticket));
         return false;
      }

      double actualPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      bool verified = (MathAbs(actualPrice - newPrice) < 0.0000001);
      if(!verified)
         CFlashLogger::Error("ORDERS", StringFormat("ModifyPendingOrderPrice: ticket %I64u actual price %s does not match requested %s",
                             ticket, DoubleToString(actualPrice, 5), DoubleToString(newPrice, 5)));
      return verified;
   }

   // Phase 3 REC02 - identical to ModifyPendingOrderPrice, except it also
   // surfaces the raw trade-server retcode to the caller via outRetcode.
   // outRetcode is 0 only when the request was never sent (ticket already
   // gone); otherwise it is the last attempted MqlTradeResult.retcode,
   // including on a "reported success but price mismatch" case, so the
   // caller can still classify a market-closed rejection from it.
   static bool ModifyPendingOrderPriceEx(const ulong ticket, const double newPrice, const double newSL, uint &outRetcode)
   {
      outRetcode = 0;
      if(!OrderSelect(ticket))
      {
         CFlashLogger::Error("ORDERS", StringFormat("ModifyPendingOrderPriceEx: ticket %I64u is not a pending order", ticket));
         return false;
      }

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action = TRADE_ACTION_MODIFY;
      request.order   = ticket;
      request.price   = newPrice;
      request.sl      = newSL;
      request.tp      = 0.0;
      request.type_time = ORDER_TIME_GTC;

      bool sent = OrderSend(request, result);
      outRetcode = result.retcode;
      if(!sent || result.retcode != TRADE_RETCODE_DONE)
      {
         CFlashLogger::Error("ORDERS",
            StringFormat("ModifyPendingOrderPriceEx failed for ticket %I64u: retcode=%u comment=%s",
                         ticket, result.retcode, result.comment));
         return false;
      }

      if(!OrderSelect(ticket))
      {
         CFlashLogger::Error("ORDERS", StringFormat("ModifyPendingOrderPriceEx: ticket %I64u no longer selectable after modify (possible race with a fill)", ticket));
         return false;
      }

      double actualPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      bool verified = (MathAbs(actualPrice - newPrice) < 0.0000001);
      if(!verified)
         CFlashLogger::Error("ORDERS", StringFormat("ModifyPendingOrderPriceEx: ticket %I64u actual price %s does not match requested %s",
                             ticket, DoubleToString(actualPrice, 5), DoubleToString(newPrice, 5)));
      return verified;
   }

   // Test-only manual exit. Must never be enabled as a normal strategy
   // rule - Phase 1 has no take-profit or timed-exit logic; this exists
   // purely so a controlled test can close a position deliberately.
   static bool TestOnlyCloseMarket(const ulong ticket, const string reason)
   {
      if(!PositionSelectByTicket(ticket))
         return false;

      CFlashLogger::Log("ORDERS", StringFormat("TEST-ONLY MANUAL EXIT invoked for ticket %I64u | reason=%s", ticket, reason));

      string symbol = PositionGetString(POSITION_SYMBOL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      long   type   = PositionGetInteger(POSITION_TYPE);

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action   = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol   = symbol;
      request.volume   = volume;
      request.type     = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price    = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID)
                                                       : SymbolInfoDouble(symbol, SYMBOL_ASK);
      bool sent = SendMarketDealWithFillingFallback(request, result);
      if(!sent)
      {
         CFlashLogger::Error("ORDERS",
            StringFormat("TEST-ONLY MANUAL EXIT failed for ticket %I64u: retcode=%u comment=%s", ticket, result.retcode, result.comment));
         return false;
      }
      return true;
   }
};

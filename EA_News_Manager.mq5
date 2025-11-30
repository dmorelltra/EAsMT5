//+------------------------------------------------------------------+
//|                                                EA_News_Manager.mq5|
//|                         Example implementation by OpenAI Assistant|
//|   News filter / risk manager that controls trading around economic |
//|   events fetched via WebRequest from https://api.symbolstats.vaotech.dev|
//+------------------------------------------------------------------+
#property copyright "OpenAI Assistant"
#property version   "1.000"
#property strict

#include <Trade/Trade.mqh>

//--- 01 – News management mode
enum ENUM_NewsMode
{
   NEWS_TRADE_DURING = 0,     // Operar noticias – only trade during news
   NEWS_BLOCK_NEW    = 1,     // No abrir trades durante noticias
   NEWS_CLOSE_ALL    = 2      // No operar noticias (cerrar todo)
};
input ENUM_NewsMode   NewsMode              = NEWS_BLOCK_NEW;

//--- 02 – News duration (seconds before and after news)
input int             NewsDurationSeconds   = 120;  // window around the event

//--- 03 – Currencies to monitor
input string          CurrenciesToMonitor   = "EUR,USD,GBP,JPY,AUD,CAD,NZD,CHF";

//--- Optional filters
input bool            OnlyHighImpact        = true;
input int             LookAheadMinutes      = 60;   // how far into the future to fetch news
input int             MagicNumberFilter     = 0;    // 0 = all trades, >0 = only this magic
input bool            ShowChartComment      = true; // display status on chart

//--- Internal configuration
input int             NewsRefreshSeconds    = 60;   // frequency to refresh news list
input bool            ClosePendingOrders    = true; // also cancel pending orders in NEWS_CLOSE_ALL

//+------------------------------------------------------------------+
//| Data structures                                                 |
//+------------------------------------------------------------------+
struct NewsEvent
{
   datetime time;   // assumed to be server time or UTC; see notes in comments
   string   currency;
   int      impact; // 1=low,2=medium,3=high
};

//+------------------------------------------------------------------+
//| Global variables                                                |
//+------------------------------------------------------------------+
CTrade         trade;
NewsEvent      g_events[];
datetime       g_lastNewsFetch = 0;
string         g_currencyList[];
bool           g_permissionsOk = false;

//+------------------------------------------------------------------+
//| Helper: trim spaces                                             |
//+------------------------------------------------------------------+
string Trim(const string value)
{
   string res = value;
   StringReplace(res,"\r","");
   StringReplace(res,"\n","");
   res = StringTrimLeft(StringTrimRight(res));
   return res;
}

//+------------------------------------------------------------------+
//| Helper: split currency list                                     |
//+------------------------------------------------------------------+
void BuildCurrencyList()
{
   StringSplit(CurrenciesToMonitor, ',', g_currencyList);
   for(int i=0;i<ArraySize(g_currencyList);++i)
      g_currencyList[i] = Trim(g_currencyList[i]);
}

//+------------------------------------------------------------------+
//| Permission checks                                               |
//+------------------------------------------------------------------+
bool CheckPermissions()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("EA_News_Manager: Algorithmic trading is disabled in terminal settings.");
      return false;
   }

   // Attempt a lightweight WebRequest to detect permissions
   char   result[];
   string headers;
   int    timeout = 5000;
   ResetLastError();
   int status = WebRequest("GET", "https://api.symbolstats.vaotech.dev", "", NULL, timeout, result, headers);
   if(status == -1 && GetLastError()==ERR_NOT_ENOUGH_RIGHTS)
   {
      Print("EA_News_Manager: WebRequest is not permitted. Add https://api.symbolstats.vaotech.dev in Tools -> Options -> Expert Advisors and allow WebRequest.");
      return false;
   }
   // If network unavailable we still allow startup; we rely on retries.
   return true;
}

//+------------------------------------------------------------------+
//| JSON utility helpers                                            |
//+------------------------------------------------------------------+
bool ExtractIntField(const string source,const string field,int &value)
{
   int pos = StringFind(source, '"'+field+'"');
   if(pos < 0) return false;
   int colon = StringFind(source, ":", pos);
   if(colon < 0) return false;
   string number = "";
   for(int i=colon+1;i<StringLen(source);++i)
   {
      ushort ch = StringGetCharacter(source, i);
      if((ch>='0' && ch<='9') || ch=='-' )
         number += (string)StringGetCharacter(source, i);
      else if(StringLen(number)>0)
         break;
   }
   if(StringLen(number)==0) return false;
   value = (int)StringToInteger(number);
   return true;
}

bool ExtractStringField(const string source,const string field,string &value)
{
   int pos = StringFind(source, '"'+field+'"');
   if(pos < 0) return false;
   int colon = StringFind(source, ":", pos);
   if(colon < 0) return false;
   int firstQuote = StringFind(source, "\"", colon+1);
   if(firstQuote < 0) return false;
   int secondQuote = StringFind(source, "\"", firstQuote+1);
   if(secondQuote < 0) return false;
   value = StringSubstr(source, firstQuote+1, secondQuote-firstQuote-1);
   return true;
}

//+------------------------------------------------------------------+
//| Parse JSON array into event list                                |
//+------------------------------------------------------------------+
int ParseNewsResponse(const string json)
{
   ArrayResize(g_events,0);
   int count = 0;
   int pos = 0;
   while(true)
   {
      int start = StringFind(json, "{", pos);
      if(start==-1) break;
      int end   = StringFind(json, "}", start);
      if(end==-1) break;
      string obj = StringSubstr(json, start, end-start+1);

      int timeVal, impactVal;
      string currencyVal;
      if(ExtractIntField(obj, "time", timeVal) && ExtractStringField(obj, "currency", currencyVal) && ExtractIntField(obj, "impact", impactVal))
      {
         datetime evTime = (datetime)timeVal; // assumes epoch seconds; adjust API if needed
         if(evTime < TimeCurrent())
         {
            pos = end+1;
            continue; // skip past events
         }
         if(evTime - TimeCurrent() > LookAheadMinutes*60)
         {
            pos = end+1;
            continue; // outside look-ahead window
         }
         if(OnlyHighImpact && impactVal < 3)
         {
            pos = end+1;
            continue;
         }
         // filter currency list
         bool allowedCurrency = false;
         for(int i=0;i<ArraySize(g_currencyList);++i)
         {
            if(StringLen(g_currencyList[i])==0) continue;
            if(StringCompare(g_currencyList[i], currencyVal, true)==0)
            {
               allowedCurrency = true;
               break;
            }
         }
         if(!allowedCurrency)
         {
            pos = end+1;
            continue;
         }
         int newIndex = ArraySize(g_events);
         ArrayResize(g_events, newIndex+1);
         g_events[newIndex].time     = evTime;
         g_events[newIndex].currency = currencyVal;
         g_events[newIndex].impact   = impactVal;
         count++;
      }
      pos = end+1;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Fetch news via WebRequest                                        |
//+------------------------------------------------------------------+
bool FetchNews()
{
   if(TimeCurrent() - g_lastNewsFetch < NewsRefreshSeconds)
      return true;

   char   result[];
   string headers;
   int    timeout = 10000;

   string url = "https://api.symbolstats.vaotech.dev";
   ResetLastError();
   int status = WebRequest("GET", url, "", NULL, timeout, result, headers);
   if(status == -1)
   {
      int err = GetLastError();
      PrintFormat("EA_News_Manager: WebRequest failed (%d): %s", err, ErrorDescription(err));
      return false;
   }

   string response = CharArrayToString(result, 0, -1, CP_UTF8);
   int parsed = ParseNewsResponse(response);
   PrintFormat("EA_News_Manager: fetched %d news events", parsed);
   g_lastNewsFetch = TimeCurrent();
   return parsed >= 0;
}

//+------------------------------------------------------------------+
//| Determine if symbol is in a news window                          |
//+------------------------------------------------------------------+
bool IsSymbolInNewsWindow(const string symbol)
{
   string base = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   string quote = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   datetime now = TimeCurrent();
   for(int i=0;i<ArraySize(g_events);++i)
   {
      if(StringCompare(g_events[i].currency, base, true)!=0 && StringCompare(g_events[i].currency, quote, true)!=0)
         continue;
      if(now >= g_events[i].time - NewsDurationSeconds && now <= g_events[i].time + NewsDurationSeconds)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if trading is allowed for a symbol                         |
//+------------------------------------------------------------------+
bool IsNewsAllowedForSymbol(const string symbol)
{
   bool inWindow = IsSymbolInNewsWindow(symbol);
   switch(NewsMode)
   {
      case NEWS_TRADE_DURING: return inWindow;
      case NEWS_BLOCK_NEW:    return !inWindow;
      case NEWS_CLOSE_ALL:    return !inWindow;
      default:                return true;
   }
}

//+------------------------------------------------------------------+
//| Close positions and pending orders for symbol                    |
//+------------------------------------------------------------------+
void CloseAllSymbolTrades(const string symbol)
{
   // Close positions
   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if(MagicNumberFilter>0 && PositionGetInteger(POSITION_MAGIC)!=MagicNumberFilter)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool closed = false;
      if(type==POSITION_TYPE_BUY)
         closed = trade.PositionClose(ticket);
      else if(type==POSITION_TYPE_SELL)
         closed = trade.PositionClose(ticket);

      if(!closed)
      {
         int err = _LastError;
         PrintFormat("EA_News_Manager: failed to close position %I64u on %s (%d): %s", ticket, symbol, err, ErrorDescription(err));
      }
   }

   if(!ClosePendingOrders)
      return;

   // Remove pending orders
   for(int j=OrdersTotal()-1;j>=0;--j)
   {
      ulong ordTicket = OrderGetTicket(j);
      if(!OrderSelect(ordTicket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol)
         continue;
      if(MagicNumberFilter>0 && OrderGetInteger(ORDER_MAGIC)!=MagicNumberFilter)
         continue;

      if(!trade.OrderDelete(ordTicket))
      {
         int err = _LastError;
         PrintFormat("EA_News_Manager: failed to delete order %I64u on %s (%d): %s", ordTicket, symbol, err, ErrorDescription(err));
      }
   }
}

//+------------------------------------------------------------------+
//| Process live positions based on mode                             |
//+------------------------------------------------------------------+
void EnforceNewsRules()
{
   if(NewsMode!=NEWS_CLOSE_ALL)
      return;

   for(int i=PositionsTotal()-1;i>=0;--i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!IsSymbolInNewsWindow(sym))
         continue;
      if(MagicNumberFilter>0 && PositionGetInteger(POSITION_MAGIC)!=MagicNumberFilter)
         continue;
      CloseAllSymbolTrades(sym);
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   BuildCurrencyList();
   g_permissionsOk = CheckPermissions();
   if(!g_permissionsOk)
      return INIT_FAILED;

   EventSetTimer(10); // timer for periodic tasks
   Print("EA_News_Manager initialized. Ensure WebRequest is permitted for https://api.symbolstats.vaotech.dev");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_permissionsOk)
      return;

   FetchNews();
   EnforceNewsRules();
   if(ShowChartComment)
      UpdateChartComment();
}

//+------------------------------------------------------------------+
//| OnTimer                                                          |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_permissionsOk)
      return;

   FetchNews();
   EnforceNewsRules();
}

//+------------------------------------------------------------------+
//| OnTradeTransaction                                               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(!g_permissionsOk)
      return;

   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      if(!HistorySelectByPosition(trans.position))
         HistorySelect(TimeCurrent()-86400, TimeCurrent());
      if(!HistoryDealSelect(dealTicket))
         return;

      string sym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      if(MagicNumberFilter>0 && HistoryDealGetInteger(dealTicket, DEAL_MAGIC)!=MagicNumberFilter)
         return;

      bool allowed = IsNewsAllowedForSymbol(sym);
      if(!allowed)
      {
         PrintFormat("EA_News_Manager: blocking trade on %s due to news window (mode=%d)", sym, NewsMode);
         if(NewsMode==NEWS_CLOSE_ALL)
            CloseAllSymbolTrades(sym);
         else if(NewsMode==NEWS_BLOCK_NEW)
         {
            // Close just-opened position to enforce block
            if(PositionSelect(sym))
               trade.PositionClose(sym);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Chart comment helper                                             |
//+------------------------------------------------------------------+
string NextNewsTimeForSymbol(const string symbol)
{
   string base = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   string quote = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   datetime soonest = 0;
   for(int i=0;i<ArraySize(g_events);++i)
   {
      if(StringCompare(g_events[i].currency, base, true)!=0 && StringCompare(g_events[i].currency, quote, true)!=0)
         continue;
      if(soonest==0 || g_events[i].time < soonest)
         soonest = g_events[i].time;
   }
   if(soonest==0)
      return "n/a";
   return TimeToString(soonest, TIME_DATE|TIME_SECONDS);
}

void UpdateChartComment()
{
   string sym = _Symbol;
   bool allowed = IsNewsAllowedForSymbol(sym);
   bool inWindow = IsSymbolInNewsWindow(sym);
   string text;
   text = StringFormat("EA_News_Manager\nMode: %d\nSymbol: %s\nTrading allowed now: %s\nIn news window: %s\nNext news: %s\nLast fetch: %s", NewsMode, sym, allowed?"YES":"NO", inWindow?"YES":"NO", NextNewsTimeForSymbol(sym), TimeToString(g_lastNewsFetch, TIME_DATE|TIME_SECONDS));
   Comment(text);
}

//+------------------------------------------------------------------+
//| Notes                                                            |
//| Attach this EA to a chart of any symbol traded by other EAs or   |
//| manual strategies. Configure WebRequest permissions for          |
//| https://api.symbolstats.vaotech.dev under Tools -> Options ->    |
//| Expert Advisors. The API is expected to return JSON with fields  |
//| "time" (epoch seconds), "currency" (e.g., USD), and "impact"    |
//| (1-3). If your broker uses a different server timezone, adjust   |
//| the API or expect times to be interpreted as server time.        |
//|                                                                  |
//| Modes:                                                           |
//|  * NEWS_TRADE_DURING: only allow new trades while in a news      |
//|    window for the symbol.                                        |
//|  * NEWS_BLOCK_NEW: block new positions during a news window;     |
//|    existing positions remain.                                    |
//|  * NEWS_CLOSE_ALL: close positions (and optionally pending       |
//|    orders) when the symbol enters a news window and block new    |
//|    trades until it ends.                                         |
//|                                                                  |
//| The EA enforces rules for trades matching MagicNumberFilter (or  |
//| all trades if zero) and supports both netting and hedging        |
//| accounts.                                                        |
//+------------------------------------------------------------------+

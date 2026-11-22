//+------------------------------------------------------------------+
//|                                       Multi_Strategy_XAU_EA_v2.0 |
//|  Three independent modules sharing ONE risk budget:             |
//|   1) TREND   - pullback to EMA, only in Bull/Bear regime        |
//|   2) RANGE   - Bollinger/RSI mean reversion, only in Neutral    |
//|   3) BREAKOUT- Asian-range breakout at the London open          |
//|  Each module: own on/off switch, own magic number, own risk %.  |
//|  Shared: daily loss limit, loss-streak halt, total open-risk    |
//|  cap, max open positions, spread filters, Friday flat.          |
//|  NO martingale, NO grid, NO averaging down.                     |
//+------------------------------------------------------------------+
#property copyright "Starter template"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

#define MOD_TREND  1
#define MOD_RANGE  2
#define MOD_BREAK  3

//=== Module switches =================================================
input bool   InpUseTrend         = true;        // Module 1: Trend pullback
input bool   InpUseRange         = true;        // Module 2: Range mean reversion
input bool   InpUseBreakout      = true;        // Module 3: Asian breakout

//=== Common =========================================================
input ENUM_TIMEFRAMES InpTF      = PERIOD_M5;   // Trading timeframe
input int    InpATRPeriod        = 14;          // ATR period (trading TF)
input ulong  InpMagicBase        = 20260200;    // Magic base (module id is added)
input int    InpSlippagePoints   = 30;          // Max slippage (points)

//=== Shared risk ====================================================
input double InpMaxDailyLossPct  = 3.0;         // Halt for the day at -X% equity
input int    InpMaxConsecLosses  = 3;           // Halt for the day after N losses in a row (0=off)
input double InpMaxTotalRiskPct  = 1.0;         // Max combined open risk across modules (%)
input int    InpMaxOpenPositions = 2;           // Max simultaneous positions (all modules)
input int    InpMaxSpreadPoints  = 35;          // Skip entries if spread above this (points)
input double InpMaxSpreadToSL    = 0.15;        // Skip if spread > this fraction of SL distance (0=off)

//=== Regime filter (used by modules 1,2 and optionally 3) ============
input ENUM_TIMEFRAMES InpRegimeTF= PERIOD_M15;  // Regime timeframe
input int    InpRegimeEMA        = 50;          // Regime EMA period
input int    InpRegimeATR        = 14;          // Regime ATR period
input int    InpRegimeADX        = 14;          // Regime ADX period
input double InpRegimeMinADX     = 20.0;        // Below this = Neutral
input int    InpSlopeBars        = 10;          // Slope lookback (regime bars)
input double InpSlopeThresh      = 0.5;         // Min EMA move over lookback, in ATRs

//=== Volatility guard (modules 1,2) =================================
input bool   InpUseVolGuard      = true;        // Skip abnormal volatility spikes
input int    InpVolLookback      = 100;         // Bars for average ATR
input double InpMaxVolRatio      = 2.0;         // Skip if ATR > avg ATR * this

//=== Session / calendar (SERVER time) ===============================
input int    InpSessionStartHour = 10;          // Modules 1,2: session start hour
input int    InpSessionEndHour   = 19;          // Modules 1,2: session end hour (exclusive)
input int    InpFridayCloseHour  = 20;          // Friday: no entries + close trades from this hour (0=off)
input int    InpBlk1StartMin     = 0;           // News blackout 1 start (minutes of day, 870 = 14:30)
input int    InpBlk1EndMin       = 0;           // News blackout 1 end   (equal to start = off)
input int    InpBlk2StartMin     = 0;           // News blackout 2 start
input int    InpBlk2EndMin       = 0;           // News blackout 2 end

//=== Module 1: TREND pullback =======================================
input double InpTrendRisk        = 0.5;         // Risk per trade (% equity)
input int    InpFastEMA          = 20;          // Fast EMA (pullback line)
input int    InpSlowEMA          = 50;          // Slow EMA
input double InpTrendSL_ATR      = 1.2;         // SL = ATR * this
input double InpTrendRR          = 1.5;         // TP = SL * this
input bool   InpAllowBull        = true;        // Longs in Bull regime
input bool   InpAllowBear        = true;        // Shorts in Bear regime
input int    InpTrendMaxTrades   = 6;           // Max entries per day
input int    InpTrendHoldBars    = 24;          // Close after N bars (0=off)

//=== Module 2: RANGE mean reversion =================================
input double InpRangeRisk        = 0.3;         // Risk per trade (% equity)
input int    InpBBPeriod         = 20;          // Bollinger period
input double InpBBDev            = 2.0;         // Bollinger deviation
input int    InpRSIPeriod        = 14;          // RSI period
input double InpRSIOversold      = 35.0;        // Buy only if RSI <= this
input double InpRSIOverbought    = 65.0;        // Sell only if RSI >= this
input double InpRangeSL_ATR      = 1.5;         // SL = ATR * this
input double InpRangeMinRR       = 1.0;         // Skip if distance to mean < SL * this
input int    InpRangeMaxTrades   = 4;           // Max entries per day
input int    InpRangeHoldBars    = 18;          // Close after N bars (0=off)

//=== Module 3: Asian-range BREAKOUT =================================
input double InpBreakRisk        = 0.4;         // Risk per trade (% equity)
input int    InpAsianStartHour   = 2;           // Asian range start (server hour)
input int    InpAsianEndHour     = 10;          // Asian range end = breakout window start
input int    InpBreakEndHour     = 13;          // Breakout window end (exclusive)
input double InpAsianMinATRH1    = 0.5;         // Range height must be >= this * H1 ATR
input double InpAsianMaxATRH1    = 3.0;         // Range height must be <= this * H1 ATR
input int    InpBreakBufferPts   = 20;          // Close must clear range by this many points
input bool   InpBreakUseRegime   = true;        // Don't break against the regime direction
input double InpBreakMaxSL_ATR   = 3.0;         // Cap SL at ATR * this
input double InpBreakRR          = 1.5;         // TP = SL * this
input int    InpBreakMaxTrades   = 1;           // Max entries per day
input int    InpBreakHoldBars    = 36;          // Close after N bars (0=off)

//=== State ==========================================================
int      hFast, hSlow, hATR, hREMA, hRATR, hRADX, hBB, hRSI, hATRH1;
datetime lastBar       = 0;
int      dayKey        = -1;
double   dayStartBal   = 0.0;
int      tradesToday[4];
int      consecLosses  = 0;
bool     haltedToday   = false;

datetime asianDayStart = 0;
bool     asianValid    = false;
double   asianHi       = 0.0, asianLo = 0.0;

//+------------------------------------------------------------------+
ulong MagicOf(int id) { return InpMagicBase + (ulong)id; }

int OnInit()
{
   hFast = iMA(_Symbol, InpTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, InpTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, InpTF, InpATRPeriod);
   hREMA = iMA(_Symbol, InpRegimeTF, InpRegimeEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRATR = iATR(_Symbol, InpRegimeTF, InpRegimeATR);
   hRADX = iADX(_Symbol, InpRegimeTF, InpRegimeADX);
   hBB   = iBands(_Symbol, InpTF, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   hRSI  = iRSI(_Symbol, InpTF, InpRSIPeriod, PRICE_CLOSE);
   hATRH1= iATR(_Symbol, PERIOD_H1, 14);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hATR == INVALID_HANDLE ||
      hREMA == INVALID_HANDLE || hRATR == INVALID_HANDLE || hRADX == INVALID_HANDLE ||
      hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE || hATRH1 == INVALID_HANDLE)
      return INIT_FAILED;

   ArrayInitialize(tradesToday, 0);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hFast);  IndicatorRelease(hSlow);  IndicatorRelease(hATR);
   IndicatorRelease(hREMA);  IndicatorRelease(hRATR);  IndicatorRelease(hRADX);
   IndicatorRelease(hBB);    IndicatorRelease(hRSI);   IndicatorRelease(hATRH1);
   Comment("");
}

//+------------------------------------------------------------------+
//| Day / time helpers                                               |
//+------------------------------------------------------------------+
void ResetDayIfNeeded()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int key = t.year * 1000 + t.day_of_year;
   if(key != dayKey)
   {
      dayKey       = key;
      dayStartBal  = AccountInfoDouble(ACCOUNT_BALANCE);
      ArrayInitialize(tradesToday, 0);
      consecLosses = 0;
      haltedToday  = false;
   }
}

bool DailyLossHit()
{
   return (AccountInfoDouble(ACCOUNT_EQUITY) <= dayStartBal * (1.0 - InpMaxDailyLossPct / 100.0));
}

bool InMainSession()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return (t.hour >= InpSessionStartHour && t.hour < InpSessionEndHour);
}

bool InBreakWindow()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return (t.hour >= InpAsianEndHour && t.hour < InpBreakEndHour);
}

bool FridayCutoff()
{
   if(InpFridayCloseHour <= 0) return false;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return (t.day_of_week == 5 && t.hour >= InpFridayCloseHour);
}

bool InWindow(int startMin, int endMin, int nowMin)
{
   if(startMin == endMin) return false;
   if(startMin < endMin)  return (nowMin >= startMin && nowMin < endMin);
   return (nowMin >= startMin || nowMin < endMin);
}

bool InBlackout()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int nowMin = t.hour * 60 + t.min;
   return InWindow(InpBlk1StartMin, InpBlk1EndMin, nowMin) ||
          InWindow(InpBlk2StartMin, InpBlk2EndMin, nowMin);
}

bool NewBar()
{
   datetime t = iTime(_Symbol, InpTF, 0);
   if(t != lastBar) { lastBar = t; return true; }
   return false;
}

//+------------------------------------------------------------------+
//| Position helpers (all modules)                                   |
//+------------------------------------------------------------------+
bool IsMyMagic(long magic)
{
   return (magic > (long)InpMagicBase && magic <= (long)InpMagicBase + 3);
}

ulong FindModulePos(int id)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)MagicOf(id))
         return ticket;
   }
   return 0;
}

int CountOpen()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && IsMyMagic(PositionGetInteger(POSITION_MAGIC)))
         n++;
   }
   return n;
}

//--- Combined money-at-risk of all open module positions, as % of equity
double OpenRiskPct()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 100.0;

   double risk = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || !IsMyMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      if(sl <= 0.0) { risk += equity * 0.01; continue; }   // unknown SL -> assume 1%
      long type = PositionGetInteger(POSITION_TYPE);
      double dist = (type == POSITION_TYPE_BUY) ? (open - sl) : (sl - open);
      if(dist > 0.0) risk += (dist / tickSize) * tickValue * vol;   // SL moved past entry = no risk
   }
   return risk / equity * 100.0;
}

double CalcLots(double slDistance, double riskPct)
{
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * riskPct / 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickSize <= 0 || tickValue <= 0 || slDistance <= 0) return 0.0;

   double lossPerLot = (slDistance / tickSize) * tickValue;
   double lots       = riskMoney / lossPerLot;

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / step) * step;
   if(lots < minLot) return 0.0;   // too small for this risk % -> skip, never oversize
   return MathMin(lots, maxLot);
}

//+------------------------------------------------------------------+
//| Regime: +1 Bull, -1 Bear, 0 Neutral                              |
//+------------------------------------------------------------------+
int GetRegime()
{
   int need = InpSlopeBars + 2;
   double ema[], ratr[], radx[];
   ArraySetAsSeries(ema,  true);
   ArraySetAsSeries(ratr, true);
   ArraySetAsSeries(radx, true);
   if(CopyBuffer(hREMA, 0, 0, need, ema)  < need) return 0;
   if(CopyBuffer(hRATR, 0, 0, 3,    ratr) < 3)    return 0;
   if(CopyBuffer(hRADX, 0, 0, 3,    radx) < 3)    return 0;

   if(ratr[1] <= 0.0) return 0;
   if(radx[1] < InpRegimeMinADX) return 0;

   double slope = (ema[1] - ema[1 + InpSlopeBars]) / ratr[1];
   double close = iClose(_Symbol, InpRegimeTF, 1);

   if(slope >=  InpSlopeThresh && close > ema[1]) return  1;
   if(slope <= -InpSlopeThresh && close < ema[1]) return -1;
   return 0;
}

bool VolatilitySpike()
{
   if(!InpUseVolGuard) return false;
   int need = InpVolLookback + 2;
   double a[];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(hATR, 0, 0, need, a) < need) return true;

   double sum = 0.0;
   for(int i = 2; i < need; i++) sum += a[i];
   double avg = sum / (need - 2);
   if(avg <= 0.0) return true;
   return (a[1] / avg > InpMaxVolRatio);
}

//+------------------------------------------------------------------+
//| Shared order placement (risk checks + retry)                     |
//+------------------------------------------------------------------+
bool Place(int id, bool isBuy, double slDist, double tpDist, double riskPct)
{
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < minStop) slDist = minStop;
   if(tpDist < minStop) return false;

   double spreadPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(InpMaxSpreadToSL > 0.0 && spreadPrice > slDist * InpMaxSpreadToSL) return false;

   if(CountOpen() >= InpMaxOpenPositions) return false;
   if(OpenRiskPct() + riskPct > InpMaxTotalRiskPct) return false;

   double lots = CalcLots(slDist, riskPct);
   if(lots <= 0.0) return false;

   string tag = (id == MOD_TREND ? "TREND" : (id == MOD_RANGE ? "RANGE" : "BREAK"));
   trade.SetExpertMagicNumber(MagicOf(id));

   for(int attempt = 0; attempt < 2; attempt++)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      bool ok;
      if(isBuy)
         ok = trade.Buy(lots, _Symbol, ask, NormalizeDouble(ask - slDist, digits),
                        NormalizeDouble(ask + tpDist, digits), "v2 " + tag + " BUY");
      else
         ok = trade.Sell(lots, _Symbol, bid, NormalizeDouble(bid + slDist, digits),
                         NormalizeDouble(bid - tpDist, digits), "v2 " + tag + " SELL");
      if(ok) { tradesToday[id]++; return true; }

      uint rc = trade.ResultRetcode();
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED &&
         rc != TRADE_RETCODE_PRICE_OFF)
         break;
   }
   Print("Order failed (", tag, "): ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
//| Module 1: TREND pullback (Bull/Bear regimes only)                |
//+------------------------------------------------------------------+
void TryTrend(int regime)
{
   if(regime == 0) return;
   if(!InMainSession()) return;
   if(FindModulePos(MOD_TREND) != 0) return;
   if(tradesToday[MOD_TREND] >= InpTrendMaxTrades) return;
   if(VolatilitySpike()) return;

   double fast[], slow[], atr[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(atr,  true);
   if(CopyBuffer(hFast, 0, 0, 3, fast) < 3) return;
   if(CopyBuffer(hSlow, 0, 0, 3, slow) < 3) return;
   if(CopyBuffer(hATR,  0, 0, 3, atr)  < 3) return;

   double hi1 = iHigh(_Symbol, InpTF, 1);
   double lo1 = iLow(_Symbol, InpTF, 1);
   double cl1 = iClose(_Symbol, InpTF, 1);

   bool buy  = (regime ==  1) && InpAllowBull && fast[1] > slow[1] && lo1 <= fast[1] && cl1 > fast[1];
   bool sell = (regime == -1) && InpAllowBear && fast[1] < slow[1] && hi1 >= fast[1] && cl1 < fast[1];
   if(!buy && !sell) return;

   double slDist = atr[1] * InpTrendSL_ATR;
   Place(MOD_TREND, buy, slDist, slDist * InpTrendRR, InpTrendRisk);
}

//+------------------------------------------------------------------+
//| Module 2: RANGE mean reversion (Neutral regime only)            |
//+------------------------------------------------------------------+
void TryRange(int regime)
{
   if(regime != 0) return;
   if(!InMainSession()) return;
   if(FindModulePos(MOD_RANGE) != 0) return;
   if(tradesToday[MOD_RANGE] >= InpRangeMaxTrades) return;
   if(VolatilitySpike()) return;

   double upper[], lower[], mid[], rsi[], atr[];
   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);
   ArraySetAsSeries(mid,   true);
   ArraySetAsSeries(rsi,   true);
   ArraySetAsSeries(atr,   true);
   if(CopyBuffer(hBB,  1, 0, 3, upper) < 3) return;
   if(CopyBuffer(hBB,  2, 0, 3, lower) < 3) return;
   if(CopyBuffer(hBB,  0, 0, 3, mid)   < 3) return;
   if(CopyBuffer(hRSI, 0, 0, 3, rsi)   < 3) return;
   if(CopyBuffer(hATR, 0, 0, 3, atr)   < 3) return;

   double hi1 = iHigh(_Symbol, InpTF, 1);
   double lo1 = iLow(_Symbol, InpTF, 1);
   double cl1 = iClose(_Symbol, InpTF, 1);

   // Stretch beyond the band, then close back inside, with RSI confirming
   bool buy  = (lo1 <= lower[1] && cl1 > lower[1] && rsi[1] <= InpRSIOversold);
   bool sell = (hi1 >= upper[1] && cl1 < upper[1] && rsi[1] >= InpRSIOverbought);
   if(!buy && !sell) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = atr[1] * InpRangeSL_ATR;
   double tpDist = buy ? (mid[1] - ask) : (bid - mid[1]);       // target = the mean
   if(tpDist < slDist * InpRangeMinRR) return;                  // not enough room back to the mean

   Place(MOD_RANGE, buy, slDist, tpDist, InpRangeRisk);
}

//+------------------------------------------------------------------+
//| Module 3: Asian-range breakout                                   |
//+------------------------------------------------------------------+
bool UpdateAsianRange()
{
   datetime now = TimeCurrent();
   datetime dayStart = (datetime)((long)now - ((long)now % 86400));
   if(asianDayStart == dayStart) return asianValid;

   datetime s = dayStart + InpAsianStartHour * 3600;
   datetime e = dayStart + InpAsianEndHour   * 3600;
   if(now < e) return false;                    // range not finished yet

   asianDayStart = dayStart;
   asianValid    = false;

   MqlRates rates[];
   int n = CopyRates(_Symbol, InpTF, s, e - 1, rates);
   if(n < 5) return false;

   double hi = rates[0].high, lo = rates[0].low;
   for(int i = 1; i < n; i++)
   {
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
   }

   double a[];
   if(CopyBuffer(hATRH1, 0, 1, 1, a) != 1 || a[0] <= 0.0) return false;
   double h = hi - lo;
   if(h < a[0] * InpAsianMinATRH1 || h > a[0] * InpAsianMaxATRH1) return false;   // too tight / too wide

   asianHi = hi; asianLo = lo; asianValid = true;
   return true;
}

void TryBreakout(int regime)
{
   if(!InBreakWindow()) return;
   if(FindModulePos(MOD_BREAK) != 0) return;
   if(tradesToday[MOD_BREAK] >= InpBreakMaxTrades) return;
   if(!UpdateAsianRange()) return;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR, 0, 0, 3, atr) < 3) return;

   double cl1 = iClose(_Symbol, InpTF, 1);
   double buf = InpBreakBufferPts * _Point;

   bool buy  = (cl1 > asianHi + buf) && !(InpBreakUseRegime && regime == -1);
   bool sell = (cl1 < asianLo - buf) && !(InpBreakUseRegime && regime ==  1);
   if(!buy && !sell) return;

   double mid    = (asianHi + asianLo) / 2.0;
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = buy ? (ask - mid) : (mid - bid);             // stop back inside the range
   slDist = MathMax(slDist, atr[1] * 1.0);
   slDist = MathMin(slDist, atr[1] * InpBreakMaxSL_ATR);

   Place(MOD_BREAK, buy, slDist, slDist * InpBreakRR, InpBreakRisk);
}

//+------------------------------------------------------------------+
//| Open-trade management: per-module time exit + Friday flat        |
//+------------------------------------------------------------------+
void ManagePositions()
{
   bool friday = FridayCutoff();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsMyMagic(magic)) continue;

      if(friday) { trade.PositionClose(ticket); continue; }

      int id = (int)(magic - (long)InpMagicBase);
      int maxBars = (id == MOD_TREND ? InpTrendHoldBars : (id == MOD_RANGE ? InpRangeHoldBars : InpBreakHoldBars));
      if(maxBars > 0)
      {
         datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
         if(iBarShift(_Symbol, InpTF, ot, false) >= maxBars) trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Loss-streak tracking across all modules                          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(!IsMyMagic(HistoryDealGetInteger(trans.deal, DEAL_MAGIC))) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(pnl < 0.0) consecLosses++;
   else          consecLosses = 0;

   if(InpMaxConsecLosses > 0 && consecLosses >= InpMaxConsecLosses && !haltedToday)
   {
      haltedToday = true;
      Print("Loss streak of ", consecLosses, " reached. Trading halted until next day.");
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ResetDayIfNeeded();
   ManagePositions();                       // always manage open trades, even when halted

   if(!haltedToday && DailyLossHit())
   {
      haltedToday = true;
      Print("Daily loss limit hit. Trading halted until next day.");
   }
   if(haltedToday) return;

   if(!NewBar()) return;

   int regime = GetRegime();
   string rName = (regime > 0 ? "BULL" : (regime < 0 ? "BEAR" : "NEUTRAL"));
   Comment("Regime: ", rName,
           " | Trades T/R/B: ", tradesToday[1], "/", tradesToday[2], "/", tradesToday[3],
           " | Open risk: ", DoubleToString(OpenRiskPct(), 2), "%",
           " | Loss streak: ", consecLosses,
           " | Spread: ", SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));

   if(FridayCutoff()) return;
   if(InBlackout()) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints) return;

   if(InpUseTrend)    TryTrend(regime);
   if(InpUseRange)    TryRange(regime);
   if(InpUseBreakout) TryBreakout(regime);
}
//+------------------------------------------------------------------+

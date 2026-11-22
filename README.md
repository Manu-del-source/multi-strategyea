# multi-strategyea

MQL5 multi-strategy Expert Advisor for XAUUSD (MetaTrader 5).

Three modules sharing one risk budget:
1. Trend pullback (Bull/Bear regime)
2. Range mean reversion (Neutral regime)
3. Asian-range breakout (London open)

Shared risk: daily loss limit, loss-streak halt, total open-risk cap, max open positions, spread filters, Friday flat.

**Status:** untested starter template. Backtest each module alone on 6-12 months of real ticks, then demo-forward-test before any live use. Not financial advice.
